#!/usr/bin/env python3
"""Checks one guard-store-cc.sh run (AIO-860). The last main-loop request
Claude Code sent to the fake API carries the whole conversation: every
scripted Bash call and the tool result that reached the model's context.

  guard-store-check.py REQUESTS_JSONL REPO_DIR
"""
import json
import subprocess
import sys

reqs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
reqs = [r for r in reqs if any(t.get("name") == "Bash" for t in r.get("tools", []))]
cmd, res = {}, {}
for m in reqs[-1]["messages"] if reqs else []:
    if not isinstance(m.get("content"), list):
        continue
    for b in m["content"]:
        if b.get("type") == "tool_use":
            cmd[b["id"]] = b["input"]["command"]
        if b.get("type") == "tool_result":
            c = b.get("content")
            t = c if isinstance(c, str) else "\n".join(x.get("text", "") for x in c or [])
            res[b["tool_use_id"]] = {"text": t, "bytes": len(t.encode()), "is_error": bool(b.get("is_error"))}
by = {}
for i, k in enumerate(sorted(cmd)):
    by[i + 1] = dict(res.get(k, {"text": "", "bytes": 0, "is_error": None}), command=cmd[k])

ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok = ok and bool(c)


def raw(c):
    return len(subprocess.run(c, shell=True, cwd=sys.argv[2], capture_output=True).stdout.rstrip(b"\n"))


def last(i):
    return (by.get(i, {}).get("text", "").strip().splitlines() or [""])[-1]


print("bytes in the model's context: after (with the hooks) vs before (the command's own stdout)")
for i in sorted(by):
    r = by[i]
    base = r["command"].replace("AIONAS_FULL=1 ", "")
    before = 0 if base.startswith("aionas-recall") else raw(base)
    print(f"  step {i}: {r['bytes']:6d} after {before:6d} before  error={r['is_error']}  {r['command']}")

check(len(by) == 7 and all(r["text"] for r in by.values()), "seven tool results reached the model")
check(last(1).startswith("[aionas-guard: capped cat_cap at about 1500 tokens: kept ") and by[1]["bytes"] < raw("cat big.log"),
      "cat big.log: capped, guard marker last")
t = by.get(2, {}).get("text", "")
check(t.count("ERROR") == 3 and "INFO" not in t and not by[2]["is_error"], "aionas-recall <id> --grep ERROR: only the matching lines")
check(last(3).startswith("[aionas-store: kept 40+40 of 300 lines, id=out_") and len(by[3]["text"].splitlines()) == 81,
      "./gen.sh: head 40 + tail 40 + store marker")
check(by.get(4, {}).get("bytes", 0) >= raw("./gen.sh") and "aionas-" not in by[4]["text"], "AIONAS_FULL=1 ./gen.sh: full output, no marker")
check(by.get(5, {}).get("command") == "git log" and 0 < len(by[5]["text"].splitlines()) <= 30 and "Author:" not in by[5]["text"],
      "git log: quiet form (-n 30 --oneline)")
t = by.get(6, {}).get("text", "")
check(by.get(6, {}).get("is_error") and "Error: step 301 broke" in t and "step 001 ok" in t and "step 300 ok" in t and "aionas-" not in t,
      "failing ./fail.sh: full output")
check(by.get(7, {}).get("bytes", 0) >= raw("git log") - 64 and "aionas-" not in by[7]["text"], "AIONAS_FULL=1 git log: full output")
print("ALL PASSED" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
