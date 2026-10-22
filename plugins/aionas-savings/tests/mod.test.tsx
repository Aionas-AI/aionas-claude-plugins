// The aionas-savings mod (hooks/mod.tsx + hooks/band.tsx), run by
// `claude plugin test` on Claude Code 2.1.299. The scripts it runs are mocked
// at process.run (the 2.1.299 kit has no `state` noun; the band is seeded
// through the scripts' fake output, wave-24 mod spec §9); their own behaviour
// is covered by tests/unit/*.test.sh in the repo.
import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { MockClock } from 'claude-code/testing'

const T0 = 1792490400 // 2026-10-20T10:00:00Z; the fixture's clock is UTC+3
const SURFACES = ['terminal', 'desktop'] as const

const BAND = {
  plugin: 'aionas-savings',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 220,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

type M = { state: 'on' | 'off'; active: 0 | 1; so: 0 | 1; released: 0 | 1; until: number; pending: 0 | 1; fired: number }
const ORDER = ['effort_default', 'subagent_sonnet', 'noisy_guard', 'output_store', 'handoff', 'unused_services', 'write_minimum']

type World = {
  argv: string[][]
  envSets: (string | undefined)[]
  env: Map<string, string | undefined>
  methods: Record<string, M>
  me: string | undefined
  savings: string | undefined
  window: string
  settings: Record<string, unknown>
  flag: Record<string, unknown>
  parentArgs: string
  compactAt: string
  handoff: string
  surfaces: string[]
  now: number
  bandReads: () => number
  clock: MockClock
  toasts: string[]
}

const ME = ['me', 'Noa Levi', 'Acme', 'member', 'Omer Katz', 'mbp-noa'].join('\t')
const SAVINGS_USD = ['savings', 'usd', '3.8', '46.2', '0', '0', '2026-10-08', '-', '-', '13', String(T0 + 300)].join('\t')
const SAVINGS_SUB = ['savings', 'api_value', '5.1', '40', '1400000', '9000000', '2026-10-08', '-', '-', '13', String(T0)].join('\t')

function bandOut(w: World): string {
  const lines = [`clock\t${w.now}\t10800`]
  if (w.me !== undefined) lines.push(w.me)
  if (w.savings !== undefined) lines.push(w.savings)
  for (const id of ORDER) {
    const m = w.methods[id] as M
    lines.push(['method', id, m.state, m.active, m.so, m.released, m.until, m.pending, m.fired].join('\t'))
  }
  // A line the band must never turn into a chip (required, gateway-side).
  lines.push(['method', 'cache_guard', 'on', 1, 0, 0, 0, 0, 0].join('\t'))
  lines.push(w.window, w.compactAt, w.handoff, 'gateway_host\tgw.example.test')
  return lines.join('\n')
}

function world(on: On, grant: string = 'high'): World {
  const env = new Map<string, string | undefined>()
  let reads = 0
  const methods: Record<string, M> = {}
  for (const id of ORDER) methods[id] = { state: 'on', active: 1, so: 1, released: 0, until: 0, pending: 0, fired: 0 }
  methods.handoff = { ...(methods.handoff as M), state: 'off', active: 0 }
  methods.noisy_guard = { ...(methods.noisy_guard as M), fired: 4 }
  const w: World = {
    argv: [],
    envSets: [],
    env,
    methods,
    me: ME,
    savings: SAVINGS_USD,
    window: 'window\t-\t0\thigh',
    settings: { effortLevel: 'medium', maxEffortLevel: 'high' },
    flag: {},
    parentArgs: '',
    compactAt: 'compact_at\t200000\t55',
    handoff: 'handoff\t-\t0\t0\t0',
    surfaces: ['terminal'],
    now: T0,
    bandReads: () => reads,
    clock: mock.clock(on, { now: T0 * 1000 }),
    toasts: [],
  }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-test-1' }))
  on('session.cwd', () => ({ value: '/work/my repo' }))
  on('session.surfaces', () => ({ value: w.surfaces }) as never)
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('env.get', ($, e) => ({ value: env.get(e.name) }))
  on('settings.read', ($, e) => ({ value: e.source === 'flag' ? w.flag : w.settings }) as never)
  on('session.measure', ($, e) => ({ changed: e.changed }))
  on('ui.toast', ($, e) => {
    w.toasts.push(String(e.text))
    return { value: undefined }
  })
  // The engine's own band beneath the plugin (what next(e) draws).
  on('ui.render', { component: 'AbovePrompt' }, () => ({ type: 'Text', props: {}, children: ['engine band'] }) as never)
  on('process.run', ($, e) => {
    w.argv.push([...e.argv])
    const a = e.argv.join(' ')
    const last = e.argv.slice(-2)
    let stdout = ''
    if (a.includes('effort-window.sh grant')) stdout = grant
    else if (a.includes('ps -o args=')) stdout = w.parentArgs
    else if (a.includes('--band')) {
      reads += 1
      stdout = bandOut(w)
    } else if (a.includes('--end')) {
      const id = last[1] as string
      w.methods[id] = { ...(w.methods[id] as M), active: 1, until: 0 }
      stdout = `${id} is back on for you on this computer, from now (new and running sessions).`
    } else if (a.includes('aionas-bypass.sh') && last[1] === '1h') {
      const id = last[0] as string
      const m = w.methods[id] as M
      if (m.so === 1) {
        w.methods[id] = { ...m, active: 0, until: w.now + 3600 }
        stdout = `${id} is off for you for 1 hour, from now (new and running sessions). Recorded with Aionas.`
      } else {
        w.methods[id] = { ...m, pending: 1 }
        stdout = `${id}: sent for approval to your org admin or lead. It applies from your next session once approved.`
      }
    } else if (a.includes('aionas-bypass.sh')) stdout = 'noisy_guard is off for you for 1 hour, from now. Reason: debugging a flaky test.'
    else if (a.includes('handoff-wake.sh end')) {
      w.handoff = 'handoff\tended\t0\t0\t0'
      stdout = 'Done: no handoff doc will be written for this chat. A new message here takes it back.'
    } else if (a.includes('handoff-wake.sh prompt')) stdout = 'Continue the work described in the handoff document /h/handoff-sess-test-1.md. Read it fully first.'
    else if (a.includes('aionas-xhigh.sh')) {
      w.window = `window\txhigh\t${w.now + 600}\thigh`
      stdout = 'Higher effort is allowed for 10 minutes: sessions you open now start at their usual level, and you may raise them to xhigh (Extra) or max with /effort.'
    }
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('env.set', ($, e) => {
    w.envSets.push(e.value)
    env.set(e.name, e.value)
    return { value: undefined }
  })
  return w
}

const TIPS_WINDOW = 'Sessions you open before the timer ends may go up to xhigh or max.'

const textOf = (n: any): string =>
  typeof n === 'string'
    ? n
    : n === null || typeof n !== 'object'
      ? ''
      : n.type === 'Button' && (n.children ?? []).length === 0
        ? `[ ${String(n.props?.label ?? '')} ]`
        : (n.children ?? []).map(textOf).join('')

// What a chip shows (its glyph and its Button or Text), without its tip.
async function chipText(ui: any, id: string): Promise<string> {
  const at = await ui.find({ key: `aionas-tipat-${id}` })
  if (at === undefined) return ''
  const shown = (at.children ?? []).filter((c: any) => c?.props?.position !== 'absolute')
  const flat = (n: any): string => (n?.type === 'Box' ? (n.children ?? []).map(flat).join(' ') : textOf(n))
  return shown.map(flat).join(' ').replace(/\[ (.*?) \]/g, '$1').replace(/\s+/g, ' ').trim()
}

const TIPS_SAVED =
  'An estimate since the first full day after install, net of anything that got worse. On a subscription plan it is not money you were charged.'

// The tip of element `id`: on the desktop the hidden absolute card inside its
// keyed Box; on the terminal the hidden row under the band its scope reveals.
async function cardOf(ui: any, id: string, surface = 'desktop'): Promise<any> {
  if (surface === 'terminal') {
    // The drawn tree carries hover on the element itself (find does not).
    let row: any
    const walk = (n: any): void => {
      if (n === null || typeof n !== 'object' || row !== undefined) return
      if (n.props?.key === `aionas-tip-${id}`) row = n
      for (const c of n.children ?? []) walk(c)
    }
    walk(await ui.drawn())
    expect(row).toBeDefined()
    return row
  }
  const at = await ui.find({ key: `aionas-tipat-${id}` })
  expect(at).toBeDefined()
  const card = (at.children ?? []).find((c: any) => c?.props?.position === 'absolute')
  expect(card).toBeDefined()
  return card
}

const scriptRuns =(w: World, script: string): string[][] => w.argv.filter(a => a.some(x => x.endsWith(script)))

async function start($: any): Promise<void> {
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
}

async function measure($: any, tokens: number): Promise<void> {
  await $.session.measure({ context: { tokens, window: 1000000 }, rateLimits: [], changed: ['context'] })
}

async function step($: any, effort: string | undefined, agentId?: string): Promise<void> {
  const stream = $.turn.step({ turnId: 't1', index: 0, model: 'claude-opus-5-5', effort, messageCount: 1, agentId })
  for await (const _chunk of stream) {
    // drain
  }
}

function bottomStep(on: On, w: World, seen: (string | undefined)[]): void {
  on('turn.step', async function* ($, e) {
    seen.push(w.env.get('CLAUDE_CODE_EXTRA_BODY'))
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
}

describe('band: one line and the full view (M1)', () => {
  test('one line shows who, saved today, the chips and More; More opens the full view and Less returns', async ($, on) => {
    world(on)
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: /aionas │ Noa Levi · Acme · mbp-noa · subscription │ saved since 8 Oct ~\$46\.20 est\./ })).toBeDefined()
      expect((await chipText(ui, 'noisy_guard'))).toContain('● guard')
      expect((await chipText(ui, 'effort_default'))).toBe('● medium · allow more')
      expect((await chipText(ui, 'subagent_sonnet'))).toContain('● sonnet subagents')
      expect(await ui.find({ type: 'Text', text: /^○ handoff$/ })).toBeDefined()
      expect(await ui.find({ key: 'aionas-more' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-hide' })).toBeUndefined()
      expect(await ui.find({ text: /👍|👎|Pause/ })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-compact' })).toBeUndefined()

      await ui.press({ key: 'aionas-more' })
      expect(await ui.find({ type: 'Text', text: /Noa Levi · Acme · member · lead Omer Katz · computer mbp-noa · via subscription/ })).toBeDefined()
      expect(
        await ui.find({ type: 'Text', text: 'saved since 8 Oct (13 days) ~$46.20 · today ~$3.80 · estimated · updated 13:05' }),
      ).toBeDefined()
      expect((await chipText(ui, 'noisy_guard'))).toContain('● guard · 4 today')
      expect((await ui.find({ key: 'aionas-xhigh' }))?.props.label).toBe('allow higher effort for 10 min')
      expect(await ui.find({ key: 'aionas-more' })).toBeUndefined()

      await ui.press({ key: 'aionas-less' })
      expect(await ui.find({ key: 'aionas-more' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-less' })).toBeUndefined()
      await ui.unmount()
    }
  })

  test('an old server (no me, no savings) shows the local half only', async ($, on) => {
    const w = world(on)
    w.me = undefined
    w.savings = undefined
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: /^aionas │ subscription │$/ })).toBeDefined()
      expect(await ui.find({ text: /saved since|No saving/ })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-chip-noisy_guard' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('cache_guard never draws a chip', async ($, on) => {
    world(on)
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ key: 'aionas-chip-cache_guard' })).toBeUndefined()
      expect(await ui.find({ text: /cache/ })).toBeUndefined()
      await ui.press({ key: 'aionas-more' })
      expect(await ui.find({ text: /cache/ })).toBeUndefined()
      await ui.press({ key: 'aionas-less' })
      await ui.unmount()
    }
  })

  test('hasSurvey: the band yields to the survey', async ($, on) => {
    world(on)
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, hasSurvey: true } })
      expect(await ui.find({ key: 'aionas-more' })).toBeUndefined()
      expect(await ui.find({ text: /aionas/ })).toBeUndefined()
      expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('narrow widths drop the computer, then the org, then the chips past the fourth (+N)', async ($, on) => {
    world(on)
    await start($)
    for (const surface of SURFACES) {
      let ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 209 } })
      expect(await ui.find({ type: 'Text', text: /Noa Levi · Acme · mbp-noa · subscription │/ })).toBeDefined()
      await ui.unmount()

      ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 208 } })
      expect(await ui.find({ type: 'Text', text: /Noa Levi · Acme · subscription │/ })).toBeDefined()
      expect(await ui.find({ text: /mbp-noa/ })).toBeUndefined()
      await ui.unmount()

      ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 194 } })
      expect(await ui.find({ type: 'Text', text: /aionas │ Noa Levi · subscription │ saved since 8 Oct/ })).toBeDefined()
      expect(await ui.find({ text: /Acme/ })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-chip-unused_services' })).toBeDefined()
      await ui.unmount()

      ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 60 } })
      expect(await ui.find({ type: 'Text', text: /aionas │ Noa Levi · subscription │ saved since 8 Oct ~\$46\.20 est\./ })).toBeDefined()
      expect(await ui.find({ text: /Acme|mbp-noa/ })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-chip-output_store' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-chip-unused_services' })).toBeUndefined()
      expect(await ui.find({ type: 'Text', text: '+3' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-more' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('a subscription user sees tokens and the API value; a gateway user sees the route', async ($, on) => {
    const w = world(on)
    w.savings = SAVINGS_SUB
    w.env.set('ANTHROPIC_BASE_URL', 'https://GW.example.test/anthropic')
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 300 } })
      expect(
        await ui.find({ type: 'Text', text: /mbp-noa · gateway │ saved since 8 Oct 9M tokens \(≈ \$40\.00 API value\) est\./ }),
      ).toBeDefined()
      await ui.press({ key: 'aionas-more' })
      expect(
        await ui.find({
          type: 'Text',
          text: 'saved since 8 Oct (13 days) 9M tokens (≈ $40.00 API value) · today 1.4M tokens (≈ $5.10 API value) · estimated · updated 13:00',
        }),
      ).toBeDefined()
      await ui.press({ key: 'aionas-less' })
      await ui.unmount()
    }
  })
})

