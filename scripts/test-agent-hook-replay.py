#!/usr/bin/env python3
"""Runs each generated Cursor, Gemini, Qwen, and Kimi hook command the way its
agent would, in a throwaway home, and checks the board after every event."""
import json, os, subprocess, sys, tempfile, tomllib

cli = os.path.abspath(sys.argv[1])
home = tempfile.mkdtemp(prefix="letitbrew-agent-replay.", dir="/tmp")
env = dict(os.environ, LETITBREW_TEST_HOME=home, CFFIXED_USER_HOME=home)
def run(*a, **k): return subprocess.run([cli,*a], env=env, capture_output=True, text=True, **k)
os.makedirs(f"{home}/.cursor"); os.makedirs(f"{home}/.gemini"); os.makedirs(f"{home}/.qwen"); os.makedirs(f"{home}/.kimi-code")
open(f"{home}/.cursor/hooks.json","w").write('{"version":1,"hooks":{"stop":[{"command":"true","timeout":1}]}}\n')
open(f"{home}/.gemini/settings.json","w").write('{"theme":"dark"}\n')
open(f"{home}/.qwen/settings.json","w").write('{"model":{"name":"q"}}\n')
open(f"{home}/.kimi-code/config.toml","w").write('default_model = "k"\n\n[loop_control]\nmax_steps = 5\n')
for a in "cursor gemini qwen kimi".split():
    r = run("install", a); assert r.returncode==0, r
doc = run("doctor").stdout; print(*[l for l in doc.splitlines() if l.split(":")[0] in ("Cursor","Gemini CLI","Qwen Code","Kimi Code")], sep="\n")
cursor = json.load(open(f"{home}/.cursor/hooks.json"))["hooks"]
gemini = json.load(open(f"{home}/.gemini/settings.json"))["hooks"]
qwen = json.load(open(f"{home}/.qwen/settings.json"))["hooks"]
kimi = tomllib.load(open(f"{home}/.kimi-code/config.toml","rb"))
assert kimi["default_model"]=="k" and kimi["loop_control"]["max_steps"]==5
kimi_by_event = {t["event"]:t["command"] for t in kimi["hooks"]}
def cmd(agent, event):
    if agent=="cursor": return next(e["command"] for e in cursor[event] if "letitbrew" in e["command"])
    if agent=="kimi": return kimi_by_event[event]
    h = gemini if agent=="gemini" else qwen
    return h[event][0]["hooks"][0]["command"]
def status():
    return {s["tool"]:(s["state"],s.get("detail")) for s in json.loads(run("status","--json").stdout)["sessions"]}
def fire(agent, event, **payload):
    p = subprocess.run(["/bin/sh","-c",cmd(agent,event)], input=json.dumps(payload), env=env, capture_output=True, text=True)
    assert p.returncode==0, (agent,event,p)
    return p.stdout
base = {"session_id":"s1","cwd":"/work/app","hook_event_name":"x"}
out=[]
def step(agent,event,**extra):
    pl = {"conversation_id":"c1","workspace_roots":["/work/app"]} if agent=="cursor" else dict(base)
    pl.update(extra); so=fire(agent,event,**pl); st=status().get(agent)
    print(f"{agent:7} {event:20} {str(extra.get('notification_type') or extra.get('tool_name') or ''):18} -> {st} stdout={so!r}")
    return st
print("--- Cursor"); assert step("cursor","beforeSubmitPrompt")[0]=="working"; assert step("cursor","postToolUse",tool_name="Shell")[0]=="working"; assert step("cursor","stop",status="aborted")[0]=="idle"; assert step("cursor","postToolUse",tool_name="Shell")[0]=="idle"; assert step("cursor","sessionEnd",reason="user_close") is None
print("--- Gemini"); assert step("gemini","SessionStart",source="startup")[0]=="idle"; assert step("gemini","BeforeAgent")[0]=="working"; assert step("gemini","BeforeTool",tool_name="run_shell_command")[0]=="working"; assert step("gemini","Notification",notification_type="ToolPermission")[0]=="awaiting_input"; assert step("gemini","AfterTool",tool_name="run_shell_command")[0]=="working"; assert step("gemini","AfterAgent")[0]=="idle"; assert step("gemini","SessionEnd",reason="exit") is None
print("--- Qwen"); assert step("qwen","SessionStart",source="startup")[0]=="idle"; assert step("qwen","UserPromptSubmit")[0]=="working"; assert step("qwen","PreToolUse",tool_name="run_shell_command",agent_id="sub")[0]=="working"; assert step("qwen","Notification",notification_type="idle_prompt")[0]=="working"; assert step("qwen","Notification",notification_type="permission_prompt")[0]=="awaiting_input"; assert step("qwen","PostToolUse",tool_name="run_shell_command")[0]=="working"; assert step("qwen","PreToolUse",tool_name="run_shell_command")[0]=="working"; assert step("qwen","PostToolUseFailure",tool_name="run_shell_command",is_interrupt=True)[0]=="idle"; assert step("qwen","SessionEnd") is None
print("--- Kimi"); assert step("kimi","UserPromptSubmit")[0]=="working"; assert step("kimi","SessionStart",source="startup")[0]=="working"; assert step("kimi","PermissionRequest",tool_name="Bash",agent_id="main")[0]=="awaiting_input"; assert step("kimi","PermissionResult",tool_name="Bash",agent_id="main")[0]=="working"; assert step("kimi","PermissionRequest",tool_name="Bash",agent_id="main")[0]=="awaiting_input"; assert step("kimi","Interrupt",reason="cancelled")[0]=="idle"; assert step("kimi","PermissionResult",tool_name="Bash",agent_id="main")[0]=="idle"; assert step("kimi","SessionEnd") is None
for a in "cursor gemini qwen kimi".split():
    r = run("uninstall", a); assert r.returncode==0, r
print("after uninstall:", open(f"{home}/.cursor/hooks.json").read().replace("\n"," ")[:90], "|", open(f"{home}/.gemini/settings.json").read().replace("\n"," "), "|", open(f"{home}/.qwen/settings.json").read().replace("\n"," "), "|", repr(open(f"{home}/.kimi-code/config.toml").read()))
subprocess.run(["rm", "-rf", home], check=True)
print("REPLAY PASS")
