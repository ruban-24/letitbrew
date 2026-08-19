import fs from "node:fs/promises"
import path from "node:path"

const [cli, plugin] = process.argv.slice(2)
if (!cli || !plugin || process.argv.length !== 4 || !path.isAbsolute(cli) || !path.isAbsolute(plugin)) process.exit(2)
let source
try { source = await fs.readFile(plugin) } catch { process.exit(2) }
const canonicalCLI = await fs.realpath(cli)
const calls = []
globalThis.Bun = { spawn(args, options) {
  const call = { args, options, text: "", ended: false }
  calls.push(call)
  return { stdin: { write(value) { call.text += value }, end() { call.ended = true } }, exited: Promise.resolve(), kill() {} }
} }
const module = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)
const pluginObject = await module.LetItBrew({ directory: "/project" })
const send = async event => { await pluginObject.event({ event }) }
for (const event of [undefined, {}, { type: "unknown", properties: { sessionID: "x" } }, { type: "session.status", properties: { status: "idle" } }]) await send(event)
await send({ type: "session.created", properties: { sessionID: "s1", info: { directory: "/work" } } })
await send({ type: "session.status", properties: { sessionID: "s1", status: "busy", info: { directory: "/work" } } })
await send({ type: "session.status", properties: { sessionID: "s1", status: "idle", info: { directory: "/work" } } })
await send({ type: "session.idle", properties: { sessionID: "s1", info: { directory: "/work" } } })
await send({ type: "session.deleted", properties: { sessionID: "s1", info: { directory: "/work" } } })
await send({ type: "permission.updated", properties: { sessionID: "p1" } })
await send({ type: "permission.asked", properties: { sessionID: "p2" } })
await send({ type: "permission.v2.asked", properties: { sessionID: "p3" } })
await send({ type: "permission.replied", properties: { sessionID: "p1", reply: "once" } })
await send({ type: "permission.v2.replied", properties: { sessionID: "p2", response: "always" } })
await send({ type: "permission.replied", properties: { sessionID: "p3", response: "reject" } })
await send({ type: "question.asked", properties: { sessionID: "q1" } })
await send({ type: "question.replied", properties: { sessionID: "q1" } })
await send({ type: "question.rejected", properties: { sessionID: "q2" } })
const events = calls.map(call => ({ args: call.args, value: JSON.parse(call.text), ended: call.ended }))
const actual = events.map(value => ({ name: value.args[3], sessionID: value.value.session_id, cwd: value.value.cwd }))
const expected = [
  { name: "SessionStart", sessionID: "s1", cwd: "/work" },
  { name: "UserPromptSubmit", sessionID: "s1", cwd: "/work" },
  { name: "Stop", sessionID: "s1", cwd: "/work" },
  { name: "Stop", sessionID: "s1", cwd: "/work" },
  { name: "SessionEnd", sessionID: "s1", cwd: "/work" },
  { name: "PermissionRequest", sessionID: "p1", cwd: "/project" },
  { name: "PermissionRequest", sessionID: "p2", cwd: "/project" },
  { name: "PermissionRequest", sessionID: "p3", cwd: "/project" },
  { name: "UserInputResolved", sessionID: "p1", cwd: "/project" },
  { name: "UserInputResolved", sessionID: "p2", cwd: "/project" },
  { name: "UserInputResolved", sessionID: "p3", cwd: "/project" },
  { name: "UserInputRequested", sessionID: "q1", cwd: "/project" },
  { name: "UserInputResolved", sessionID: "q1", cwd: "/project" },
  { name: "UserInputResolved", sessionID: "q2", cwd: "/project" },
]
if (JSON.stringify(actual) !== JSON.stringify(expected) || calls.some(value => value.args[0] !== canonicalCLI || value.options.stdout !== "ignore" || value.options.stderr !== "ignore") || events.some(value => value.args[1] !== "hook" || value.args[2] !== "opencode" || !value.ended)) throw new Error(`runtime contract mismatch cli=${canonicalCLI} actual=${JSON.stringify(actual)} options=${JSON.stringify(calls.map(x=>x.options))} calls=${JSON.stringify(events)}`)
console.log("PASS: OpenCode plugin runtime contract")
