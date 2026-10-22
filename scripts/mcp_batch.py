# Sends a list of MCP tool calls to an MCP server over stdio and prints each result.
#
# Usage: python3 mcp_batch.py CALLS.json MAXCHARS -- server command...
# CALLS.json: [{"name": tool, "arguments": {...}} | {"sleep": seconds} | {"shell": "cmd"}]
# ${VAR} placeholders in CALLS.json are filled from environment variables.
import json, os, subprocess, sys, time
calls = json.loads(os.path.expandvars(open(sys.argv[1]).read())); maxc = int(sys.argv[2]); cmd = sys.argv[sys.argv.index("--")+1:]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
n = [0]
def rpc(method, params):
    n[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":n[0],"method":method,"params":params})+"\n"); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line: raise SystemExit("server closed")
        try: m = json.loads(line)
        except Exception: continue
        if m.get("id") == n[0]: return m
rpc("initialize", {"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"batch","version":"0"}})
p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"})+"\n"); p.stdin.flush()
for c in calls:
    if "sleep" in c: time.sleep(c["sleep"]); continue
    if "shell" in c: subprocess.run(c["shell"], shell=True); print(f"$ {c['shell']}"); continue
    r = rpc("tools/call", {"name": c["name"], "arguments": c.get("arguments", {})})
    res = r.get("result") or r.get("error")
    text = "\n".join(x.get("text", f"[{x.get('type')}]") for x in res.get("content", [])) if isinstance(res, dict) and "content" in res else json.dumps(res)
    print(f"=== {c['name']} {json.dumps(c.get('arguments', {}))}{' [ERROR]' if isinstance(res, dict) and res.get('isError') else ''}")
    print(text[:maxc]); print()
p.kill()
