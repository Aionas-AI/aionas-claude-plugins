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
  todayUsd: number | null
  sinceUsd: number | null
  todayTokens: number
  sinceTokens: number
  sinceDate: string
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
  effort_default: 'high',
  subagent_sonnet: 'sonnet subagents',
  noisy_guard: 'guard',
  output_store: 'store',
  handoff: 'handoff',
  unused_services: 'unused off',
  write_minimum: 'write-min',
}

const int = (s: string | undefined): number => (s !== undefined && /^[0-9]+$/.test(s) ? Number(s) : 0)
const name = (s: string | undefined): string => (s === undefined || s === '-' ? '' : s)
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
  }
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
        if (p.length === 8 && (p[1] === 'usd' || p[1] === 'api_value'))
          f.savings = {
            kind: p[1],
            todayUsd: amount(p[2]),
            sinceUsd: amount(p[3]),
            todayTokens: int(p[4]),
            sinceTokens: int(p[5]),
            sinceDate: /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(p[6] ?? '') ? (p[6] as string) : '',
            asOf: int(p[7]),
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
      case 'gateway_host':
        f.gatewayHost = p[1] !== undefined && p[1] !== '-' && p[1] !== '' ? p[1].toLowerCase() : undefined
        break
    }
  }
  return f
}

// 950 -> "950", 61000 -> "61K", 1400000 -> "1.4M", 1000000 -> "1M".
export const fmtTokens = (n: number): string => {
  if (n < 1000) return String(Math.max(0, Math.round(n)))
  if (n < 1_000_000) return `${Math.round(n / 1000)}K`
  return `${String(Math.round(n / 100_000) / 10)}M`
}

export const fmtUsd = (v: number | null, approx: '~' | '≈ ' = '~'): string =>
  v === null ? '—' : `${approx}$${v.toFixed(2)}`

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
    const base = m.id === 'effort_default' ? (opts.sessionLevel ?? 'high') : (CHIP_LABELS[m.id] as string)
    const key = `aionas-chip-${m.id}`
    const chip = (text: string, tone: Chip['tone'], action?: Action['kind']): Chip => ({
      method: m.id,
      key,
      text,
      tone,
      action: action === undefined ? undefined : { kind: action, method: m.id },
    })
    if (m.id === 'effort_default' && isWindowOpen(f))
      return chip(`◆ ${f.window.level ?? 'xhigh'} window ${mss(f.window.until - f.now)} left`, 'window')
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
    return chip(`● ${base}${extra}`, 'on', m.id === 'effort_default' ? 'xhigh' : 'bypass')
  })

// "saved today <amount><tail>": the amount drawn strong, the rest plain/dim.
export const savedParts = (s: Savings): { amount: string; tail: string } =>
  s.kind === 'api_value'
    ? { amount: `${fmtTokens(s.todayTokens)} tokens`, tail: ` (${fmtUsd(s.todayUsd, '≈ ')} API value, est.)` }
    : { amount: fmtUsd(s.todayUsd), tail: ' est.' }

export const savedLine = (s: Savings): string => {
  const p = savedParts(s)
  return `saved today ${p.amount}${p.tail}`
}

export const sinceDays = (s: Savings, now: number, tzOffset: number): number | undefined => {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/.exec(s.sinceDate)
  if (m === null) return undefined
  const since = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86400000
  const today = Math.floor((now + tzOffset) / 86400)
  return Math.max(1, today - since + 1)
}

export const savedFull = (s: Savings, now: number, tzOffset: number): string => {
  const days = sinceDays(s, now, tzOffset)
  const span = days === undefined ? 'since on' : `since on (${days} ${days === 1 ? 'day' : 'days'})`
  const today =
    s.kind === 'api_value'
      ? `${fmtTokens(s.todayTokens)} tokens (${fmtUsd(s.todayUsd, '≈ ')} API value)`
      : fmtUsd(s.todayUsd)
  const since =
    s.kind === 'api_value'
      ? `${fmtTokens(s.sinceTokens)} tokens (${fmtUsd(s.sinceUsd, '≈ ')} API value)`
      : fmtUsd(s.sinceUsd)
  const updated = s.asOf > 0 ? ` · updated ${hhmm(s.asOf, tzOffset)}` : ''
  return `saved today ${today} · ${span} ${since} · estimated${updated}`
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
}

