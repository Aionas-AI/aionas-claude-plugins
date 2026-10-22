// aionas-savings mod (Claude Code 2.1.299 function hooks). Owners: AIO-855, AIO-859.
//
// - The aionas mod band above the prompt (terminal and desktop; VS Code draws
//   no mod in 2.1.299), drawn by hooks/band.tsx per the wave-24 mod spec: one
//   line by default with More (M1), per-method chips whose one click bypasses
//   that method for 1 hour or ends my bypass (M3), the effort chip with the
//   higher-effort window's countdown, and the warning row with /compact above
//   compact_at. /compact runs only when pressed: never automatically. No
//   thumbs up/down and no "pause all" in this wave (W24-5, M3).
// - The slash commands /aionas-bypass and /aionas-xhigh, answered here without
//   a model turn; the work is done by commands/*.sh, run by argument vector
//   (no shell), so nothing the person types is ever parsed by a shell.
// - The effort grant of W24-3, which ALLOWS and never sets a level (AIO-868):
//   a session opened in an /aionas-xhigh window (or while effort_default is
//   off for the person) starts at its usual level; when the person picks
//   xhigh or max (with /effort, or the app's picker: at launch, or Extra
//   mid-session), that level goes on each main-loop request
//   through CLAUDE_CODE_EXTRA_BODY, set just before the request and put back
//   right after it, so tools and subagents never inherit it. Every other
//   session is left to the settings cap (maxEffortLevel=high); an older
//   install's pin (CLAUDE_CODE_EFFORT_LEVEL) is moved by /effort for the
//   session it is typed in.
// - The "write the minimum" skill expands to a no-op when the method is off.
// - The handoff row (AIO-874): the minutes left until the handoff doc, with
//   "Done with this chat" (also /aionas-done: no doc for this session); after
//   the doc, the minutes left until the session's prompt cache runs out; once
//   cold, "Continue in a new conversation": in the desktop app a new session
//   of its own (the app's claude://code/new link: the starting prompt that
//   names the doc, this folder) while this one stays in the list; in the
//   terminal /clear (a new session id; /resume returns to the old one) and
//   the starting prompt put in the prompt box. The person sends it.
//
// Privacy (W24-4): nothing here sends anything; the scripts send only method
// ids, durations, closed-set params and a reason the person typed. The band
// reads its facts through `aionas-bypass.sh --band` (numbers and names) and
// the context size from session.measure; it never calls $.http.fetch or
// $.session.messages, nor reads ~/.claude/projects or the alias credential.
import type { EngineInterface, Register } from 'claude-code'
import { drawBand, isCounting, parseBand, routeOf } from './band.tsx'
import type { Action, Facts } from './band.tsx'

type Grant = 'high' | 'xhigh' | 'max' | 'free'
type Level = 'xhigh' | 'max'
type Ran = { code: number; out: string }

export const parseGrant = (out: string): Grant => {
  const g = out.trim()
  return g === 'xhigh' || g === 'max' || g === 'free' ? g : 'high'
}

// The user's own CLAUDE_CODE_EXTRA_BODY with output_config.effort set; the
// user's value untouched (undefined) when it is not a JSON object.
export const withEffort = (base: string | undefined, level: Level): string | undefined => {
  let body: Record<string, unknown> = {}
  if (base !== undefined && base.trim() !== '') {
    try {
      const parsed: unknown = JSON.parse(base)
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined
      body = parsed as Record<string, unknown>
    } catch {
      return undefined
    }
  }
  const oc = body.output_config
  const config = oc !== null && typeof oc === 'object' && !Array.isArray(oc) ? (oc as Record<string, unknown>) : {}
  return JSON.stringify({ ...body, output_config: { ...config, effort: level } })
}

export const splitArgs = (args: string): string[] => args.trim().split(/\s+/).filter(a => a !== '')

const levelOf = (v: unknown): Level | undefined => (v === 'xhigh' || v === 'max' ? v : undefined)