describe('band: the savings figure (AIO-867)', () => {
  const line = (f: (string | number)[]): string => ['savings', ...f.map(String)].join('\t')
  test('install day: no number, the potential instead; never a negative amount', async ($, on) => {
    const w = world(on)
    w.savings = line(['api_value', '-', '-', '-', '-', '2026-10-20', '61.2', '2100000', '0', T0])
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 300 } })
      expect(
        await ui.find({ type: 'Text', text: /│ No saving measured yet · potential this month 2\.1M tokens \(≈ \$61\.20 API value\)/ }),
      ).toBeDefined()
      expect(await ui.find({ text: /-\$|saved today/ })).toBeUndefined()
      await ui.unmount()
    }
    w.savings = line(['usd', '-1.2', '-4.5', '-300', '-900', '2026-10-08', '20', '-', '20', T0])
    await w.clock.advance(30_000)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, bodyColumns: 300 } })
    expect(await ui.find({ type: 'Text', text: /│ No saving measured yet │/ })).toBeDefined()
    expect(await ui.find({ text: /-\$|potential/ })).toBeUndefined()
    await ui.press({ key: 'aionas-more' })
    expect(await ui.find({ type: 'Text', text: 'No saving measured yet · estimated · updated 13:00' })).toBeDefined()
  })

  test('the potential shows beside the figure until 14 counted days', async ($, on) => {
    const w = world(on)
    w.savings = line(['api_value', '1', '5.1', '100000', '1400000', '2026-10-17', '61.2', '2100000', '3', T0])
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'desktop', props: { ...BAND.props, bodyColumns: 300 } })
    expect(
      await ui.find({
        type: 'Text',
        text: /saved since 17 Oct 1\.4M tokens \(≈ \$5\.10 API value\) est\. · potential this month 2\.1M tokens/,
      }),
    ).toBeDefined()
    await ui.press({ key: 'aionas-more' })
    expect(
      await ui.find({
        type: 'Text',
        text: 'saved since 17 Oct (3 days) 1.4M tokens (≈ $5.10 API value) · today 100K tokens (≈ $1.00 API value) · potential this month 2.1M tokens (≈ $61.20 API value) · estimated · updated 13:00',
      }),
    ).toBeDefined()
    await ui.press({ key: 'aionas-less' })
    w.savings = line(['api_value', '1', '5.1', '100000', '1400000', '2026-10-01', '61.2', '2100000', '14', T0])
    await w.clock.advance(30_000)
    expect(await ui.find({ text: /potential/ })).toBeUndefined()
  })
})

