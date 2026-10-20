#!/usr/bin/env python3
# E2E evidence for the aionas mod band (wave-24 mod spec §9): runs the pinned
# Claude Code (2.1.299) INTERACTIVELY in a pseudo-terminal with
# --plugin-dir plugins/aionas-savings, a temporary HOME and CLAUDE_CONFIG_DIR,
# and a fixture policy.json that carries the `me` and `savings` blocks. The
# Messages API and the Aionas machine routes are a LOCAL stub on 127.0.0.1
# (no model, nothing billable; the key is a placeholder the stub ignores).
# The person's own ~/.claude and ~/.aionas are never read or written.
#
# It draws the terminal screen with a small VT emulator and saves PNGs (and
# the plain text) of:
#   band-1-one-line       variant 1: the one line (who, saved today, chips, More)
#   band-3-warning-row    variant 3: after one turn the stub reports a 214K
#                         context: the warning row with /compact and Later
#   band-7-chip-pressed   variant 7b: the guard chip pressed -> off until HH:MM
#                         (and pressed again: back on, band-7-chip-pressed-again)
#   band-2-full-view      variant 2: More pressed
#
#   python3 -I plugins/aionas-savings/docs/evidence/band-e2e.py [OUT_DIR]
# Needs npx (the npm cache or registry), python3 with Pillow, macOS or Linux.
import json, os, pty, re, select, shutil, signal, struct, subprocess, sys, tempfile, termios, fcntl, threading, time, unicodedata
import http.server

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(os.path.dirname(HERE))
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE
COLS, ROWS = 200, 34
CC = os.environ.get('CLAUDE_CODE_VERSION', '2.1.299')

# --- the local stub -----------------------------------------------------------
NOW = time.time()
POLICY = {
    'methods': [
        {'method_id': m, 'state': 'off' if m == 'handoff' else 'on', 'required': False, 'self_override_allowed': True,
         'self_release_allowed': True, **({'params': {'threshold_tokens': 200000, 'idle_minutes': 55}} if m == 'handoff' else {})}
        for m in ['effort_default', 'subagent_sonnet', 'noisy_guard', 'output_store', 'handoff', 'unused_services', 'write_minimum']
    ] + [{'method_id': 'cache_guard', 'state': 'on', 'required': True, 'self_override_allowed': False, 'self_release_allowed': False}],
    'overrides': [],
    # Example names and numbers (fixture), as the gateway lane will send them.
    'me': {'display_name': 'Noa Levi', 'org_name': 'Acme', 'role': 'member', 'lead_name': 'Omer Katz', 'computer_name': 'mbp-noa'},
    'savings': {'as_of': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(NOW - 300)), 'money_kind': 'usd', 'today_usd': 3.8,
                'since_on_usd': 46.2, 'today_tokens': 0, 'since_on_tokens': 0,
                'since_on_date': time.strftime('%Y-%m-%d', time.gmtime(NOW - 12 * 86400)), 'tier': 'estimated'},
}
LOG = []


class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj, ctype='application/json'):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', ctype)
        self.send_header('content-length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        LOG.append(('GET', self.path))
        if self.path.startswith('/enroll/v1/savings/policy'):
            return self.send(200, POLICY)
        self.send(200, {})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length') or 0))
        LOG.append(('POST', self.path))
        if self.path.startswith('/enroll/v1/savings/overrides'):
            j = json.loads(body or b'{}')
            return self.send(201, {'id': 'ovr_e2e', 'user_id': 'u1', 'method_id': j.get('method_id'), 'status': 'self'})
        if self.path.startswith('/enroll/v1/'):
            return self.send(200, {'stored': 1})
        if 'count_tokens' in self.path:
            return self.send(200, {'input_tokens': 10})
        j = json.loads(body or b'{}')
        # A 214K context: the band's warning row (compact_at 200K).
        usage = {'input_tokens': 14000, 'cache_read_input_tokens': 200000, 'cache_creation_input_tokens': 0, 'output_tokens': 1}
        msg = {'id': 'msg_stub', 'type': 'message', 'role': 'assistant', 'model': j.get('model', 'x'), 'content': [],
               'stop_reason': None, 'stop_sequence': None, 'usage': usage}
        if not j.get('stream'):
            msg['content'] = [{'type': 'text', 'text': 'ok'}]
            msg['stop_reason'] = 'end_turn'
            return self.send(200, msg)
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.end_headers()

        def ev(t, d):
            self.wfile.write(('event: %s\ndata: %s\n\n' % (t, json.dumps(d))).encode())
        ev('message_start', {'type': 'message_start', 'message': msg})
        ev('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
        ev('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Done: the retry loop now backs off.'}})
        ev('content_block_stop', {'type': 'content_block_stop', 'index': 0})
        ev('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': usage})
        ev('message_stop', {'type': 'message_stop'})


