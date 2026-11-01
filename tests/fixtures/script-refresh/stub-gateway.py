# Local stub for the real-curl script-refresh test: serves manifest.json and
# the four scripts from a folder and logs every request (request line and
# headers) to a file. Binds 127.0.0.1 only.
#   usage: python3 -I stub-gateway.py PORTFILE LOGFILE SERVEDIR
import http.server, sys

PORTFILE, LOG, SERVE = sys.argv[1], sys.argv[2], sys.argv[3]
NAMES = ('aionas-plan-usage.sh', 'aionas-statusline-tap.sh',
         'aionas-plan-usage.ps1', 'aionas-statusline-tap.ps1')


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def note(self):
        with open(LOG, 'a') as f:
            f.write('REQUEST %s %s\n' % (self.command, self.path))
            for k, v in self.headers.items():
                f.write('HEADER %s: %s\n' % (k, v))

    def send(self, code, body=b'', extra=()):
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.note()
        if self.path == '/enroll/v1/scripts/manifest':
            return self.send(200, open(SERVE + '/manifest.json', 'rb').read())
        pre = '/api/aionas/onboarding/scripts/'
        if self.path.startswith(pre):
            n = self.path[len(pre):]
            if n == 'aionas-plan-usage.ps1':
                return self.send(302, b'', [('location', '/elsewhere/' + n)])
            if n in NAMES:
                return self.send(200, open(SERVE + '/' + n, 'rb').read())
        return self.send(404)


s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(PORTFILE, 'w').write(str(s.server_address[1]))
s.timeout = 0.5
import time
end = time.time() + 30
while time.time() < end:
    s.handle_request()