export const isWarning = (v: View): boolean =>
  v.contextTokens >= v.facts.compactAt && v.contextTokens >= v.laterAt

// The band's tree for the terminal and the desktop (one tree; the desktop
// draws it with its own buttons and type sizes).
export function drawBand($: EngineInterface, e: RenderInput<'AbovePrompt', 'terminal' | 'desktop'>, v: View, on: Handlers) {
  const { Box, Text, Button } = $.ui.resolve(e)
  const f = v.facts
  const chips = chipsOf(f, { isFull: v.isFull, sessionLevel: v.sessionLevel, contextTokens: v.contextTokens })
  const handoff = f.methods.find(m => m.id === 'handoff')

  const chipEl = (c: Chip) => {
    const body =
      c.tone === 'on' ? (
        <Text>
          <Text color="success">●</Text>
          {c.text.slice(1)}
        </Text>
      ) : c.tone === 'window' ? (
        <Text color="merged" weight="semibold">
          {c.text}
        </Text>
      ) : c.tone === 'dim' ? (
        <Text dimColor>{c.text}</Text>
      ) : (
        <Text color="warning">{c.text}</Text>
      )
    const action = c.action
    if (action === undefined) return body
    return (
      <Button key={c.key} label={c.text} onPress={() => on.chip(action)}>
        {body}
      </Button>
    )
  }

  const rows = []
  if (!v.isFull) {
    const line = fitOneLine(f, v.route, chips, v.columns)
    rows.push(
      <Box key="aionas-line" flexDirection="row" flexWrap="wrap" columnGap={1}>
        <Text>
          <Text color="claude" weight="bold">
            aionas
          </Text>
          <Text dimColor> │ </Text>
          {f.me === undefined ? <Text dimColor>{line.who}</Text> : <Text>{f.me.name}</Text>}
          {f.me !== undefined && line.who !== f.me.name && <Text dimColor>{line.who.slice(f.me.name.length)}</Text>}
          {f.savings !== undefined && <Text dimColor> │ </Text>}
          {f.savings !== undefined && <Text>saved today </Text>}
          {f.savings !== undefined && (
            <Text color="success" weight="bold">
              {savedParts(f.savings).amount}
            </Text>
          )}
          {f.savings !== undefined && <Text dimColor>{savedParts(f.savings).tail}</Text>}
          <Text dimColor> │</Text>
        </Text>
        {line.chips.map(chipEl)}
        {line.more > 0 && <Text dimColor>+{line.more}</Text>}
        <Button key="aionas-more" label="More" dimColor onPress={on.more} />
      </Box>,
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
    if (f.savings !== undefined) rows.push(<Text key="aionas-saved">{savedFull(f.savings, f.now, f.tzOffset)}</Text>)
    rows.push(
      <Box key="aionas-chips" flexDirection="row" flexWrap="wrap" columnGap={1}>
        {chips.map(chipEl)}
      </Box>,
    )
    rows.push(
      <Box key="aionas-buttons" flexDirection="row" columnGap={1}>
        {!isWindowOpen(f) && <Button key="aionas-xhigh" label="xhigh for 10 min" onPress={on.xhigh} />}
        <Button key="aionas-less" label="Less" dimColor onPress={on.less} />
      </Box>,
    )
  }

  if (isWindowOpen(f)) {
    const minutes = Math.max(1, Math.ceil((f.window.until - f.now) / 60))
    const self = v.sessionLevel === 'xhigh' || v.sessionLevel === 'max' ? `is ${v.sessionLevel}` : 'stays high'
    rows.push(
      <Text key="aionas-window" dimColor>
        new sessions in the next {String(minutes)} min start at {f.window.level ?? 'xhigh'} · this session {self}
      </Text>,
    )
  }

  if (isWarning(v)) {
    const idle = handoff?.isActive === true ? ` Idle ${f.idleMinutes} min → a handoff doc is written.` : ''
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