// The --effort the app launched this Claude Code with (its picker before the
// first message), from the process's command line.
export const launchEffort = (args: string): string | undefined =>
  /(?:^|\s)--effort(?:=|\s+)(low|medium|high|xhigh|max)(?=\s|$)/.exec(args)?.[1]

// The /effort arguments that name a level (Claude Code 2.1.299).
const EFFORT_ARGS = ['low', 'medium', 'high', 'xhigh', 'max', 'auto']

// The session's state. Module variables: a reload (a new module) starts them
// over, and session.start (which a reload fires again) reads them back from
// the scripts, which keep the grant pinned per session on disk.
const st = {
  sid: '',
  bash: 'bash',
  grant: Promise.resolve<Grant>('high'),
  chosen: undefined as Level | undefined,
  // The level the band shows: the last main-loop request's, else the level
  // the session starts at (an older install's pin, else effortLevel).
  sent: undefined as string | undefined,
  start: undefined as string | undefined,
  // The app's mid-session picker reaches Claude Code as the flag setting
  // effortLevel (apply_flag_settings); a change since the last request is
  // the person's latest choice. Max is not kept there (Claude Code drops it),
  // so a mid-session Max stays at the cap: /effort max is the way.
  flag: undefined as unknown,
  baseExtra: undefined as string | undefined,
  baseUrl: undefined as string | undefined,
  facts: undefined as Facts | undefined,
  listed: Promise.resolve(),
  refreshing: undefined as Promise<void> | undefined,
  isFull: false,
  contextTokens: 0,
  contextWindow: 0,
  laterAt: 0,
  tick: undefined as { cancel: () => void } | undefined,
  countdown: undefined as { cancel: () => void } | undefined,
  isDrawn: false,
}

function script(root: string, path: string): string {
  return `${root.replace(/\\/g, '/')}/${path}`
}

async function run($: EngineInterface, argv: string[]): Promise<Ran> {
  try {
    const r = await $.process.run([st.bash, ...argv], { timeoutMs: 15000, env: { AIONAS_SESSION_ID: st.sid } })
    return { code: r.exitCode, out: r.stdout.trim() }
  } catch {
    return { code: 127, out: '' }
  }
}

async function bypass($: EngineInterface, args: string[]): Promise<Ran> {
  return run($, [script($.plugin.root, 'commands/aionas-bypass.sh'), ...args])
}

// The band's facts, read again (§6): at session start, every 30 s, after a
// press and after each main-loop turn. One read at a time. While a countdown
// runs (the xhigh window, the handoff doc, the cold time) a 15 s timer keeps
// it moving; it stops with it.
function refresh($: EngineInterface): Promise<void> {
  if (st.refreshing !== undefined) return st.refreshing
  const p = (async () => {
    const r = await bypass($, ['--band'])
    if (r.code !== 0 || r.out === '') return
    st.facts = parseBand(r.out)
    const isOpen = isCounting(st.facts)
    if (isOpen && st.countdown === undefined) st.countdown = $.clock.every(15_000, () => void refresh($))
    if (!isOpen && st.countdown !== undefined) {
      st.countdown.cancel()
      st.countdown = undefined
    }
    $.ui.invalidate('ui.render')
  })().finally(() => {
    st.refreshing = undefined
  })
  st.refreshing = p
  return p
}

// The 30 s read, while the band is drawn: once a surface asked for it (the
// desktop app's sessions are not interactive, and its roster may not list
// it), or while a surface is attached.
async function drawnRefresh($: EngineInterface): Promise<void> {
  if (st.isDrawn) return refresh($)
  const surfaces = await $.session.surfaces().catch(() => [] as readonly string[])
  if (surfaces.length > 0) await refresh($)
}

async function readFlag($: EngineInterface): Promise<unknown> {
  try {
    return (await $.settings.read({ source: 'flag' })).effortLevel
  } catch {
    return undefined
  }
}

