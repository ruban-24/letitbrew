// Invoked by PiExtensionTests with a disposable directory and a generated adapter.
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import path from 'node:path'

const [extension, helper] = process.argv.slice(2)
assert(path.isAbsolute(extension) && path.isAbsolute(helper))
const log = path.join(path.dirname(extension), 'events.jsonl')
await fs.writeFile(helper, `#!/usr/bin/env node
const fs = require('node:fs');
let input = '';
process.stdin.on('data', b => input += b);
process.stdin.on('end', () => fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({args:process.argv.slice(2), payload:JSON.parse(input)})+'\\n'));
`, { mode: 0o755 })
const source = await fs.readFile(extension, 'utf8')
const factory = (await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)).default
const emissions = async () => (await fs.readFile(log, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse)
const runtime = () => {
  const handlers = new Map()
  factory({ on: (name, handler) => handlers.set(name, handler) })
  const ctx = { cwd: '/fixture/project', sessionManager: { getSessionId: () => 'same-resumed-session' } }
  return { send: (name, event = {}) => handlers.get(name)?.({ type: name, secret: 'PRIVATE PROMPT', ...event }, ctx) }
}
const first = runtime()
assert.equal((await emissions()).length, 0, 'factory has no side effects')
const check = async (event, expected) => {
  await first.send(event)
  assert.equal((await emissions()).at(-1).args[2], expected, event)
}
await check('session_start', 'SessionStart')
await check('agent_start', 'UserPromptSubmit')
const beforeEnd = (await emissions()).length
await first.send('agent_end')
assert.equal((await emissions()).length, beforeEnd, 'low-level end does not release during retry/continuation')
await check('ui_prompt_start', 'UserInputRequested')
await check('ui_prompt_end', 'UserInputResolved')
await check('session_before_compact', 'UserPromptSubmit')
await check('session_compact', 'UserPromptSubmit')
await check('agent_settled', 'Stop')
await check('ui_prompt_start', 'UserInputRequested')
await check('ui_prompt_end', 'Stop') // an idle menu dialog must not start work
await check('session_before_compact', 'UserPromptSubmit')
await check('session_compact_failed', 'Stop') // failed/cancelled manual compaction
await check('session_before_compact', 'UserPromptSubmit')
await check('session_compact', 'Stop')
await check('agent_start', 'UserPromptSubmit')
await check('session_before_compact', 'UserPromptSubmit')
await check('session_compact_failed', 'UserPromptSubmit') // automatic retry stays working
await check('agent_settled', 'Stop')
// UI notifications are emitted without awaiting the handlers in Pi. Preserve
// start/end/settled order even when all arrive before the first child exits.
await check('agent_start', 'UserPromptSubmit')
await Promise.all([first.send('ui_prompt_start'), first.send('ui_prompt_end'), first.send('agent_settled')])
assert.deepEqual((await emissions()).slice(-3).map(x => x.args[2]), ['UserInputRequested', 'UserInputResolved', 'Stop'])
const second = runtime()
await second.send('session_start')
const firstID = (await emissions())[0].payload.session_id
const secondID = (await emissions()).at(-1).payload.session_id
assert.notEqual(firstID, secondID, 'two processes resuming one Pi session have independent records')
await check('session_shutdown', 'SessionEnd')
const afterShutdown = (await emissions()).length
await first.send('session_shutdown')
await first.send('agent_settled')
assert.equal((await emissions()).length, afterShutdown, 'shutdown is idempotent; late notifications cannot resurrect it')
await first.send('session_start')
assert.notEqual((await emissions()).at(-1).payload.session_id, firstID, 'reload has a fresh lifetime')
await first.send('session_start') // defensive replacement without a preceding shutdown
assert.equal((await emissions()).at(-2).args[2], 'SessionEnd')
await first.send('session_shutdown')
await second.send('session_shutdown')
const captured = await emissions()
for (const call of captured) {
  assert.deepEqual(call.args.slice(0, 2), ['hook', 'pi'])
  assert.deepEqual(Object.keys(call.payload).sort(), ['cwd', 'hook_event_name', 'session_id'])
  assert.equal(call.payload.cwd, '/fixture/project')
  assert.equal(call.payload.hook_event_name, call.args[2])
}
assert(!JSON.stringify(captured).includes('PRIVATE PROMPT'))
if (process.env.LETITBREW_TEST_PI_PACKAGE) {
  const { testInstalledPi } = await import('./test-pi-sdk.mjs')
  await testInstalledPi(process.env.LETITBREW_TEST_PI_PACKAGE, extension, emissions)
  captured.splice(0, captured.length, ...await emissions())
}
// Broken/missing helpers and a hung helper must never block Pi indefinitely.
await fs.unlink(helper)
await first.send('session_start')
await first.send('session_shutdown')
await fs.writeFile(helper, '#!/usr/bin/env node\nprocess.stdin.resume(); process.stdin.on("end", () => process.exit(7));\n', { mode: 0o755 })
await first.send('session_start')
await first.send('session_shutdown')
await fs.writeFile(helper, '#!/usr/bin/env node\nprocess.stdin.destroy(); setInterval(() => {}, 10000);\n', { mode: 0o755 })
const started = Date.now()
await first.send('session_start')
await first.send('session_shutdown')
assert(Date.now() - started < 5000, 'helper timeout is bounded')
console.log(JSON.stringify(captured.map(call => ({ event: call.args[2], payload: call.payload }))))