describe('band: chips and the one-click bypass (M3)', () => {
  test('a chip press bypasses that method for 1h; the chip says off until; pressing again ends it with --end', async ($, on) => {
    const w = world(on)
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      const before = scriptRuns(w, 'commands/aionas-bypass.sh').length
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      const runs = scriptRuns(w, 'commands/aionas-bypass.sh').slice(before)
      expect(runs[0]?.slice(-2)).toEqual(['noisy_guard', '1h'])
      expect(runs.some(a => a.includes('--band'))).toBe(true)
      expect((await chipText(ui, 'noisy_guard'))).toContain('◌ guard · off until 14:00')
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      const ended = scriptRuns(w, 'commands/aionas-bypass.sh').find(a => a.includes('--end'))
      expect(ended?.slice(-2)).toEqual(['--end', 'noisy_guard'])
      expect((await chipText(ui, 'noisy_guard'))).toContain('● guard')
      expect(w.toasts.some(t => t.includes('back on'))).toBe(true)
      expect(w.toasts.some(t => t.includes('off for you for 1 hour'))).toBe(true)
      await ui.unmount()
    }
  })

  test('a method whose self-override the admin blocked becomes a request: request pending, display only', async ($, on) => {
    const w = world(on)
    ;(w.methods.output_store as M).so = 0
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await ui.press({ key: 'aionas-chip-output_store' })
    expect(await ui.find({ key: 'aionas-chip-output_store' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: '◌ store · request pending' })).toBeDefined()
    await ui.unmount()
    for (const surface of SURFACES) {
      const again = await $.ui.mount({ ...BAND, surface })
      expect(await again.find({ type: 'Text', text: '◌ store · request pending' })).toBeDefined()
      await again.unmount()
    }
  })

  test('released and off-by-policy methods are dim and display only', async ($, on) => {
    const w = world(on)
    w.methods.write_minimum = { ...(w.methods.write_minimum as M), state: 'off', active: 0, released: 1 }
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      await ui.press({ key: 'aionas-more' })
      expect(await ui.find({ type: 'Text', text: '○ write-min · released' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-chip-write_minimum' })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-chip-handoff' })).toBeUndefined()
      await ui.press({ key: 'aionas-less' })
      await ui.unmount()
    }
  })

  test('the effort chip opens the window that allows higher effort; it counts down every 15 s with a dim second line', async ($, on) => {
    const w = world(on)
    const clock = w.clock
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      await ui.press({ key: 'aionas-chip-effort_default' })
      const xhigh = scriptRuns(w, 'commands/aionas-xhigh.sh')
      expect(xhigh.at(-1)?.slice(-1)[0]).toMatch(/commands\/aionas-xhigh\.sh$/)
      expect(w.toasts.at(-1)).toContain('you may raise them to xhigh (Extra) or max with /effort')
      expect(await ui.find({ type: 'Text', text: '◆ higher effort allowed · 10:00 left' })).toBeDefined()
      expect(
        await ui.find({
          type: 'Text',
          text: 'sessions you open in the next 10 min may use /effort xhigh (Extra) or max · this one stays at high or below',
        }),
      ).toBeDefined()
      expect(await ui.find({ text: /start at xhigh|xhigh window/ })).toBeUndefined()
      expect(await ui.find({ key: 'aionas-chip-effort_default' })).toBeUndefined()
      const reads = w.bandReads()
      w.now += 15
      await clock.advance(15_000)
      expect(w.bandReads()).toBeGreaterThan(reads)
      expect(await ui.find({ type: 'Text', text: '◆ higher effort allowed · 9:45 left' })).toBeDefined()
      w.window = 'window\t-\t0\thigh'
      w.now += 600
      await clock.advance(15_000)
      expect((await chipText(ui, 'effort_default'))).toBe('● medium · allow more')
      expect(await ui.find({ text: /sessions you open in the next/ })).toBeUndefined()
      await ui.unmount()
    }
  })

  test('every chip and saved today has a tip: a card above it on the desktop, the row under the band on the terminal', async ($, on) => {
    const w = world(on)
    w.methods.write_minimum = { ...(w.methods.write_minimum as M), state: 'off', active: 0 }
    await start($)
    // AIO-874: the desktop app reveals an absolute card in a keyed Box, not a
    // scope row; the terminal keeps the row under the band (Tal, 2026-10-22).
    const expectTip = async (ui: any, surface: string, id: string, full: string) => {
      const card = await cardOf(ui, id, surface)
      expect(card.props.display).toBe('none')
      const text = textOf(card)
      if (surface === 'desktop') {
        expect(card.hover).toEqual({ display: 'flex' })
        expect(card.props.top).toBeLessThan(0)
        expect(card.props.width).toBeLessThanOrEqual(56)
        expect(card.props.left).toBeLessThanOrEqual(0)
        expect(text).toBe(full)
      } else {
        expect(card.hover).toEqual({ scope: `aionas-tip-${id}`, display: 'flex' })
        expect(card.props.position).toBeUndefined()
        expect(text).toBe(full)
        // The element itself joins the scope.
        let at: any
        const walk = (n: any): void => {
          if (n === null || typeof n !== 'object' || at !== undefined) return
          if (n.props?.key === `aionas-tipat-${id}`) at = n
          for (const c of n.children ?? []) walk(c)
        }
        walk(await ui.drawn())
        expect(at?.hover).toEqual({ scope: `aionas-tip-${id}` })
      }
    }
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, bodyColumns: 300 } })
      await expectTip(ui, surface, 'saved', TIPS_SAVED)
      await expectTip(ui, surface, 'noisy_guard', 'Noisy commands are shortened. Click: off for you for 1 hour.')
      await expectTip(ui, surface, 'effort_default', 'New sessions start at medium; high is the most you can pick. Click: for 10 min, new sessions may go up to xhigh or max.')
      await expectTip(ui, surface, 'handoff', 'Off now. A long chat left idle gets a note to go on in a new session.')
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      await expectTip(ui, surface, 'noisy_guard', 'Noisy commands are shortened. Click: back on.')
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      await ui.press({ key: 'aionas-chip-effort_default' })
      await expectTip(ui, surface, 'effort_default', TIPS_WINDOW)
      w.window = 'window\t-\t0\thigh'
      w.now += 600
      await w.clock.advance(15_000)
      await ui.press({ key: 'aionas-more' })
      await expectTip(ui, surface, 'write_minimum', 'Off now. Claude writes only what the task needs.')
      await ui.press({ key: 'aionas-less' })
      await ui.unmount()
    }
  })

  test('on the desktop a card near the right edge moves left to stay inside the band', async ($, on) => {
    world(on)
    await start($)
    const desk = await $.ui.mount({ ...BAND, surface: 'desktop' })
    expect((await cardOf(desk, 'write_minimum', 'desktop')).props.left).toBeLessThan(0)
    expect((await cardOf(desk, 'saved', 'desktop')).props.left).toBe(0)
  })

  test('a chip shows its state in color beside its Button: on green, off grey (a desktop drops a Button\'s child colors)', async ($, on) => {
    const w = world(on)
    await start($)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      const glyph = async (id: string) => (await ui.find({ key: `aionas-tipat-${id}` })).children[0].children[0]
      expect((await glyph('noisy_guard')).props.color).toBe('success')
      expect((await ui.find({ key: 'aionas-chip-noisy_guard' })).props.dimColor).toBe(false)
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      expect((await glyph('noisy_guard')).props.dimColor).toBe(true)
      expect((await ui.find({ key: 'aionas-chip-noisy_guard' })).props.dimColor).toBe(true)
      await ui.press({ key: 'aionas-chip-noisy_guard' })
      const off = await ui.find({ key: 'aionas-tipat-handoff' })
      expect(off.children[0].props.dimColor).toBe(true)
      await ui.unmount()
    }
    expect(w.toasts.length).toBeGreaterThan(0)
  })

  test('a session opened in a window says it may go higher, then the level it was raised to', async ($, on) => {
    const w = world(on, 'xhigh')
    w.window = `window\txhigh\t${T0 + 300}\txhigh`
    on('command.run', { command: 'effort' }, () => ({ text: 'engine' }))
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(
      await ui.find({ type: 'Text', text: 'sessions you open in the next 5 min may use /effort xhigh (Extra) or max · this one may too' }),
    ).toBeDefined()
    await $.command.run({ command: 'effort', args: 'max' } as never)
    expect(
      await ui.find({ type: 'Text', text: 'sessions you open in the next 5 min may use /effort xhigh (Extra) or max · this one is at max' }),
    ).toBeDefined()
  })

  test('the effort chip shows the level the last main-loop request carried, else the settings level, else medium', async ($, on) => {
    const w = world(on, 'xhigh')
    bottomStep(on, w, [])
    on('command.run', { command: 'effort' }, () => ({ text: 'engine' }))
    w.settings = { effortLevel: 'low' }
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await chipText(ui, 'effort_default'))).toBe('● low · allow more')
    await step($, 'high')
    expect((await chipText(ui, 'effort_default'))).toBe('● high · allow more')
    await step($, 'low', 'agent-1')
    expect((await chipText(ui, 'effort_default'))).toBe('● high · allow more')
    await $.command.run({ command: 'effort', args: 'max' } as never)
    expect((await chipText(ui, 'effort_default'))).toBe('● max · allow more')
  })

  test('the band refreshes every 30 s and after a main-loop turn', async ($, on) => {
    const w = world(on)
    const clock = w.clock
    on('turn.complete', ($, e) => ({ text: e.answer }))
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const n = w.bandReads()
    w.savings = SAVINGS_USD.replace('\t46.2\t', '\t50.25\t')
    await clock.advance(30_000)
    expect(w.bandReads()).toBe(n + 1)
    expect(await ui.find({ type: 'Text', text: /saved since 8 Oct ~\$50\.25 est\./ })).toBeDefined()
    await $.turn.complete({ turnId: 't1', reason: 'answer', answer: '', durationMs: 1, isAborted: false })
    await clock.settle()
    expect(w.bandReads()).toBe(n + 2)
    // ...and again 20 s later, once the handoff timer had time to arm.
    await clock.advance(20_000)
    expect(w.bandReads()).toBe(n + 3)
  })

  test('the 30 s read runs while a surface draws, interactive or not (the desktop app), and never headless', async ($, on) => {
    const w = world(on)
    w.surfaces = []
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const n = w.bandReads()
    await w.clock.advance(30_000)
    expect(w.bandReads()).toBe(n)
    w.surfaces = ['desktop']
    await w.clock.advance(30_000)
    expect(w.bandReads()).toBe(n + 1)
  })

  test('a band drawn on a surface the roster does not list still reads every 30 s', async ($, on) => {
    const w = world(on)
    w.surfaces = []
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
    expect(await ui.find({ key: 'aionas-more' })).toBeDefined()
    const n = w.bandReads()
    await w.clock.advance(30_000)
    expect(w.bandReads()).toBe(n + 1)
  })

  test('context at compact_at shows the warning row with /compact; never pressed for you; isWorking hides it; Later waits 50K', async ($, on) => {
    const w = world(on)
    let compacts = 0
    on('command.run', { command: 'compact' }, () => {
      compacts += 1
      return { text: 'compacted' }
    })
    w.methods.handoff = { ...(w.methods.handoff as M), state: 'on', active: 1 }
    await start($)
    await measure($, 150000)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ key: 'aionas-compact' })).toBeUndefined()
      await ui.unmount()
    }
    await measure($, 214000)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(
        await ui.find({ type: 'Text', text: '▲ Context 214K of 1M. Compact recommended. Idle 55 min → a handoff doc is written.' }),
      ).toBeDefined()
      expect(await ui.find({ key: 'aionas-compact' })).toBeDefined()
      expect(compacts).toBe(0)
      await ui.press({ key: 'aionas-more' })
      expect((await chipText(ui, 'handoff'))).toContain('● handoff · 214K')
      expect(await ui.find({ key: 'aionas-compact' })).toBeDefined()
      await ui.press({ key: 'aionas-less' })
      await ui.unmount()

      const working = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, isWorking: true } })
      expect(await working.find({ key: 'aionas-compact' })).toBeUndefined()
      expect(await working.find({ key: 'aionas-later' })).toBeDefined()
      await working.unmount()
    }
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await ui.press({ key: 'aionas-compact' })
    expect(compacts).toBe(1)
    await ui.press({ key: 'aionas-later' })
    expect(await ui.find({ key: 'aionas-compact' })).toBeUndefined()
    await measure($, 250000)
    expect(await ui.find({ key: 'aionas-compact' })).toBeUndefined()
    await measure($, 264000)
    expect(await ui.find({ key: 'aionas-compact' })).toBeDefined()
  })

  test('without handoff on, the idle clause is left out; compact_at comes from the policy', async ($, on) => {
    const w = world(on)
    w.compactAt = 'compact_at\t100000\t40'
    await start($)
    await measure($, 120000)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '▲ Context 120K of 1M. Compact recommended.' })).toBeDefined()
  })
})

