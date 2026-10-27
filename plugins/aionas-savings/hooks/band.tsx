// The aionas mod band above the prompt (wave-24 mod spec §3, §4, §6). Owners:
// AIO-855, AIO-859. Imported statically by hooks/mod.tsx (a plugin has one
// hooks module); this file only parses the band's facts and draws them.
//
// Facts come from `aionas-bypass.sh --band` (numbers and names only; the
// `me` and `savings` blocks are optional) and the live context from
// `session.measure`. Nothing here reads a prompt, a reply, tool output or the
// alias credential, and nothing here sends anything (W24-4, spec §7).
import type { EngineInterface, RenderInput } from 'claude-code'

export type Me = { name: string; org: string; role: string; lead: string; computer: string }
export type Savings = {
  kind: 'usd' | 'api_value'
  // AIO-867: since-on is cumulative from the first full day after install;
  // amounts may be negative (regressions net) and are null with no data.
  todayUsd: number | null
  sinceUsd: number | null
  todayTokens: number | null
  sinceTokens: number | null
  sinceDate: string
  // The potential: what could have been saved in the 30 days before install.
  couldUsd: number | null
  couldTokens: number | null
  // Whole UTC days since-on covers; 0 on the install day, null without one.
  countedDays: number | null
  asOf: number
}
export type MethodFact = {
  id: string
  state: 'on' | 'off'
  isActive: boolean
  isSelfOverride: boolean
  isReleased: boolean
  bypassUntil: number
  isRequestPending: boolean
  firedToday: number
}
// The session's handoff (hooks/stop-handoff.sh writes it, --band reads it):
// armed counts down to `due`; delivered counts down to `coldAt`, when the
// prompt cache this session paid for runs out; ended = the person said done.
export type HandoffFact = {
  status: 'armed' | 'delivered' | 'ended' | undefined
  due: number
  coldAt: number
  hasDoc: boolean
}
export type Facts = {
  now: number
  tzOffset: number
  me?: Me
  savings?: Savings
  methods: MethodFact[]
  window: { level: 'xhigh' | 'max' | undefined; until: number; grant: string }
  compactAt: number
  idleMinutes: number
  gatewayHost: string | undefined
  handoff: HandoffFact
}

export type Action = { kind: 'bypass' | 'end' | 'xhigh'; method: string }
export type Chip = {
  method: string
  key: string
  text: string
  tone: 'on' | 'bypassed' | 'pending' | 'dim' | 'window'
  action: Action | undefined
}

// Short chip labels (spec §3.1); cache_alert, seat_fit and cache_guard never
// get a chip.
export const CHIP_LABELS: Record<string, string> = {
  effort_default: 'medium',
  subagent_sonnet: 'sonnet subagents',
  output_trim: 'trim',
  handoff: 'handoff',
  unused_services: 'unused off',
  write_minimum: 'write-min',
}

// One plain sentence per chip (what it does), shown in a row under
// the band while the pointer is on the chip; `window` is the open xhigh
// window's chip, `saved` the saved-today figure.
export const TIPS: Record<string, string> = {
  effort_default: 'New sessions start at medium; high is the most you can pick.',
  window: 'Sessions you open before the timer ends may go up to xhigh or max.',
  subagent_sonnet: 'Sub-agents that do not pick a model run on Sonnet.',
  output_trim: 'Noisy commands are shortened; long output shows only its start, its end and the errors.',
  handoff: 'A long chat left idle gets a note to go on in a new session.',
  handoff_done: 'Writes no handoff doc for this session. A new message here takes it back.',
  handoff_new: 'Opens a new conversation that starts from the doc. This one is kept, so you can come back to it.',
  unused_services: 'Tools unused for 30 days are turned off; /mcp turns one back on.',
  write_minimum: 'Claude writes only what the task needs.',
  saved:
    'An estimate since the first full day after install, net of anything that got worse. On a subscription plan it is not money you were charged.',
}
const CLICK: Record<Action['kind'], string> = {
  bypass: 'Click: off for you for 1 hour.',
  end: 'Click: back on.',
  xhigh: 'Click: for 10 min, new sessions may go up to xhigh or max.',
}
export const tipOf = (c: Chip): string => {
  const base = `${c.tone === 'dim' ? 'Off now. ' : ''}${TIPS[c.tone === 'window' ? 'window' : c.method] ?? ''}`
  return c.action === undefined ? base : `${base} ${CLICK[c.action.kind]}`
}
export const tipScope = (id: string): string => `aionas-tip-${id}`

