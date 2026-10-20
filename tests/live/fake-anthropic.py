#!/usr/bin/env python3
"""A scripted stand-in for the Anthropic Messages API, on 127.0.0.1 only
(AIO-860 live check of the guard and store hooks). No model, no network:
each main-loop request gets the next scripted Bash tool call, and every
tool_result Claude Code sends back is logged as JSON lines, so the check can
measure the bytes that reached the model's context.

  fake-anthropic.py PORT_FILE LOG_FILE STEPS_FILE

STEPS_FILE: one command per line. "{id}" is replaced with the last
out_<12 hex> id seen in a tool_result.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, log_file, steps_file = sys.argv[1:4]
steps = [l.rstrip("\n") for l in open(steps_file, encoding="utf-8") if l.strip()]
state = {"last_id": "", "issued": {}}


def text_of(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict))
    return ""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def sse(self, events):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for name, data in events:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def reply(self, blocks, stop, stream):
        msg = {"id": "msg_fake", "type": "message", "role": "assistant", "model": "claude-fake",
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 1, "output_tokens": 1}}
        if not stream:
            msg.update(content=blocks, stop_reason=stop)
            body = json.dumps(msg).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        ev = [("message_start", {"type": "message_start", "message": msg})]
        for i, b in enumerate(blocks):
            if b["type"] == "text":
                ev.append(("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}}))
                ev.append(("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": b["text"]}}))
            else:
                ev.append(("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}}))
                ev.append(("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}}))
            ev.append(("content_block_stop", {"type": "content_block_stop", "index": i}))
        ev.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}))
        ev.append(("message_stop", {"type": "message_stop"}))
        self.sse(ev)

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        if "count_tokens" in self.path:
            body = b'{"input_tokens": 10}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if os.environ.get("FAKE_DUMP"):
            with open(os.environ["FAKE_DUMP"], "a", encoding="utf-8") as f:
                f.write(json.dumps(req) + "\n")
        stream = bool(req.get("stream"))
        tools = [t.get("name") for t in req.get("tools", []) if isinstance(t, dict)]
        if "Bash" not in tools:
            self.reply([{"type": "text", "text": "ok"}], "end_turn", stream)
            return
        done = 0
        for m in req.get("messages", []):
            if m.get("role") != "user" or not isinstance(m.get("content"), list):
                continue
            for b in m["content"]:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    done += 1
                    t = text_of(b)
                    ids = re.findall(r"out_[0-9a-f]{12}", t)
                    if ids:
                        state["last_id"] = ids[-1]
        # Log only the newest tool_result (the request repeats the history).
        last = req["messages"][-1]
        if done and isinstance(last.get("content"), list):
            for b in last["content"]:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    t = text_of(b)
                    with open(log_file, "a", encoding="utf-8") as f:
                        f.write(json.dumps({"step": done, "command": state["issued"].get(done - 1, ""),
                                            "is_error": bool(b.get("is_error")), "bytes": len(t.encode()), "text": t}) + "\n")
        if done < len(steps):
            cmd = steps[done].replace("{id}", state["last_id"])
            state["issued"][done] = cmd
            self.reply([{"type": "tool_use", "id": f"toolu_{done:04d}", "name": "Bash",
                         "input": {"command": cmd, "description": "scripted step"}}], "tool_use", stream)
        else:
            self.reply([{"type": "text", "text": "all steps done"}], "end_turn", stream)


srv = HTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
