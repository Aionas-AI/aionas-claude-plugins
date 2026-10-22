#!/usr/bin/env python3
# E2E evidence for AIO-874, built on band-e2e.py (its local stub, VT emulator
# and temporary HOME): Claude Code runs INTERACTIVELY in a pseudo-terminal with
# --plugin-dir plugins/aionas-savings, handoff on, and the handoff test seams
# (idle 20 s, cache TTL 25 s). Nothing billable, the person's own ~/.claude and
# ~/.aionas are never read or written. It saves PNGs (and the plain text) of:
#   hh-1-hover-tip       the pointer on a chip: its tip in the row under the band (the
#                        desktop app's floating card is checked by a person, see AIO-874)
#   hh-2-countdown       idle above the threshold: "Handoff doc in 1 min" + Done
#   hh-3-done            Done pressed: no row, the timer stopped
#   hh-4-warm            the doc written: "goes cold in 1 min"
#   hh-5-cold            cold: "Continue in a new conversation"
#   hh-6-new-chat        pressed: a new conversation, the starting prompt in the box
#
#   CLAUDE_CODE_VERSION=2.1.308 python3 -I plugins/aionas-savings/docs/evidence/handoff-hover-e2e.py [OUT_DIR]
import glob, importlib.util, json, os, pty, re, select, shutil, signal, struct, sys, tempfile, termios, fcntl, threading, time
import http.server

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('band_e2e', os.path.join(HERE, 'band-e2e.py'))
B = importlib.util.module_from_spec(spec)
spec.loader.exec_module(B)
OUT = sys.argv[1] if len(sys.argv) > 1 else HERE
COLS, ROWS = 200, 40
for m in B.POLICY['methods']:
    if m['method_id'] == 'handoff':
        m['state'] = 'on'


def main():
    root = tempfile.mkdtemp(prefix='aionas-hh-e2e.')
    home = os.path.join(root, 'home')
    cfg = os.path.join(home, '.claude')
    agent = os.path.join(home, '.aionas', 'agent')
    work = os.path.join(root, 'work')
    for d in (cfg, os.path.join(agent, 'savings'), work):
        os.makedirs(d)
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), B.Stub)
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
               COLORTERM='truecolor', DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
               TZ=os.environ.get('TZ', 'Asia/Jerusalem'),
               AIONAS_HANDOFF_IDLE_SECONDS='45', AIONAS_HANDOFF_POLL_SECONDS='2', AIONAS_HANDOFF_TTL_SECONDS='75')
    npx = shutil.which('npx')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(npx, [npx, '-y', '@anthropic-ai/claude-code@%s' % B.CC, '--plugin-dir', B.PLUGIN, '--model', 'claude-opus-5-5'], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    scr = B.Screen(COLS, ROWS, lambda s: os.write(fd, s.encode()))
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

    def find(text):
        """(column, row), 1-based, of the first cell of text on screen."""
        for y, line in enumerate(scr.text().split('\n')):
            x = line.find(text)
            if x >= 0:
                return x + 1, y + 1
        return None

    def hover(text):
        at = find(text)
        if at is None:
            return False
        send('\x1b[<35;%d;%dM' % (at[0] + 1, at[1]), 1.5)
        return True

    def press(label):
        send('\x18\t', 1)
        for _ in range(20):
            if re.search(label, scr.focused()):
                send('\r', 2.5)
                return True
            send('\t', 0.5)
        print('could not focus %r; focused=%r' % (label, scr.focused()))
        send('\x1b', 1)
        return False

    hdir = os.path.join(agent, 'savings', 'handoff')
    ok = True
    try:
        if not until(r'aionas │ Noa Levi', 120):
            print('band did not appear:\n' + scr.text()); ok = False; return
        time.sleep(1.5)
        if not hover('[ guard ]'):
            print('no guard chip:\n' + scr.text()); ok = False
        if not until(r'Noisy commands are shortened', 8):
            print('no tip card on hover:\n' + scr.text()); ok = False
        shot('hh-1-hover-tip', 'AIO-874: the pointer on the guard chip; on the terminal its tip is the row under the band (Claude Code %s)' % B.CC)
        send('\x1b[<35;2;2M', 1)
        if os.environ.get('HH_ONLY_HOVER'):
            return

        send('fix the retry loop\r', 1)
        if not until(r'Handoff doc in 1 min', 60):
            print('no countdown:\n' + scr.text()); ok = False
        shot('hh-2-countdown', 'AIO-874: idle above the threshold, the minutes until the handoff doc, and Done')
        ok = press(r'Done with this chat') and ok
        time.sleep(2)
        sids = [os.path.basename(p)[:-6] for p in glob.glob(os.path.join(hdir, '*.state'))]
        state = open(os.path.join(hdir, sids[0] + '.state')).read() if sids else ''
        if not state.startswith('ended') or re.search(r'Handoff doc in', scr.text()):
            print('done not applied: state=%r\n%s' % (state, scr.text())); ok = False
        shot('hh-3-done', 'AIO-874: Done pressed, no handoff doc for this chat')

        send('one more thing\r', 1)
        if not until(r'Handoff doc in 1 min', 60):
            print('no countdown after a new prompt:\n' + scr.text()); ok = False
        # The wake: the stub model writes no file, so the doc is written for it.
        if not until(r'\[aionas-handoff\]|Handoff doc written', 60):
            if not re.search('delivered', open(os.path.join(hdir, sids[0] + '.state')).read()):
                print('no wake:\n' + scr.text()); ok = False
        sid = sids[0] if sids else ''
        with open(os.path.join(hdir, 'handoff-%s.md' % sid), 'w') as f:
            f.write('Previous conversation: %s\n# Handoff\n' % sid)
        if not until(r'goes cold in [12] min', 40):
            print('no warm countdown:\n' + scr.text()); ok = False
        shot('hh-4-warm', 'AIO-874: the doc written, the minutes until this chat goes cold')
        if not until(r'This chat is cold', 60):
            print('never cold:\n' + scr.text()); ok = False
        shot('hh-5-cold', 'AIO-874: cold, Continue in a new conversation')
        ok = press(r'Continue in a new conversation') and ok
        if not until(r'Continue the work described in the handoff document', 15):
            print('prompt not filled:\n' + scr.text()); ok = False
        if not until(r'^(?![\s\S]*This chat is cold)', 10):
            print('the old chat\'s handoff row stayed after /clear'); ok = False
        shot('hh-6-new-chat', 'AIO-874: a new conversation (/clear), the starting prompt in the box; the old one stays for /resume')
        olds = glob.glob(os.path.join(cfg, 'projects', '*', sid + '.jsonl'))
        print('old transcript kept:', bool(olds))
    finally:
        alive[0] = False
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        srv.shutdown()
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