const int = (s: string | undefined): number => (s !== undefined && /^[0-9]+$/.test(s) ? Number(s) : 0)
const name = (s: string | undefined): string => (s === undefined || s === '-' ? '' : s)
const sint = (s: string | undefined): number | null => (s !== undefined && /^-?[0-9]+$/.test(s) ? Number(s) : null)
const amount = (s: string | undefined): number | null => {
  if (s === undefined || s === '-' || s.trim() === '') return null
  const n = Number(s)
  return Number.isFinite(n) ? n : null
}

// The lines of `aionas-bypass.sh --band` -> Facts. Unknown or malformed lines
// are skipped; a missing me/savings line leaves that half out.
export const parseBand = (out: string): Facts => {
  const f: Facts = {
    now: 0,
    tzOffset: 0,
    methods: [],
    window: { level: undefined, until: 0, grant: '-' },
    compactAt: 200000,
    idleMinutes: 55,
    gatewayHost: undefined,
    handoff: { status: undefined, due: 0, coldAt: 0, hasDoc: false },
  }
  let armedAt = 0
  for (const line of out.split('\n')) {
    const p = line.split('\t')
    switch (p[0]) {
      case 'clock':
        f.now = int(p[1])
        f.tzOffset = /^-?[0-9]+$/.test(p[2] ?? '') ? Number(p[2]) : 0
        break
      case 'me':
        if (p.length === 6 && name(p[1]) !== '')
          f.me = { name: name(p[1]), org: name(p[2]), role: name(p[3]), lead: name(p[4]), computer: name(p[5]) }
        break
      case 'savings':
        if (p.length === 11 && (p[1] === 'usd' || p[1] === 'api_value'))
          f.savings = {
            kind: p[1],
            todayUsd: amount(p[2]),
            sinceUsd: amount(p[3]),
            todayTokens: sint(p[4]),
            sinceTokens: sint(p[5]),
            sinceDate: /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(p[6] ?? '') ? (p[6] as string) : '',
            couldUsd: amount(p[7]),
            couldTokens: sint(p[8]),
            countedDays: sint(p[9]),
            asOf: int(p[10]),
          }
        break
      case 'method':
        if (p.length === 9 && (p[1] ?? '') in CHIP_LABELS && (p[2] === 'on' || p[2] === 'off'))
          f.methods.push({
            id: p[1] as string,
            state: p[2],
            isActive: p[3] === '1',
            isSelfOverride: p[4] === '1',
            isReleased: p[5] === '1',
            bypassUntil: int(p[6]),
            isRequestPending: p[7] === '1',
            firedToday: int(p[8]),
          })
        break
      case 'window':
        f.window = {
          level: p[1] === 'xhigh' || p[1] === 'max' ? p[1] : undefined,
          until: int(p[2]),
          grant: p[3] ?? '-',
        }
        break
      case 'compact_at':
        if (int(p[1]) > 0) f.compactAt = int(p[1])
        if (int(p[2]) > 0) f.idleMinutes = int(p[2])
        break
      case 'handoff':
        f.handoff = {
          status: p[1] === 'armed' || p[1] === 'delivered' || p[1] === 'ended' ? p[1] : undefined,
          due: int(p[2]),
          coldAt: int(p[3]),
          hasDoc: p[4] === '1',
        }
        armedAt = int(p[5])
        break
      case 'gateway_host':
        f.gatewayHost = p[1] !== undefined && p[1] !== '-' && p[1] !== '' ? p[1].toLowerCase() : undefined
        break
    }
  }
  // A timer of an older version writes no deadline: it is the arm time plus
  // the idle minutes (at most 58, the Stop hook's own bound).
  if (f.handoff.status === 'armed' && f.handoff.due === 0 && armedAt > 0)
    f.handoff.due = armedAt + Math.min(f.idleMinutes * 60, 3480)
  return f
}

