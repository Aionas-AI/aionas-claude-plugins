# Local stub for the scripted `claude -p` checks: plays the Messages API
# (answers "ok", no model) and the Aionas machine routes the plugin calls.
# Every request is logged as one JSON line (path, a few body fields), never a
# prompt. Binds 127.0.0.1 only.  usage: python3 -I stub.py PORT LOGFILE POLICYFILE
import http.server, json, sys

PORT, LOG, POLICY = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None, ctype='application/json'):
        b = b'' if obj is None else (obj if isinstance(obj, bytes) else json.dumps(obj).encode())
        self.send_response(code)
        self.send_header('content-type', ctype)
        self.send_header('content-length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log(self, entry):
        with open(LOG, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def do_GET(self):
        if self.path.startswith('/enroll/v1/savings/policy'):
            self.log({'path': self.path, 'auth': self.headers.get('authorization', '')[:11]})
            with open(POLICY, 'rb') as f:
                return self.reply(200, f.read())
        self.reply(200, {})

    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        raw = self.rfile.read(n)
        try:
            j = json.loads(raw)
        except Exception:
            j = {}
        if self.path.startswith('/enroll/v1/savings/'):
            self.log({'path': self.path, 'body': j})
            if self.path.startswith('/enroll/v1/savings/overrides'):
                blocked = json.load(open(POLICY)).get('x_blocked', [])
                st = 'requested' if j.get('method_id') in blocked else 'self'
                return self.reply(202 if st == 'requested' else 201, {'id': 'ovr_e2e', 'user_id': 'u1', 'method_id': j.get('method_id'), 'status': st, 'reason': j.get('reason')})
            return self.reply(200, {'stored': 1})
        self.log({'path': self.path, 'model': j.get('model'), 'output_config': j.get('output_config'), 'stream': j.get('stream')})
        if 'count_tokens' in self.path:
            return self.reply(200, {'input_tokens': 10})
        msg = {'id': 'msg_stub', 'type': 'message', 'role': 'assistant', 'model': j.get('model', 'x'), 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 5, 'output_tokens': 1}}
        if not j.get('stream'):
            msg['content'] = [{'type': 'text', 'text': 'ok'}]
            msg['stop_reason'] = 'end_turn'
            return self.reply(200, msg)
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.end_headers()
        def ev(t, d):
            self.wfile.write(('event: %s\ndata: %s\n\n' % (t, json.dumps(d))).encode())
        ev('message_start', {'type': 'message_start', 'message': msg})
        ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
        ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'ok'}})
        ev('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        ev('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}})
        ev('message_stop', {'type': 'message_stop'})


http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
