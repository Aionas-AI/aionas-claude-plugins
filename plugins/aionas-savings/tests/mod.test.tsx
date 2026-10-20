// The aionas-savings mod (hooks/mod.tsx), run by `claude plugin test` on
// Claude Code 2.1.299. The scripts it runs are mocked at process.run; their
// own behaviour is covered by tests/unit/*.test.sh in the repo.
import { describe, expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const BAND = {
  plugin: 'aionas-savings',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const LIST = [
  'handoff\ton\t1\t1',
  'effort_default\ton\t1\t0',
  'subagent_sonnet\ton\t1\t1',
  'unused_services\ton\t1\t1',
  'noisy_guard\ton\t1\t1',
  'output_store\toff\t0\t1',
  'write_minimum\ton\t1\t1',
  'compact_at\t200000',
].join('\n')

type World = { argv: string[][]; envSets: (string | undefined)[]; tokens: number; env: Map<string, string | undefined> }

function world(on: On, grant: string, list: string = LIST): World {
  const env = new Map<string, string | undefined>()
  const w: World = { argv: [], envSets: [], tokens: 1000, env }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.id', () => ({ value: 'sess-test-1' }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('env.get', ($, e) => ({ value: env.get(e.name) }))
  on('process.run', ($, e) => {
    w.argv.push([...e.argv])
    const a = e.argv.join(' ')
    let stdout = ''
    if (a.includes('effort-window.sh grant')) stdout = grant
    else if (a.includes('--list')) stdout = list
    else if (a.includes('aionas-bypass.sh')) stdout = 'noisy_guard is off for you for 1 hour, from now. Reason: debugging a flaky test.'
    else if (a.includes('aionas-xhigh.sh')) stdout = 'Sessions you open in the next 10 minutes start at xhigh.'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('env.set', ($, e) => {
    w.envSets.push(e.value)
    env.set(e.name, e.value)
    return { value: undefined }
  })
  on('session.usage', () => ({
    value: { startedAt: 0, context: { tokens: w.tokens, window: 1000000 }, rateLimits: [] },
  }))
  return w
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

describe('band', () => {
  test('shows the methods, a bypass button and no thumbs on terminal and desktop', async ($, on) => {
    world(on, 'high')
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: /Aionas savings: 6 of 7 on/ })).toBeDefined()
      expect(await ui.find({ key: 'aionas-bypass' })).toBeDefined()
      expect(await ui.find({ key: 'aionas-compact' })).toBeUndefined()
      expect(await ui.find({ text: /👍|👎/ })).toBeUndefined()
    }
  })

  test('the bypass button picks a method and runs aionas-bypass for 1h', async ($, on) => {
    const w = world(on, 'high')
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await ui.press({ key: 'aionas-bypass' })
    await ui.select({ key: 'aionas-bypass-method', value: 'noisy_guard' })
    const ran = w.argv.find(a => a.some(x => x.endsWith('commands/aionas-bypass.sh')) && a.includes('noisy_guard'))
    expect(ran?.slice(-2)).toEqual(['noisy_guard', '1h'])
  })

  test('"Compact recommended" appears over the threshold and is never pressed for you', async ($, on) => {
    const w = world(on, 'high')
    let compacts = 0
    on('turn.complete', ($, e) => ({ text: e.answer }))
    on('command.run', { command: 'compact' }, () => {
      compacts += 1
      return { text: 'compacted' }
    })
    await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
    w.tokens = 250000
    await $.turn.complete({ turnId: 't1', reason: 'answer', answer: '', durationMs: 1, isAborted: false })
    const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await ui.find({ key: 'aionas-compact' })).toBeDefined()
    expect(compacts).toBe(0)
    await ui.press({ key: 'aionas-compact' })
    expect(compacts).toBe(1)
  })
})

describe('commands', () => {
  test('/aionas-bypass runs the script by argument vector and prints its line', async ($, on) => {
    const w = world(on, 'high')
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const r = await $.command.run({ command: 'aionas-bypass', args: 'noisy_guard 1h debugging a flaky test; rm x' } as never)
    expect(r.text).toContain('noisy_guard is off')
    const ran = w.argv.find(a => a.some(x => x.endsWith('commands/aionas-bypass.sh')) && a.includes('noisy_guard'))
    expect(ran?.slice(1)).toEqual([
      ran?.[1] ?? '',
      'noisy_guard',
      '1h',
      'debugging',
      'a',
      'flaky',
      'test;',
      'rm',
      'x',
    ])
  })

  test('/aionas-xhigh runs the script and prints its line', async ($, on) => {
    world(on, 'high')
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    const r = await $.command.run({ command: 'aionas-xhigh', args: 'max because' } as never)
    expect(r.text).toContain('Sessions you open in the next 10 minutes start at')
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

  test('a session opened in an xhigh window sends xhigh, then max after /effort max, and puts the env back', async ($, on) => {
    const w = world(on, 'xhigh')
    const seen: (string | undefined)[] = []
    bottomStep(on, w, seen)
    await $.session.start({ cwd: '/tmp', surface: null, isInteractive: false })
    await step($, 'high')
    const r = await $.command.run({ command: 'effort', args: 'max' } as never)
    expect(r.text).toContain('Set effort level to max')
    await step($, 'high')
    await step($, 'high', 'agent-1')
    expect(seen).toEqual([
      '{"output_config":{"effort":"xhigh"}}',
      '{"output_config":{"effort":"max"}}',
      undefined,
    ])
    expect(w.envSets.at(-1)).toBeUndefined()
  })
})


describe('write the minimum', () => {
  test('the skill expands as written while the method is on, and to a no-op when it is off', async ($, on) => {
    const w = world(on, 'high', LIST.replace('write_minimum\ton\t1\t1', 'write_minimum\toff\t0\t1'))
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