async function readGrant($: EngineInterface): Promise<Grant> {
  const r = await run($, [script($.plugin.root, 'hooks/effort-window.sh'), 'grant', st.sid])
  st.chosen = undefined
  const g = parseGrant(r.out)
  if (g === 'high') return g
  // A granted session honours the level the app started it at, then the
  // picker's flag setting when it is set.
  const ps = await run($, ['-c', 'ps -o args= -p $PPID 2>/dev/null'])
  st.chosen = levelOf(launchEffort(ps.out))
  st.flag = await readFlag($)
  if (st.flag !== undefined) st.chosen = levelOf(st.flag)
  return g
}

async function readStart($: EngineInterface): Promise<void> {
  const pin = await $.env.get('CLAUDE_CODE_EFFORT_LEVEL')
  let level = pin
  if (level === undefined) {
    try {
      const v = (await $.settings.read()).effortLevel
      level = typeof v === 'string' ? v : undefined
    } catch {
      level = undefined
    }
  }
  st.start = level
  $.ui.invalidate('ui.render')
}

const shownLevel = (): string | undefined => st.chosen ?? st.sent ?? st.start

async function press($: EngineInterface, a: Action): Promise<void> {
  const r =
    a.kind === 'xhigh'
      ? await run($, [script($.plugin.root, 'commands/aionas-xhigh.sh')])
      : await bypass($, a.kind === 'end' ? ['--end', a.method] : [a.method, '1h'])
  $.ui.toast(r.out || 'aionas could not run (bash was not found).')
  await refresh($)
}

// After a /clear the process goes on under a new session id, a moment later:
// take it up (and forget the old session's context size) once it shows.
async function adoptNewSession($: EngineInterface, old: string): Promise<void> {
  for (let i = 0; i < 30; i++) {
    const id = await $.session.id()
    if (id !== old) {
      st.sid = id
      st.contextTokens = 0
      st.laterAt = 0
      await refresh($)
      return
    }
    await $.clock.sleep(100)
  }
}

function handoff($: EngineInterface, args: string[]): Promise<Ran> {
  return run($, [script($.plugin.root, 'hooks/handoff-wake.sh'), ...args])
}

// "Done with this chat": no handoff doc for this session.
async function done($: EngineInterface): Promise<Ran> {
  const r = await handoff($, ['end', st.sid])
  await refresh($)
  return r
}

// "Continue in a new conversation". Where neither way works, the starting
// prompt is copied for the person to paste.
async function newChat($: EngineInterface, surface: string | undefined): Promise<void> {
  const old = st.sid
  const r = await handoff($, ['prompt', old])
  if (r.code !== 0 || r.out === '') {
    $.ui.toast('The handoff doc of this chat was not found.')
    return
  }
  if (surface !== 'terminal') {
    const cwd = await $.session.cwd()
    const url = `claude://code/new?q=${encodeURIComponent(r.out)}&folder=${encodeURIComponent(cwd)}`
    const o = await handoff($, ['open-app', url])
    if (o.code === 0) {
      $.ui.toast('A new session opened with the handoff doc. This one stays in your list, so you can come back to it.')
      return
    }
    await $.ui.copy({ text: r.out, ...(surface === undefined ? {} : { surface: surface as never }) }).catch(() => undefined)
    $.ui.toast('The starting prompt is copied: paste it into a new session.')
    return
  }
  let isCleared = true
  try {
    await $.command.run({ command: 'clear' })
  } catch {
    isCleared = false
  }
  // The new conversation's own facts (no handoff row).
  if (isCleared) void adoptNewSession($, old).catch(() => undefined)
  const filled = isCleared ? await $.prompt.fill({ text: r.out }).catch(() => undefined) : undefined
  if (filled?.isFilled === true) {
    $.ui.toast(`New conversation: press Enter to start it. The old one is kept: /resume ${old} goes back to it.`)
    return
  }
  await $.ui.copy({ text: r.out, ...(surface === undefined ? {} : { surface: surface as never }) }).catch(() => undefined)
  $.ui.toast('The starting prompt is copied: paste it into a new conversation.')
}