# --- a small VT emulator ------------------------------------------------------
BASIC = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
         (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]
FG, BG = (215, 218, 224), (20, 22, 26)


def x256(n):
    if n < 16:
        return BASIC[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return (v, v, v)


class Screen:
    def __init__(self, cols, rows, reply):
        self.cols, self.rows, self.reply = cols, rows, reply
        self.reset_style()
        self.grid = [[self.blank() for _ in range(cols)] for _ in range(rows)]
        self.x = self.y = 0
        self.saved = (0, 0)
        self.buf = ''
        self.lock = threading.Lock()

    def reset_style(self):
        self.style = {'fg': None, 'bg': None, 'bold': False, 'dim': False, 'inv': False}

    def blank(self):
        return [' ', None, None, False, False, False]

    def scroll(self):
        self.grid.pop(0)
        self.grid.append([self.blank() for _ in range(self.cols)])

    def put(self, ch):
        w = 2 if unicodedata.east_asian_width(ch) in 'WF' else 1
        if unicodedata.combining(ch) or ch in '‍️':
            return
        if self.x + w > self.cols:
            self.x = 0
            self.lf()
        s = self.style
        self.grid[self.y][self.x] = [ch, s['fg'], s['bg'], s['bold'], s['dim'], s['inv']]
        if w == 2 and self.x + 1 < self.cols:
            self.grid[self.y][self.x + 1] = ['', s['fg'], s['bg'], s['bold'], s['dim'], s['inv']]
        self.x += w

    def lf(self):
        if self.y == self.rows - 1:
            self.scroll()
        else:
            self.y += 1

    def sgr(self, ps):
        ps = ps or [0]
        i = 0
        while i < len(ps):
            p = ps[i]
            if p == 0:
                self.reset_style()
            elif p == 1:
                self.style['bold'] = True
            elif p == 2:
                self.style['dim'] = True
            elif p == 22:
                self.style['bold'] = self.style['dim'] = False
            elif p == 7:
                self.style['inv'] = True
            elif p == 27:
                self.style['inv'] = False
            elif 30 <= p <= 37:
                self.style['fg'] = BASIC[p - 30]
            elif 90 <= p <= 97:
                self.style['fg'] = BASIC[p - 90 + 8]
            elif 40 <= p <= 47:
                self.style['bg'] = BASIC[p - 40]
            elif 100 <= p <= 107:
                self.style['bg'] = BASIC[p - 100 + 8]
            elif p == 39:
                self.style['fg'] = None
            elif p == 49:
                self.style['bg'] = None
            elif p in (38, 48) and i + 1 < len(ps):
                key = 'fg' if p == 38 else 'bg'
                if ps[i + 1] == 5 and i + 2 < len(ps):
                    self.style[key] = x256(ps[i + 2])
                    i += 2
                elif ps[i + 1] == 2 and i + 4 < len(ps):
                    self.style[key] = tuple(ps[i + 2:i + 5])
                    i += 4
            i += 1

    def erase(self, y, x0, x1):
        for x in range(max(0, x0), min(self.cols, x1)):
            self.grid[y][x] = self.blank()

    def csi(self, priv, params, final):
        ps = [int(p) if p.isdigit() else 0 for p in params.split(';')] if params else []
        n = (ps[0] if ps and ps[0] else 1)
        if priv in ('?', '>', '<', '='):
            if final in 'hl' and ps and ps[0] in (1049, 47, 1047):
                self.grid = [[self.blank() for _ in range(self.cols)] for _ in range(self.rows)]
            if priv == '?' and final == 'u':
                pass
            return
        if final == 'm':
            self.sgr(ps)
        elif final == 'A':
            self.y = max(0, self.y - n)
        elif final in 'Be':
            self.y = min(self.rows - 1, self.y + n)
        elif final in 'Ca':
            self.x = min(self.cols - 1, self.x + n)
        elif final == 'D':
            self.x = max(0, self.x - n)
        elif final == 'E':
            self.y = min(self.rows - 1, self.y + n); self.x = 0
        elif final == 'F':
            self.y = max(0, self.y - n); self.x = 0
        elif final in 'G`':
            self.x = min(self.cols - 1, n - 1)
        elif final == 'd':
            self.y = min(self.rows - 1, n - 1)
        elif final in 'Hf':
            r = ps[0] if len(ps) > 0 and ps[0] else 1
            c = ps[1] if len(ps) > 1 and ps[1] else 1
            self.y, self.x = min(self.rows - 1, r - 1), min(self.cols - 1, c - 1)
        elif final == 'J':
            m = ps[0] if ps else 0
            if m == 0:
                self.erase(self.y, self.x, self.cols)
                for y in range(self.y + 1, self.rows):
                    self.erase(y, 0, self.cols)
            elif m == 1:
                for y in range(0, self.y):
                    self.erase(y, 0, self.cols)
                self.erase(self.y, 0, self.x + 1)
            else:
                for y in range(self.rows):
                    self.erase(y, 0, self.cols)
        elif final == 'K':
            m = ps[0] if ps else 0
            if m == 0:
                self.erase(self.y, self.x, self.cols)
            elif m == 1:
                self.erase(self.y, 0, self.x + 1)
            else:
                self.erase(self.y, 0, self.cols)
        elif final == 'X':
            self.erase(self.y, self.x, self.x + n)
        elif final == 'P':
            row = self.grid[self.y]
            del row[self.x:self.x + n]
            row.extend(self.blank() for _ in range(self.cols - len(row)))
        elif final == '@':
            row = self.grid[self.y]
            for _ in range(n):
                row.insert(self.x, self.blank())
            del row[self.cols:]
        elif final == 'L':
            for _ in range(n):
                self.grid.insert(self.y, [self.blank() for _ in range(self.cols)])
                self.grid.pop()
        elif final == 'M':
            for _ in range(n):
                self.grid.pop(self.y)
                self.grid.append([self.blank() for _ in range(self.cols)])
        elif final == 'S':
            for _ in range(n):
                self.scroll()
        elif final == 's':
            self.saved = (self.x, self.y)
        elif final == 'u':
            self.x, self.y = self.saved
        elif final == 'n' and ps and ps[0] == 6:
            self.reply('\x1b[%d;%dR' % (self.y + 1, self.x + 1))
        elif final == 'c':
            self.reply('\x1b[?1;2c')

    def feed(self, data):
        with self.lock:
            s = self.buf + data
            self.buf = ''
            i = 0
            while i < len(s):
                c = s[i]
                if c == '\x1b':
                    if i + 1 >= len(s):
                        self.buf = s[i:]; return
                    d = s[i + 1]
                    if d == '[':
                        m = re.match(r'\x1b\[([?><=]?)([0-9;:]*)([ -/]*)([@-~])', s[i:])
                        if not m:
                            if len(s) - i < 32:
                                self.buf = s[i:]; return
                            i += 2; continue
                        self.csi(m.group(1), m.group(2).replace(':', ';'), m.group(4))
                        i += m.end(); continue
                    if d in ']PX^_':
                        end = -1
                        for term in ('\x07', '\x1b\\'):
                            k = s.find(term, i + 2)
                            if k != -1 and (end == -1 or k < end[0]):
                                end = (k, len(term))
                        if end == -1:
                            self.buf = s[i:]; return
                        i = end[0] + end[1]; continue
                    if d == '7':
                        self.saved = (self.x, self.y)
                    elif d == '8':
                        self.x, self.y = self.saved
                    elif d in '()*+':
                        i += 3; continue
                    i += 2; continue
                if c == '\r':
                    self.x = 0
                elif c == '\n':
                    self.lf()
                elif c == '\b':
                    self.x = max(0, self.x - 1)
                elif c == '\t':
                    self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
                elif c >= ' ' and c != '\x7f':
                    self.put(c)
                i += 1

    def focused(self):
        """The text drawn inverse (the focus ring on the terminal)."""
        with self.lock:
            return ' '.join(''.join(c[0] for c in row if c[5]).strip() for row in self.grid if any(c[5] for c in row)).strip()

    def text(self):
        with self.lock:
            return '\n'.join(''.join(cell[0] for cell in row).rstrip() for row in self.grid).rstrip('\n') + '\n'

    def png(self, path, title):
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 15) if os.path.exists('/System/Library/Fonts/Menlo.ttc') else ImageFont.load_default()
        bold = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 15, index=1) if os.path.exists('/System/Library/Fonts/Menlo.ttc') else font
        cw, ch, pad, top = int(font.getlength('M') + 0.5), 20, 14, 30
        with self.lock:
            grid = [row[:] for row in self.grid]
        used = max((y for y, row in enumerate(grid) if ''.join(c[0] for c in row).strip()), default=0) + 1
        img = Image.new('RGB', (pad * 2 + cw * self.cols, top + pad + ch * used + pad), BG)
        dr = ImageDraw.Draw(img)
        dr.rectangle([0, 0, img.width, top - 6], fill=(36, 39, 46))
        dr.text((pad, 6), title, font=font, fill=(150, 156, 166))
        for y, row in enumerate(grid[:used]):
            for x, (c, fg, bg, b, dim, inv) in enumerate(row):
                f, k = (fg or FG), (bg or BG)
                if inv:
                    f, k = k, f
                if dim:
                    f = tuple(int(v * 0.6 + BG[i] * 0.4) for i, v in enumerate(f))
                px, py = pad + x * cw, top + pad + y * ch
                if k != BG:
                    dr.rectangle([px, py, px + cw - 1, py + ch - 1], fill=k)
                if c.strip():
                    dr.text((px, py + 1), c, font=bold if b else font, fill=f)
        img.save(path)


