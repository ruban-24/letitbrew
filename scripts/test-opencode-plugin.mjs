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
for (const event of [undefined, {}, { type: "permission.updated", properties: { sessionID: "x" } }, { type: "unknown", properties: { sessionID: "x" } }, { type: "session.status", properties: { status: "idle" } }]) await send(event)
await send({ type: "session.created", properties: { sessionID: "s1", info: { directory: "/work" } } })
await send({ type: "session.status", properties: { sessionID: "s1", status: "busy", info: { directory: "/work" } } })
await send({ type: "session.status", properties: { sessionID: "s1", status: "idle", info: { directory: "/work" } } })
await send({ type: "session.idle", properties: { sessionID: "s1", info: { directory: "/work" } } })
await send({ type: "session.deleted", properties: { sessionID: "s1", info: { directory: "/work" } } })
const events = calls.map(call => ({ args: call.args, value: JSON.parse(call.text), ended: call.ended }))
const names = events.map(value => value.args.slice(2).join(" "))
if (names.join(",") !== "opencode SessionStart,opencode UserPromptSubmit,opencode Stop,opencode Stop,opencode SessionEnd" || calls.some(value => value.args[0] !== canonicalCLI || value.options.stdout !== "ignore" || value.options.stderr !== "ignore") || events.some(value => value.args[1] !== "hook" || value.args[2] !== "opencode" || value.value.session_id !== "s1" || value.value.cwd !== "/work" || !value.ended)) throw new Error(`runtime contract mismatch cli=${canonicalCLI} names=${names.join(",")} options=${JSON.stringify(calls.map(x=>x.options))} calls=${JSON.stringify(events)}`)
console.log("PASS: OpenCode plugin runtime contract")