async function compactNow($: EngineInterface): Promise<void> {
  await $.command.run({ command: 'compact' })
}

function redraw($: EngineInterface, change: () => void): void {
  change()
  $.ui.invalidate('ui.render')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'aionas-bypass',
      description: 'Aionas: turn a savings method off for yourself for a while (sent for approval when your org blocks it)',
      argumentHint: '<method> [duration] [reason]',
    })
    await $.command.register({
      name: 'aionas-done',
      description: 'Aionas: done with this chat, so no handoff doc is written for it',
    })
    await $.command.register({
      name: 'aionas-xhigh',
      description: 'Aionas: for 10 minutes, sessions you open may go up to xhigh or max with /effort',
      argumentHint: '[max] [reason]',
    })
    st.sid = await $.session.id()
    // Windows: Claude Code's own Git Bash, never whatever "bash" PATH finds (WSL).
    st.bash = (await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) ?? 'bash'
    st.baseExtra = await $.env.get('CLAUDE_CODE_EXTRA_BODY')
    st.baseUrl = await $.env.get('ANTHROPIC_BASE_URL')
    // Not awaited: the session never waits on a process; a request waits only
    // in the rare case it is sent before the grant is read.
    st.sent = undefined
    st.grant = readGrant($)
    void readStart($)
    st.listed = refresh($)
    st.tick?.cancel()
    st.tick = undefined
    // The 30 s refresh, read only while a surface draws the band: the
    // desktop app's sessions are not interactive, and it attaches when it
    // likes (a reload fires session.start again without its attach).
    st.tick = $.clock.every(30_000, () => void drawnRefresh($))
    return next(e)
  })

  // The granted level for each main-loop request; back to the user's own value
  // as soon as the request is sent and answered.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || e.effort === undefined) return yield* next(e)
    if (typeof e.effort === 'string' && e.effort !== st.sent) {
      st.sent = e.effort
      $.ui.invalidate('ui.render')
    }
    if ((await st.grant) !== 'high') {
      const flag = await readFlag($)
      if (flag !== st.flag) {
        st.flag = flag
        st.chosen = levelOf(flag)
        $.ui.invalidate('ui.render')
      }
    }
    if (st.chosen === undefined) return yield* next(e)
    const body = withEffort(st.baseExtra, st.chosen)
    if (body === undefined) return yield* next(e)
    await $.env.set('CLAUDE_CODE_EXTRA_BODY', body)
    try {
      return yield* next(e)
    } finally {
      await $.env.set('CLAUDE_CODE_EXTRA_BODY', st.baseExtra)
    }
  })

  // /effort inside a granted session: xhigh and max are this session's to
  // pick; the settings cap answers everywhere else.
  //
  // The install pins CLAUDE_CODE_EFFORT_LEVEL=high (settings env) so every
  // session starts at high whatever the model (Claude Code 2.1.299 keeps
  // effortLevel only as a legacy default under a per-model /effort entry).
  // Claude Code would refuse any /effort under that pin ("overrides this
  // session"), so a level the person picks becomes this session's pin first
  // (auto lifts it): /effort keeps working, maxEffortLevel still clamps it,
  // and the next session starts at high again.
  on('command.run', { command: 'effort' }, async ($, e, next) => {
    const g = await st.grant
    const level = (splitArgs(e.args)[0] ?? '').toLowerCase()
    if (g !== 'high' && (level === 'xhigh' || level === 'max')) {
      st.chosen = level
      $.ui.invalidate('ui.render')
      return { text: `Set effort level to ${level} (this session only; opened in an Aionas window).` }
    }
    if (g !== 'high' && ['low', 'medium', 'high', 'auto'].includes(level)) {
      st.chosen = undefined
      $.ui.invalidate('ui.render')
    }
    if (EFFORT_ARGS.includes(level) && (await $.env.get('CLAUDE_CODE_EFFORT_LEVEL')) !== undefined) {
      await $.env.set('CLAUDE_CODE_EFFORT_LEVEL', level === 'auto' ? undefined : level)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'aionas-bypass' }, async ($, e) => {
    const r = await bypass($, splitArgs(e.args))
    await refresh($)
    return { text: r.out || 'aionas-bypass could not run (bash was not found).', exitCode: r.code === 0 ? 0 : 1 }
  })

  on('command.run', { command: 'aionas-done' }, async $ => {
    const r = await done($)
    return { text: r.out || 'aionas-done could not run (bash was not found).', exitCode: r.code === 0 ? 0 : 1 }
  })

  // A /clear goes on under a new session id with no session.start: the band
  // reads the new session's facts.
  on('session.end', async ($, e, next) => {
    const r = await next(e)
    if (e.reason === 'clear') void adoptNewSession($, e.sessionId).catch(() => undefined)
    return r
  })

  on('command.run', { command: 'aionas-xhigh' }, async ($, e) => {
    const r = await run($, [script($.plugin.root, 'commands/aionas-xhigh.sh'), ...splitArgs(e.args)])
    return { text: r.out || 'aionas-xhigh could not run (bash was not found).', exitCode: r.code === 0 ? 0 : 1 }
  })

  on('skill.prompt', async ($, e, next) => {
    if (e.pluginName !== 'aionas-savings' || !e.skill.endsWith('write-minimum')) return next(e)
    const row = st.facts?.methods.find(m => m.id === 'write_minimum')
    if (row !== undefined && !row.isActive) {
      void bypass($, ['--count', 'write_minimum', 'skipped'])
      return { text: 'The Aionas "write the minimum" method is off for you right now. Ignore this skill and work as usual.' }
    }
    void bypass($, ['--count', 'write_minimum', 'fired'])
    return next(e)
  })

  // After a main-loop turn, and again once the handoff timer has had time to
  // arm (its Stop hook waits up to 15 s for the turn's answer): the countdown
  // shows within seconds, not at the next 30 s read.
  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) {
      void refresh($)
      $.clock.after(20_000, () => void refresh($))
    }
    return done
  })

  // The live context, pushed by the engine (§4.3): the warning row and the
  // handoff chip's size. Redraw only when what the band shows moves.
  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('context')) {
      const t = e.context.tokens ?? 0
      const shown = (n: number) => Math.round(n / 1000)
      const isChanged = shown(t) !== shown(st.contextTokens) || e.context.window !== st.contextWindow
      st.contextTokens = t
      st.contextWindow = e.context.window
      if (isChanged) $.ui.invalidate('ui.render')
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    if (e.surface !== 'terminal' && e.surface !== 'desktop') return next(e)
    st.isDrawn = true
    if (st.facts === undefined) await st.listed
    const facts = st.facts
    if (facts === undefined || facts.methods.length === 0) return next(e)
    return drawBand(
      $,
      e,
      {
        facts,
        route: routeOf(st.baseUrl, facts.gatewayHost),
        isFull: st.isFull,
        isWorking: e.props.isWorking,
        columns: e.props.bodyColumns,
        sessionLevel: shownLevel(),
        isGranted: (await st.grant) !== 'high',
        contextTokens: st.contextTokens,
        contextWindow: st.contextWindow,
        laterAt: st.laterAt,
      },
      {
        chip: a => void press($, a),
        more: () => redraw($, () => (st.isFull = true)),
        less: () => redraw($, () => (st.isFull = false)),
        xhigh: () => void press($, { kind: 'xhigh', method: 'effort_default' }),
        compact: () => void compactNow($),
        later: () => redraw($, () => (st.laterAt = st.contextTokens + 50_000)),
        done: () => void done($).then(r => $.ui.toast(r.out || 'aionas could not run (bash was not found).')),
        newChat: () => void newChat($, e.surface),
      },
    )
  })
}