def main():
    root = tempfile.mkdtemp(prefix='aionas-band-e2e.')
    home = os.path.join(root, 'home')
    cfg = os.path.join(home, '.claude')
    agent = os.path.join(home, '.aionas', 'agent')
    work = os.path.join(root, 'work')
    for d in (cfg, os.path.join(agent, 'savings'), work):
        os.makedirs(d)
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Stub)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % port
    key = 'sk-ant-local-stub-not-a-key-0000000000'
    with open(os.path.join(agent, 'enrollment.json'), 'w') as f:
        json.dump({'gateway': base, 'enrollment_id': 'enr-E2E', 'machine_id': 'm1', 'os': 'darwin', 'installer_version': 3}, f)
    with open(os.path.join(agent, 'credential'), 'w') as f:
        f.write('aen-E2ETESTALIAS0123456789\n')
    os.chmod(os.path.join(agent, 'credential'), 0o600)
    with open(os.path.join(cfg, 'settings.json'), 'w') as f:
        json.dump({'effortLevel': 'high', 'maxEffortLevel': 'high', 'theme': 'dark'}, f)
    real_work = os.path.realpath(work)
    with open(os.path.join(cfg, '.claude.json'), 'w') as f:
        json.dump({'hasCompletedOnboarding': True, 'theme': 'dark', 'numStartups': 5,
                   'customApiKeyResponses': {'approved': [key[-20:]], 'rejected': []},
                   'projects': {real_work: {'hasTrustDialogAccepted': True, 'hasCompletedProjectOnboarding': True}}}, f)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'ANTHROPIC', 'AIONAS'))}
    env.update(HOME=home, CLAUDE_CONFIG_DIR=cfg, ANTHROPIC_BASE_URL=base, ANTHROPIC_API_KEY=key, TERM='xterm-256color',
               COLORTERM='truecolor', DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', TZ=os.environ.get('TZ', 'Asia/Jerusalem'))
    npx = shutil.which('npx')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(npx, [npx, '-y', '@anthropic-ai/claude-code@%s' % CC, '--plugin-dir', PLUGIN, '--model', 'claude-opus-5-5'], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    scr = Screen(COLS, ROWS, lambda s: os.write(fd, s.encode()))
    alive = [True]

    def pump():
        dec = __import__('codecs').getincrementaldecoder('utf-8')('replace')
        while alive[0]:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                scr.feed(dec.decode(data))
    threading.Thread(target=pump, daemon=True).start()

    def send(s, wait=1.5):
        os.write(fd, s.encode())
        time.sleep(wait)

    def until(pattern, timeout=60):
        t = time.time()
        while time.time() - t < timeout:
            if re.search(pattern, scr.text()):
                return True
            time.sleep(0.3)
        return False

    def shot(name, title):
        scr.png(os.path.join(OUT, name + '.png'), title)
        with open(os.path.join(OUT, name + '.txt'), 'w') as f:
            f.write(scr.text())
        print('saved', name)

    ok = True
    try:
        if not until(r'aionas │ Noa Levi', 90):
            print('band did not appear:\n' + scr.text()); ok = False; return
        time.sleep(1.5)
        shot('band-1-one-line', 'variant 1: one line (Claude Code %s, --plugin-dir, fixture policy.json)' % CC)
        send('fix the retry loop\r', 1)
        if not until(r'Context 214K', 60):
            print('no warning row:\n' + scr.text()); ok = False
        time.sleep(1.5)
        shot('band-3-warning-row', 'variant 3: the warning row after a 214K-context turn (/compact only when pressed)')
        def press(label):
            """Focus the band (ctrl+x tab), Tab to the Button whose focused text
            matches label, press Enter."""
            send('\x18\t', 1)
            for _ in range(16):
                if re.search(label, scr.focused()):
                    send('\r', 2.5)
                    send('\x1b', 1)
                    return True
                send('\t', 0.5)
            print('could not focus %r; focused=%r' % (label, scr.focused()))
            send('\x1b', 1)
            return False

        ok = press(r'guard') and ok
        if not until(r'◌ guard · off until', 10):
            print('chip press not seen:\n' + scr.text()); ok = False
        shot('band-7-chip-pressed', 'variant 7b: one click on the guard chip -> bypassed for 1 hour, on this computer at once')
        ok = press(r'guard') and ok
        if not until(r'\[ ● guard \]', 10):
            print('second press not seen:\n' + scr.text()); ok = False
        shot('band-7-chip-pressed-again', 'variant 7b: a second click on the chip -> back on (--end, no network call)')
        ok = press(r'More') and ok
        if not until(r'since on \(', 10):
            print('full view not seen:\n' + scr.text()); ok = False
        shot('band-2-full-view', 'variant 2: the full view (More); Less returns')
    finally:
        alive[0] = False
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        srv.shutdown()
        with open(os.path.join(OUT, 'band-e2e-requests.txt'), 'w') as f:
            f.write('\n'.join('%s %s' % r for r in LOG) + '\n')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