describe('band: the handoff row (AIO-874)', () => {
  const handoffOn = (w: World) => (w.methods.handoff = { ...(w.methods.handoff as M), state: 'on', active: 1 })

  test('idle above the threshold: minutes left until the doc, and Done stops it', async ($, on) => {
    const w = world(on)
    handoffOn(w)
    w.handoff = `handoff\tarmed\t${T0 + 42 * 60 + 10}\t0\t0`
    await start($)
    await measure($, 214000)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: '◷ Handoff doc in 43 min if this chat stays idle.' })).toBeDefined()
      // The warning row no longer says a fixed idle time while the row counts.
      expect(await ui.find({ type: 'Text', text: '▲ Context 214K of 1M. Compact recommended.' })).toBeDefined()
      expect(textOf(await cardOf(ui, 'handoff_done', surface))).toContain(surface === 'desktop' ? 'A new message here takes it back' : 'Writes no handoff doc')
      await ui.unmount()
    }
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    w.now += 15 * 60
    await w.clock.advance(15_000)
    expect(await ui.find({ type: 'Text', text: '◷ Handoff doc in 28 min if this chat stays idle.' })).toBeDefined()
    await ui.press({ key: 'aionas-handoff-done' })
    await w.clock.settle()
    expect(scriptRuns(w, 'hooks/handoff-wake.sh').at(-1)?.slice(-2)).toEqual(['end', 'sess-test-1'])
    expect(w.toasts.at(-1)).toMatch(/^Done: no handoff doc/)
    expect(await ui.find({ key: 'aionas-handoff' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: '▲ Context 214K of 1M. Compact recommended.' })).toBeDefined()
  })

  test('a timer of an older version (no deadline) counts down from its arm time + the idle minutes', async ($, on) => {
    const w = world(on)
    handoffOn(w)
    w.handoff = `handoff\tarmed\t0\t0\t0\t${T0 - 5 * 60}`
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
    expect(await ui.find({ type: 'Text', text: '◷ Handoff doc in 50 min if this chat stays idle.' })).toBeDefined()
  })

  test('/aionas-done does the same without a model turn', async ($, on) => {
    const w = world(on)
    await start($)
    const r = await $.command.run({ command: 'aionas-done', args: '' } as never)
    expect((r as any).text).toMatch(/^Done: no handoff doc/)
    expect(scriptRuns(w, 'hooks/handoff-wake.sh').at(-1)?.slice(-2)).toEqual(['end', 'sess-test-1'])
  })

  test('after the doc: minutes left until cold; once cold, continue in a new conversation', async ($, on) => {
    const w = world(on)
    handoffOn(w)
    const commands: string[] = []
    const fills: string[] = []
    on('command.run', { command: 'clear' }, () => {
      commands.push('clear')
      return { text: '' }
    })
    on('prompt.fill', ($, e) => {
      fills.push(e.text)
      return { isFilled: true, text: e.text, cursor: e.text.length } as never
    })
    w.handoff = `handoff\tdelivered\t0\t${T0 + 30 * 60}\t1`
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '◷ Handoff doc written. This chat goes cold in 30 min.' })).toBeDefined()
    expect(await ui.find({ key: 'aionas-handoff-new' })).toBeUndefined()
    w.now += 30 * 60
    await w.clock.advance(15_000)
    expect(await ui.find({ type: 'Text', text: '◷ This chat is cold: going on here reads all of it again.' })).toBeDefined()
    expect(textOf(await cardOf(ui, 'handoff_new', 'terminal'))).toContain('This one is kept')
    await ui.press({ key: 'aionas-handoff-new' })
    await w.clock.settle()
    expect(commands).toEqual(['clear'])
    expect(fills).toEqual(['Continue the work described in the handoff document /h/handoff-sess-test-1.md. Read it fully first.'])
    expect(w.toasts.at(-1)).toBe('New conversation: press Enter to start it. The old one is kept: /resume sess-test-1 goes back to it.')
  })

  test('in the desktop app, continue opens a session of its own through the app link; this one stays', async ($, on) => {
    const w = world(on)
    handoffOn(w)
    let clears = 0
    on('command.run', { command: 'clear' }, () => {
      clears += 1
      return { text: '' }
    })
    w.handoff = `handoff\tdelivered\t0\t${T0 - 60}\t1`
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
    expect(textOf(await cardOf(ui, 'handoff_new', 'desktop'))).toContain('This one is kept')
    await ui.press({ key: 'aionas-handoff-new' })
    await w.clock.settle()
    const opened = scriptRuns(w, 'hooks/handoff-wake.sh').at(-1) as string[]
    expect(opened.slice(-2, -1)).toEqual(['open-app'])
    const url = new URL(opened.at(-1) as string)
    expect(url.protocol + url.host + url.pathname).toBe('claude:code/new')
    expect(url.searchParams.get('q')).toBe('Continue the work described in the handoff document /h/handoff-sess-test-1.md. Read it fully first.')
    expect(url.searchParams.get('folder')).toBe('/work/my repo')
    expect(clears).toBe(0)
    expect(w.toasts.at(-1)).toMatch(/^A new session opened with the handoff doc/)
  })

  test('no doc yet, handoff off, or done: no row', async ($, on) => {
    const w = world(on)
    w.handoff = `handoff\tdelivered\t0\t${T0 + 600}\t0`
    handoffOn(w)
    await start($)
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ key: 'aionas-handoff' })).toBeUndefined()
    w.handoff = `handoff\tarmed\t${T0 + 600}\t0\t0`
    w.methods.handoff = { ...(w.methods.handoff as M), active: 0 }
    await w.clock.advance(30_000)
    expect(await ui.find({ key: 'aionas-handoff' })).toBeUndefined()
  })
})