// 950 -> "950", 61000 -> "61K", 1400000 -> "1.4M", 1000000 -> "1M".
export const fmtTokens = (n: number): string => {
  if (n < 1000) return String(Math.max(0, Math.round(n)))
  if (n < 1_000_000) return `${Math.round(n / 1000)}K`
  return `${String(Math.round(n / 100_000) / 10)}M`
}

// Never a negative amount: no saving is drawn as a dash, never "-$".
export const fmtUsd = (v: number | null, approx: '~' | '≈ ' = '~'): string =>
  v === null || v <= 0 ? '—' : `${approx}$${v.toFixed(2)}`

// The local wall-clock time of an epoch, as this computer shows it.
export const hhmm = (epoch: number, tzOffset: number): string => {
  const d = new Date((epoch + tzOffset) * 1000)
  return `${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}`
}

export const mss = (seconds: number): string => {
  const s = Math.max(0, Math.floor(seconds))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export const isWindowOpen = (f: Facts): boolean => f.window.level !== undefined && f.window.until > f.now

// Whole minutes left, at least 1 while any time is left.
export const minutesLeft = (until: number, now: number): number => Math.max(1, Math.ceil((until - now) / 60))

// What the handoff row shows (AIO-874): counting down to the doc, counting
// down to cold, or cold with the doc ready; nothing otherwise.
export type HandoffView = 'due' | 'warm' | 'cold' | undefined
export const handoffView = (f: Facts): HandoffView => {
  const h = f.handoff
  if (h.status === 'armed' && h.due > f.now) return 'due'
  if (h.status !== 'delivered' || !h.hasDoc) return undefined
  return h.coldAt > f.now ? 'warm' : 'cold'
}
// The band reads its facts again every 15 s while a countdown runs.
export const isCounting = (f: Facts): boolean => isWindowOpen(f) || handoffView(f) === 'due' || handoffView(f) === 'warm'

// gateway when ANTHROPIC_BASE_URL's host is the enrolled gateway's (§4.3).
export const routeOf = (baseUrl: string | undefined, gatewayHost: string | undefined): 'gateway' | 'subscription' => {
  if (baseUrl === undefined || baseUrl.trim() === '' || gatewayHost === undefined) return 'subscription'
  const plain = (h: string): string => h.toLowerCase().replace(/:(443|80)$/, '')
  try {
    return plain(new URL(baseUrl.trim()).host) === plain(gatewayHost) ? 'gateway' : 'subscription'
  } catch {
    return 'subscription'
  }
}

// One chip per client method the person has, in the band's order (§3.3).
export const chipsOf = (
  f: Facts,
  opts: { isFull: boolean; sessionLevel: string | undefined; contextTokens: number },
): Chip[] =>
  f.methods.map(m => {
    const base = m.id === 'effort_default' ? (opts.sessionLevel ?? CHIP_LABELS.effort_default) : (CHIP_LABELS[m.id] as string)
    const key = `aionas-chip-${m.id}`
    const chip = (text: string, tone: Chip['tone'], action?: Action['kind']): Chip => ({
      method: m.id,
      key,
      text,
      tone,
      action: action === undefined ? undefined : { kind: action, method: m.id },
    })
    if (m.id === 'effort_default' && isWindowOpen(f))
      return chip(`◆ higher effort allowed · ${mss(f.window.until - f.now)} left`, 'window')
    if (m.isReleased) return chip(`○ ${base} · released`, 'dim')
    if (m.state === 'off') return chip(`○ ${base}`, 'dim')
    if (!m.isActive) {
      const until = m.bypassUntil > 0 ? ` until ${hhmm(m.bypassUntil, f.tzOffset)}` : ''
      // Effort is never "bypassed" by a chip (§3.3): display only.
      return chip(`◌ ${base} · off${until}`, 'bypassed', m.id === 'effort_default' ? undefined : 'end')
    }
    if (m.isRequestPending) return chip(`◌ ${base} · request pending`, 'pending')
    let extra = ''
    if (opts.isFull) {
      if (m.id === 'handoff') extra = ` · ${fmtTokens(opts.contextTokens)}`
      else if (m.id !== 'effort_default' && m.firedToday > 0) extra = ` · ${m.firedToday} today`
    }
    // The effort chip's press asks for the window, so it says so (AIO-868).
    if (m.id === 'effort_default') return chip(`● ${base} · allow more`, 'on', 'xhigh')
    return chip(`● ${base}${extra}`, 'on', 'bypass')
  })

// A figure is measured when it is above zero: tokens for a subscription
// (API value), dollars otherwise. Zero, a regression or no data reads as
// "No saving measured yet", never as a negative number.
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
export const dayLabel = (iso: string): string => {
  const m = /^[0-9]{4}-([0-9]{2})-([0-9]{2})$/.exec(iso)
  return m === null ? '' : `${Number(m[2])} ${MONTHS[Number(m[1]) - 1] ?? ''}`
}
const isMeasured = (kind: Savings['kind'], usd: number | null, tokens: number | null): boolean =>
  kind === 'api_value' ? tokens !== null && tokens > 0 : usd !== null && usd > 0
const figure = (kind: Savings['kind'], usd: number | null, tokens: number | null): { amount: string; tail: string } =>
  kind === 'api_value'
    ? { amount: `${fmtTokens(tokens ?? 0)} tokens`, tail: usd !== null && usd > 0 ? ` (${fmtUsd(usd, '≈ ')} API value)` : '' }
    : { amount: fmtUsd(usd), tail: '' }
const plain = (x: { amount: string; tail: string }): string => `${x.amount}${x.tail}`

// The potential is shown next to the figure for the first 14 counted days.
export const potentialLine = (s: Savings): string | undefined => {
  if (s.countedDays !== null && s.countedDays >= 14) return undefined
  if (!isMeasured(s.kind, s.couldUsd, s.couldTokens)) return undefined
  return `potential this month ${plain(figure(s.kind, s.couldUsd, s.couldTokens))}`
}

// One line: "saved since 21 Oct <amount><tail>", the amount drawn strong.
export const savedParts = (s: Savings): { lead: string; amount: string; tail: string } => {
  const potential = potentialLine(s)
  const more = potential === undefined ? '' : ` · ${potential}`
  if (!isMeasured(s.kind, s.sinceUsd, s.sinceTokens)) return { lead: 'No saving measured yet', amount: '', tail: more }
  const f = figure(s.kind, s.sinceUsd, s.sinceTokens)
  const since = dayLabel(s.sinceDate)
  return { lead: since === '' ? 'saved ' : `saved since ${since} `, amount: f.amount, tail: `${f.tail} est.${more}` }
}

export const savedLine = (s: Savings): string => {
  const p = savedParts(s)
  return `${p.lead}${p.amount}${p.tail}`
}

// The full view: the cumulative figure with its counted days, today, the
// potential, and when the server computed it.
export const savedFull = (s: Savings, tzOffset: number): string => {
  const parts: string[] = []
  if (isMeasured(s.kind, s.sinceUsd, s.sinceTokens)) {
    const since = dayLabel(s.sinceDate)
    const days = s.countedDays !== null && s.countedDays > 0 ? ` (${s.countedDays} ${s.countedDays === 1 ? 'day' : 'days'})` : ''
    const head = since === '' ? 'saved' : `saved since ${since}`
    parts.push(`${head}${days} ${plain(figure(s.kind, s.sinceUsd, s.sinceTokens))}`)
    if (isMeasured(s.kind, s.todayUsd, s.todayTokens)) parts.push(`today ${plain(figure(s.kind, s.todayUsd, s.todayTokens))}`)
  } else parts.push('No saving measured yet')
  const potential = potentialLine(s)
  if (potential !== undefined) parts.push(potential)
  parts.push('estimated')
  if (s.asOf > 0) parts.push(`updated ${hhmm(s.asOf, tzOffset)}`)
  return parts.join(' · ')
}

const cells = (s: string): number => [...s].length

export type OneLine = { who: string; saved: string | undefined; chips: Chip[]; more: number }

// The one line (M1), fitted to `columns` (§3.1): drop the computer name, then
// the org, then the chips past the fourth (as "+N"). The name, saved-today
// and More always stay.
export const fitOneLine = (f: Facts, route: string, chips: Chip[], columns: number): OneLine => {
  const whoOf = (org: boolean, computer: boolean): string =>
    f.me === undefined
      ? route
      : [f.me.name, org ? f.me.org : '', computer ? f.me.computer : '', route].filter(x => x !== '').join(' · ')
  const saved = f.savings === undefined ? undefined : savedLine(f.savings)
  const width = (l: OneLine): number => {
    let w = cells(`aionas │ ${l.who} │ `) + (l.saved === undefined ? 0 : cells(l.saved) + 3)
    for (const c of l.chips) w += cells(c.text) + (c.action === undefined ? 1 : 5)
    if (l.more > 0) w += cells(`+${l.more}`) + 1
    return w + cells('[ More ]')
  }
  const tries: OneLine[] = [
    { who: whoOf(true, true), saved, chips, more: 0 },
    { who: whoOf(true, false), saved, chips, more: 0 },
    { who: whoOf(false, false), saved, chips, more: 0 },
    { who: whoOf(false, false), saved, chips: chips.slice(0, 4), more: Math.max(0, chips.length - 4) },
  ]
  return tries.find(l => width(l) <= columns) ?? (tries[tries.length - 1] as OneLine)
}

export type View = {
  facts: Facts
  route: 'gateway' | 'subscription'
  isFull: boolean
  isWorking: boolean
  columns: number
  sessionLevel: string | undefined
  isGranted: boolean
  contextTokens: number
  contextWindow: number
  laterAt: number
}

export type Handlers = {
  chip: (a: Action) => void
  more: () => void
  less: () => void
  xhigh: () => void
  compact: () => void
  later: () => void
  done: () => void
  newChat: () => void
}

export const isWarning = (v: View): boolean =>
  v.contextTokens >= v.facts.compactAt && v.contextTokens >= v.laterAt

// Tips (AIO-874, measured 2026-10-22). A graphical surface (the desktop app)
// shows neither a row revealed by a hover scope nor a Button's label, but it
// shows a card drawn absolute above the band, revealed by the hover of the
// keyed Box it sits in (the card itself unkeyed: a keyed Box is a scope of its
// own); showing it moves nothing. The terminal clips the band to its own rows,
// so there the tip stays the row under the band that a hover scope reveals.
export const CARD_MAX = 56
export const cardSize = (text: string): { width: number; rows: number } => {
  const width = Math.min(CARD_MAX, cells(text) + 4)
  return { width, rows: Math.ceil(cells(text) / (width - 4)) + 2 }
}
// The column each element starts at in a row of `gap`-spaced elements that
// wraps at `columns`, the first starting at `first`.
export const startsOf = (widths: number[], first: number, columns: number, gap = 1): number[] => {
  const out: number[] = []
  let x = first
  for (const w of widths) {
    if (x > 0 && x + w > columns) x = 0
    out.push(x)
    x += w + gap
  }
  return out
}
// Moves a card left as far as it needs to stay inside the band's columns.
export const cardLeft = (start: number, width: number, columns: number): number => Math.min(0, columns - start - width)
const chipCells = (c: Chip): number => cells(c.text) + (c.action === undefined ? 0 : 4)

// The band's tree for the terminal and the desktop (one tree; the desktop
// draws it with its own buttons and type sizes).
export function drawBand($: EngineInterface, e: RenderInput<'AbovePrompt', 'terminal' | 'desktop'>, v: View, on: Handlers) {
  const { Box, Text, Button } = $.ui.resolve(e)
  const f = v.facts
  const chips = chipsOf(f, { isFull: v.isFull, sessionLevel: v.sessionLevel, contextTokens: v.contextTokens })
  const handoff = f.methods.find(m => m.id === 'handoff')

  const isTerminal = e.surface === 'terminal'
  // The tip card of element `id` that starts at column `start` (a graphical
  // surface; the terminal draws tipRow instead).
  const card = (id: string, text: string, start: number) => {
    if (isTerminal) return undefined
    const size = cardSize(text)
    return (
      <Box
        position="absolute"
        top={-size.rows}
        left={cardLeft(start, size.width, v.columns)}
        width={size.width}
        display="none"
        hover={{ display: 'flex' }}
        borderStyle="round"
        borderDimColor
        paddingX={1}
      >
        <Text key={tipScope(id)}>{text}</Text>
      </Box>
    )
  }

  // A chip: its glyph in the state's color beside the Button (a desktop draws
  // a Button natively and drops its children's colors), on green, off and
  // bypassed grey; a display-only chip is one Text in that color.
  const chipEl = (c: Chip, start: number) => {
    const glyph = c.text.slice(0, 1)
    const rest = c.text.slice(2)
    const action = c.action
    const body =
      action !== undefined ? (
        <Box flexDirection="row" columnGap={1}>
          <Text color={c.tone === 'on' ? 'success' : c.tone === 'pending' ? 'warning' : undefined} dimColor={c.tone === 'bypassed' || c.tone === 'dim'}>
            {glyph}
          </Text>
          <Button key={c.key} label={rest} dimColor={c.tone !== 'on'} onPress={() => on.chip(action)} />
        </Box>
      ) : c.tone === 'on' ? (
        <Text>
          <Text color="success">{glyph}</Text>
          {c.text.slice(1)}
        </Text>
      ) : c.tone === 'window' ? (
        <Text color="merged" weight="semibold">
          {c.text}
        </Text>
      ) : c.tone === 'pending' ? (
        <Text color="warning">{c.text}</Text>
      ) : (
        <Text dimColor>{c.text}</Text>
      )
    return (
      <Box key={`aionas-tipat-${c.method}`} hover={isTerminal ? { scope: tipScope(c.method) } : undefined}>
        {body}
        {card(c.method, tipOf(c), start)}
      </Box>
    )
  }
  // The terminal's tips: a row under the band, every tip drawn hidden and the
  // hovered element's revealed through its scope (as before AIO-874).
  const tipRow = (key: string, tips: { id: string; text: string }[]) =>
    isTerminal ? (
      <Box key={key} flexDirection="column">
        {tips.map(t => (
          <Box key={tipScope(t.id)} display="none" hover={{ scope: tipScope(t.id), display: 'flex' }}>
            <Text dimColor>{t.text}</Text>
          </Box>
        ))}
      </Box>
    ) : undefined
  const chipTips = (shown: Chip[]) => [
    ...(f.savings === undefined ? [] : [{ id: 'saved', text: TIPS.saved as string }]),
    ...shown.map(c => ({ id: c.method, text: tipOf(c) })),
  ]

  const chipEls = (shown: Chip[], first: number) => {
    const at = startsOf(shown.map(chipCells), first, v.columns)
    return shown.map((c, i) => chipEl(c, at[i] ?? 0))
  }

  const rows = []
  if (!v.isFull) {
    const line = fitOneLine(f, v.route, chips, v.columns)
    const lead = `aionas │ ${line.who}${f.savings === undefined ? '' : ` │ ${savedLine(f.savings)}`} │`
    rows.push(
      <Box key="aionas-line" flexDirection="row" flexWrap="wrap" columnGap={1}>
        <Box key="aionas-tipat-saved" hover={isTerminal ? { scope: tipScope('saved') } : undefined}>
        <Text>
          <Text color="claude" weight="bold">
            aionas
          </Text>
          <Text dimColor> │ </Text>
          {f.me === undefined ? <Text dimColor>{line.who}</Text> : <Text>{f.me.name}</Text>}
          {f.me !== undefined && line.who !== f.me.name && <Text dimColor>{line.who.slice(f.me.name.length)}</Text>}
          {f.savings !== undefined && <Text dimColor> │ </Text>}
          {f.savings !== undefined && <Text>{savedParts(f.savings).lead}</Text>}
          {f.savings !== undefined && (
            <Text color="success" weight="bold">
              {savedParts(f.savings).amount}
            </Text>
          )}
          {f.savings !== undefined && <Text dimColor>{savedParts(f.savings).tail}</Text>}
          <Text dimColor> │</Text>
        </Text>
        {f.savings !== undefined && card('saved', TIPS.saved as string, 0)}
        </Box>
        {chipEls(line.chips, cells(lead) + 1)}
        {line.more > 0 && <Text dimColor>+{line.more}</Text>}
        <Button key="aionas-more" label="More" dimColor onPress={on.more} />
      </Box>,
      tipRow('aionas-tips', chipTips(line.chips)),
    )
  } else {
    const me = f.me
    const who = [
      me?.name,
      me?.org,
      me?.role,
      me !== undefined && me.lead !== '' ? `lead ${me.lead}` : '',
      me !== undefined && me.computer !== '' ? `computer ${me.computer}` : '',
      `via ${v.route}`,
    ]
      .filter((x): x is string => x !== undefined && x !== '')
      .join(' · ')
    rows.push(
      <Text key="aionas-who">
        <Text color="claude" weight="bold">
          aionas
        </Text>
        {'  '}
        {who}
      </Text>,
    )
    if (f.savings !== undefined)
      rows.push(
        <Box key="aionas-tipat-saved" hover={isTerminal ? { scope: tipScope('saved') } : undefined}>
          <Text key="aionas-saved">{savedFull(f.savings, f.tzOffset)}</Text>
          {card('saved', TIPS.saved as string, 0)}
        </Box>,
      )
    rows.push(
      <Box key="aionas-chips" flexDirection="row" flexWrap="wrap" columnGap={1}>
        {chipEls(chips, 0)}
      </Box>,
      tipRow('aionas-tips', chipTips(chips)),
    )
    rows.push(
      <Box key="aionas-buttons" flexDirection="row" columnGap={1}>
        {!isWindowOpen(f) && <Button key="aionas-xhigh" label="allow higher effort for 10 min" onPress={on.xhigh} />}
        <Button key="aionas-less" label="Less" dimColor onPress={on.less} />
      </Box>,
    )
  }

  if (isWindowOpen(f)) {
    const minutes = Math.max(1, Math.ceil((f.window.until - f.now) / 60))
    const self = !v.isGranted
      ? 'stays at high or below'
      : v.sessionLevel === 'xhigh' || v.sessionLevel === 'max'
        ? `is at ${v.sessionLevel}`
        : 'may too'
    rows.push(
      <Text key="aionas-window" dimColor>
        sessions you open in the next {String(minutes)} min may use /effort xhigh (Extra) or max · this one {self}
      </Text>,
    )
  }

  const hv = handoff?.isActive === true ? handoffView(f) : undefined
  if (hv !== undefined) {
    const text =
      hv === 'due'
        ? `◷ Handoff doc in ${minutesLeft(f.handoff.due, f.now)} min if this chat stays idle.`
        : hv === 'warm'
          ? `◷ Handoff doc written. This chat goes cold in ${minutesLeft(f.handoff.coldAt, f.now)} min.`
          : '◷ This chat is cold: going on here reads all of it again.'
    rows.push(
      <Box key="aionas-handoff" flexDirection="row" flexWrap="wrap" columnGap={1}>
        <Text color={hv === 'cold' ? 'warning' : undefined} dimColor={hv !== 'cold'}>
          {text}
        </Text>
        {hv === 'due' && (
          <Box key="aionas-tipat-handoff_done" hover={isTerminal ? { scope: tipScope('handoff_done') } : undefined}>
            <Button key="aionas-handoff-done" label="Done with this chat" dimColor onPress={on.done} />
            {card('handoff_done', TIPS.handoff_done as string, cells(text) + 1)}
          </Box>
        )}
        {hv === 'cold' && (
          <Box key="aionas-tipat-handoff_new" hover={isTerminal ? { scope: tipScope('handoff_new') } : undefined}>
            <Button key="aionas-handoff-new" label="Continue in a new conversation" variant="primary" onPress={on.newChat} />
            {card('handoff_new', TIPS.handoff_new as string, cells(text) + 1)}
          </Box>
        )}
      </Box>,
      tipRow('aionas-handoff-tips', [
        ...(hv === 'due' ? [{ id: 'handoff_done', text: TIPS.handoff_done as string }] : []),
        ...(hv === 'cold' ? [{ id: 'handoff_new', text: TIPS.handoff_new as string }] : []),
      ]),
    )
  }

  if (isWarning(v)) {
    const idle = handoff?.isActive === true && f.handoff.status === undefined ? ` Idle ${f.idleMinutes} min → a handoff doc is written.` : ''
    rows.push(
      <Box key="aionas-warning" flexDirection="row" flexWrap="wrap" columnGap={1}>
        <Text color="warning">
          ▲ Context {fmtTokens(v.contextTokens)} of {fmtTokens(v.contextWindow)}. Compact recommended.{idle}
        </Text>
        {!v.isWorking && <Button key="aionas-compact" label="/compact" variant="primary" onPress={on.compact} />}
        <Button key="aionas-later" label="Later" dimColor onPress={on.later} />
      </Box>,
    )
  }

  return (
    <Box key="aionas-band" flexDirection="column">
      {rows}
    </Box>
  )
}
