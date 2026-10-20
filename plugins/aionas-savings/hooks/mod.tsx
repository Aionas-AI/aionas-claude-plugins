// aionas-savings mod (Claude Code 2.1.299 function hooks). Owners: AIO-855, AIO-859.
//
// - The band above the prompt (terminal and desktop): how many savings
//   methods are on, a self-override button ("Bypass…", 1 hour), and
//   "Compact recommended" once the context passes the handoff threshold. The
//   compact button only runs /compact when pressed: never automatically. No
//   thumbs up/down in this wave (W24-5).
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
// ids, durations, closed-set params and a reason the person typed.
import type { EngineInterface, Register } from 'claude-code'

type Grant = 'high' | 'xhigh' | 'max' | 'free'
type Level = 'xhigh' | 'max'
type Row = { method: string; state: string; isActive: boolean; isSelfOverride: boolean }
type Ran = { code: number; out: string }

const LABELS: Record<string, string> = {
  handoff: 'handoff document',
  effort_default: 'high effort default',
  subagent_sonnet: 'Sonnet for sub-agents',
  unused_services: 'unused services off',
  noisy_guard: 'noisy-command guard',
  output_store: 'long-output store',
  write_minimum: 'write the minimum',
}

export const parseRows = (out: string): { rows: Row[]; compactAt: number } => {
  const rows: Row[] = []
  let compactAt = 200000
  for (const line of out.split('\n')) {
    const [name = '', state = '', active, selfOverride, extra] = line.split('\t')
    if (name === 'compact_at' && /^[0-9]+$/.test(state)) compactAt = Number(state)
    else if (name in LABELS && selfOverride !== undefined && extra === undefined)
      rows.push({ method: name, state, isActive: active === '1', isSelfOverride: selfOverride === '1' })
  }
  return { rows, compactAt }
}

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
  rows: [] as Row[],
  compactAt: 200000,
  contextTokens: 0,
  isHidden: false,
  isPicking: false,
  listed: Promise.resolve(),
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

async function refresh($: EngineInterface): Promise<void> {
  const r = await bypass($, ['--list'])
  if (r.code !== 0) return
  const parsed = parseRows(r.out)
  st.rows = parsed.rows
  st.compactAt = parsed.compactAt
  $.ui.invalidate('ui.render')
}

async function readGrant($: EngineInterface): Promise<Grant> {
  const r = await run($, [script($.plugin.root, 'hooks/effort-window.sh'), 'grant', st.sid])
  const g = parseGrant(r.out)
  st.chosen = g === 'xhigh' || g === 'max' ? g : undefined
  return g
}

async function pickBypass($: EngineInterface, value: string): Promise<void> {
  st.isPicking = false
  if (value !== '-') {
    const r = await bypass($, [value, '1h'])
    $.ui.toast(r.out || 'aionas-bypass could not run.')
    await refresh($)
  }
  $.ui.invalidate('ui.render')
}

async function compactNow($: EngineInterface): Promise<void> {
  await $.command.run({ command: 'compact' })
}

function showPicker($: EngineInterface): void {
  st.isPicking = true
  $.ui.invalidate('ui.render')
}

function hideBand($: EngineInterface): void {
  st.isHidden = true
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
    // Not awaited: the session never waits on a process; a request waits only
    // in the rare case it is sent before the grant is read.
    st.grant = readGrant($)
    st.listed = refresh($)
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
    const row = st.rows.find(r => r.method === 'write_minimum')
    if (row !== undefined && !row.isActive) {
      void bypass($, ['--count', 'write_minimum', 'skipped'])
      return { text: 'The Aionas "write the minimum" method is off for you right now. Ignore this skill and work as usual.' }
    }
    void bypass($, ['--count', 'write_minimum', 'fired'])
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId === undefined) {
      try {
        const u = await $.session.usage()
        const t = u.context.tokens ?? 0
        if (t >= st.compactAt !== st.contextTokens >= st.compactAt) $.ui.invalidate('ui.render')
        st.contextTokens = t
      } catch {
        // no usage reading: the band keeps its last
      }
    }
    return done
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (st.rows.length === 0) await st.listed
    if (e.props.hasSurvey || st.isHidden || st.rows.length === 0) return next(e)
    if (e.surface !== 'terminal' && e.surface !== 'desktop') return next(e)
    const { Box, Text, Button, Select } = $.ui.resolve(e)
    const onCount = st.rows.filter(r => r.isActive).length
    const isOverCompact = st.contextTokens >= st.compactAt
    const choices = st.rows.filter(r => r.isActive)

    if (st.isPicking && choices.length > 0) {
      return (
        <Box key="aionas-pick" flexDirection="row">
          <Select
            key="aionas-bypass-method"
            label="Bypass for 1 hour: "
            autoFocus
            options={[
              ...choices.map(r => ({
                value: r.method,
                label: `${LABELS[r.method]}${r.isSelfOverride ? '' : ' (asks approval)'}`,
              })),
              { value: '-', label: 'cancel' },
            ]}
            onSelect={(value: string) => void pickBypass($, value)}
          />
        </Box>
      )
    }

    return (
      <Box key="aionas-band" flexDirection="row">
        <Text dimColor>
          Aionas savings: {onCount} of {st.rows.length} on{' '}
        </Text>
        {choices.length > 0 && (
          <Button
            key="aionas-bypass"
            label="Bypass…"
            dimColor
            onPress={() => showPicker($)}
          />
        )}
        {isOverCompact && (
          <Button
            key="aionas-compact"
            label="Compact recommended"
            variant="primary"
            onPress={() => void compactNow($)}
          />
        )}
        <Button
          key="aionas-hide"
          label="Hide"
          dimColor
          onPress={() => hideBand($)}
        />
      </Box>
    )
  })
}