describe('commands', () => {
  test('/aionas-bypass runs the script by argument vector and prints its line', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const r = await $.command.run({ command: 'aionas-bypass', args: 'noisy_guard 2h debugging a flaky test; rm x' } as never)
    expect(r.text).toContain('noisy_guard is off')
    const ran = w.argv.find(a => a.some(x => x.endsWith('commands/aionas-bypass.sh')) && a.includes('noisy_guard'))
    expect(ran?.slice(2)).toEqual(['noisy_guard', '2h', 'debugging', 'a', 'flaky', 'test;', 'rm', 'x'])
  })

  test('/aionas-xhigh runs the script and prints its line', async ($, on) => {
    world(on)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const r = await $.command.run({ command: 'aionas-xhigh', args: 'max because' } as never)
    expect(r.text).toContain('Higher effort is allowed for 10 minutes')
  })
})

describe('effort grant', () => {
  test('a high session never touches CLAUDE_CODE_EXTRA_BODY, and /effort goes to Claude Code', async ($, on) => {
    const w = world(on, 'high')
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    let engineEffort = 0
    on('command.run', { command: 'effort' }, () => {
      engineEffort += 1
      return { text: "Effort 'xhigh' exceeds the cap" }
    })
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'high')
    expect(seen).toEqual([undefined])
    expect(w.envSets).toEqual([])
    await $.command.run({ command: 'effort', args: 'xhigh' } as never)
    expect(engineEffort).toBe(1)
  })

  test('under the install pin CLAUDE_CODE_EFFORT_LEVEL=high, /effort moves the pin for this session and goes to Claude Code', async ($, on) => {
    const w = world(on, 'high')
    w.env.set('CLAUDE_CODE_EFFORT_LEVEL', 'high')
    const engine: string[] = []
    on('command.run', { command: 'effort' }, ($, e) => {
      engine.push(`${e.args}:${w.env.get('CLAUDE_CODE_EFFORT_LEVEL')}`)
      return { text: 'ok' }
    })
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await $.command.run({ command: 'effort', args: 'low' } as never)
    await $.command.run({ command: 'effort', args: 'xhigh' } as never)
    await $.command.run({ command: 'effort', args: 'nonsense' } as never)
    await $.command.run({ command: 'effort', args: 'auto' } as never)
    // Claude Code sees the pin equal to the pick (xhigh is then clamped by
    // maxEffortLevel); auto lifts the pin; an unknown word changes nothing.
    expect(engine).toEqual(['low:low', 'xhigh:xhigh', 'nonsense:xhigh', 'auto:undefined'])
    expect(w.envSets).toEqual(['low', 'xhigh', undefined])
  })

  test('without the pin, /effort never sets CLAUDE_CODE_EFFORT_LEVEL; a granted session keeps the pin as it is', async ($, on) => {
    const w = world(on, 'xhigh')
    on('command.run', { command: 'effort' }, () => ({ text: 'ok' }))
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await $.command.run({ command: 'effort', args: 'low' } as never)
    expect(w.envSets).toEqual([])
    w.env.set('CLAUDE_CODE_EFFORT_LEVEL', 'high')
    const r = await $.command.run({ command: 'effort', args: 'max' } as never)
    expect(r.text).toContain('Set effort level to max')
    expect(w.envSets).toEqual([])
  })

  test('a session opened in a window starts at its usual level; /effort max, xhigh raise it; /effort high goes back to Claude Code', async ($, on) => {
    const w = world(on, 'xhigh')
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    const engine: string[] = []
    on('command.run', { command: 'effort' }, ($, e) => {
      engine.push(e.args)
      return { text: 'engine' }
    })
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'medium')
    expect(seen).toEqual([undefined])
    expect(w.envSets).toEqual([])
    const r = await $.command.run({ command: 'effort', args: 'max' } as never)
    expect(r.text).toContain('Set effort level to max')
    await step($, 'high')
    await step($, 'high', 'agent-1')
    await $.command.run({ command: 'effort', args: 'xhigh' } as never)
    await step($, 'high')
    await $.command.run({ command: 'effort', args: 'high' } as never)
    await step($, 'high')
    expect(seen).toEqual([
      undefined,
      '{"output_config":{"effort":"max"}}',
      undefined,
      '{"output_config":{"effort":"xhigh"}}',
      undefined,
    ])
    expect(engine).toEqual(['high'])
    expect(w.envSets.at(-1)).toBeUndefined()
  })
})

