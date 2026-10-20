// aionas-savings mod (Claude Code 2.1.299 function hooks). Owners: AIO-855, AIO-859.
//
// - The aionas mod band above the prompt (terminal and desktop; VS Code draws
//   no mod in 2.1.299), drawn by hooks/band.tsx per the wave-24 mod spec: one
//   line by default with More (M1), per-method chips whose one click bypasses
//   that method for 1 hour or ends my bypass (M3), the effort chip with the
//   xhigh window's countdown, and the warning row with /compact above
//   compact_at. /compact runs only when pressed: never automatically. No
//   thumbs up/down and no "pause all" in this wave (W24-5, M3).
// - The slash commands /aionas-bypass and /aionas-xhigh, answered here without
//   a model turn; the work is done by commands/*.sh, run by argument vector
//   (no shell), so nothing the person types is ever parsed by a shell.
// - The effort grant of W24-3: a session opened in an /aionas-xhigh window
//   (or while effort_default is off for the person) gets its level per main-
//   loop request through CLAUDE_CODE_EXTRA_BODY, set just before the request
//   and put back right after it, so tools and subagents never inherit it.
//   Every other session is left to the settings cap (maxEffortLevel=high).
// - The "write the minimum" skill expands to a no-op when the method is off.
//
// Privacy (W24-4): nothing here sends anything; the scripts send only method
// ids, durations, closed-set params and a reason the person typed. The band
// reads its facts through `aionas-bypass.sh --band` (numbers and names) and
// the context size from session.measure; it never calls $.http.fetch or
// $.session.messages, nor reads ~/.claude/projects or the alias credential.
import type { EngineInterface, Register } from 'claude-code'
import { drawBand, isWindowOpen, parseBand, routeOf } from './band.tsx'
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

// The session's state. Module variables: a reload (a new module) starts them
// over, and session.start (which a reload fires again) reads them back from
// the scripts, which keep the grant pinned per session on disk.
const st = {
  sid: '',
  bash: 'bash',
  grant: Promise.resolve<Grant>('high'),
  chosen: undefined as Level | undefined,
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
// press and after each main-loop turn. One read at a time. While an xhigh
// window is open a 15 s timer keeps its countdown moving; it stops with it.
function refresh($: EngineInterface): Promise<void> {
  if (st.refreshing !== undefined) return st.refreshing
  const p = (async () => {
    const r = await bypass($, ['--band'])
    if (r.code !== 0 || r.out === '') return
    st.facts = parseBand(r.out)
    const isOpen = isWindowOpen(st.facts)
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

async function readGrant($: EngineInterface): Promise<Grant> {
  const r = await run($, [script($.plugin.root, 'hooks/effort-window.sh'), 'grant', st.sid])
  const g = parseGrant(r.out)
  st.chosen = g === 'xhigh' || g === 'max' ? g : undefined
  return g
}

async function press($: EngineInterface, a: Action): Promise<void> {
  const r =
    a.kind === 'xhigh'
      ? await run($, [script($.plugin.root, 'commands/aionas-xhigh.sh')])
      : await bypass($, a.kind === 'end' ? ['--end', a.method] : [a.method, '1h'])
  $.ui.toast(r.out || 'aionas could not run (bash was not found).')
  await refresh($)
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
      name: 'aionas-xhigh',
      description: 'Aionas: sessions you open in the next 10 minutes start at xhigh (or max)',
      argumentHint: '[max] [reason]',
    })
    st.sid = await $.session.id()
    // Windows: Claude Code's own Git Bash, never whatever "bash" PATH finds (WSL).
    st.bash = (await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) ?? 'bash'
    st.baseExtra = await $.env.get('CLAUDE_CODE_EXTRA_BODY')
    st.baseUrl = await $.env.get('ANTHROPIC_BASE_URL')
    // Not awaited: the session never waits on a process; a request waits only
    // in the rare case it is sent before the grant is read.
    st.grant = readGrant($)
    st.listed = refresh($)
    st.tick?.cancel()
    st.tick = undefined
    // The 30 s refresh only where a band is drawn (an interactive session).
    if (e.isInteractive) st.tick = $.clock.every(30_000, () => void refresh($))
    return next(e)
  })

  // The granted level for each main-loop request; back to the user's own value
  // as soon as the request is sent and answered.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || e.effort === undefined) return yield* next(e)
    await st.grant
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
  on('command.run', { command: 'effort' }, async ($, e, next) => {
    const g = await st.grant
    if (g === 'high') return next(e)
    const level = (splitArgs(e.args)[0] ?? '').toLowerCase()
    if (level === 'xhigh' || level === 'max') {
      st.chosen = level
      return { text: `Set effort level to ${level} (this session only; opened in an Aionas window).` }
    }
    if (['low', 'medium', 'high', 'auto'].includes(level)) st.chosen = undefined
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'aionas-bypass' }, async ($, e) => {
    const r = await bypass($, splitArgs(e.args))
    await refresh($)
    return { text: r.out || 'aionas-bypass could not run (bash was not found).', exitCode: r.code === 0 ? 0 : 1 }
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

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) void refresh($)
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
        sessionLevel: st.chosen,
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
      },
    )
  })
}