describe('effort grant: the app\'s picker (AIO-868, option 1)', () => {
  const APP = '/Applications/Claude.app/claude --output-format stream-json --effort=max --model=claude-opus-5-5'

  for (const [label, grant, args, want] of [
    ['in a window, launched at Max: sends max', 'xhigh', APP, '{"output_config":{"effort":"max"}}'],
    ['in a window, launched at Extra: sends xhigh', 'xhigh', APP.replace('--effort=max', '--effort xhigh'), '{"output_config":{"effort":"xhigh"}}'],
    ['in a window, launched at Medium: sends nothing extra', 'xhigh', APP.replace('--effort=max', '--effort=medium'), undefined],
    ['outside a window, launched at Max: sends nothing extra', 'high', APP, undefined],
  ] as const) {
    test(`the app's launch-time picker: ${label}`, async ($, on) => {
      const w = world(on, grant)
      w.parentArgs = args
      const seen: (string | undefined)[] = []
      bottomStep(on, w, seen)
      await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
      await step($, 'high')
      expect(seen).toEqual([want])
    })
  }

  test('in a window session, the picker moved to Extra mid-session raises the next request; moved to Low or High drops it', async ($, on) => {
    const w = world(on, 'xhigh')
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'medium')
    w.flag = { effortLevel: 'xhigh' }
    await step($, 'high')
    await step($, 'high')
    w.flag = { effortLevel: 'low' }
    await step($, 'low')
    expect(seen).toEqual([undefined, '{"output_config":{"effort":"xhigh"}}', '{"output_config":{"effort":"xhigh"}}', undefined])
  })

  test('the latest choice wins: /effort max after the picker, then the picker again', async ($, on) => {
    const w = world(on, 'xhigh')
    w.flag = { effortLevel: 'xhigh' }
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'high')
    await $.command.run({ command: 'effort', args: 'max' } as never)
    await step($, 'high')
    w.flag = { effortLevel: 'high' }
    await step($, 'high')
    expect(seen).toEqual(['{"output_config":{"effort":"xhigh"}}', '{"output_config":{"effort":"max"}}', undefined])
  })

  test('outside a window the picker is never read and nothing is sent above the cap', async ($, on) => {
    const w = world(on, 'high')
    w.flag = { effortLevel: 'xhigh' }
    w.parentArgs = APP
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'high')
    expect(seen).toEqual([undefined])
    expect(w.argv.some(a => a.join(' ').includes('ps -o args='))).toBe(false)
  })
})

describe('write the minimum', () => {
  test('the skill expands as written while the method is on, and to a no-op when it is off', async ($, on) => {
    const w = world(on, 'high')
    w.methods.write_minimum = { ...(w.methods.write_minimum as M), state: 'off', active: 0 }
    on('skill.prompt', ($, e) => ({ text: e.text }))
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await $.ui.mount({ ...BAND, surface: 'terminal' })
    const off = await $.skill.prompt({ skill: 'aionas-savings:write-minimum', text: 'Write the minimum.', pluginName: 'aionas-savings' } as never)
    expect(off.text).toContain('is off for you')
    const other = await $.skill.prompt({ skill: 'commit', text: 'A commit.', pluginName: 'other' } as never)
    expect(other.text).toBe('A commit.')
    expect(w.argv.some(a => a.includes('--count') && a.includes('skipped'))).toBe(true)
  })
})
