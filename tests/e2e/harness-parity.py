"""The scenarios of tests/e2e/harness-parity.sh: REAL Claude Code sessions in the throwaway sandbox (claude-bedrock -p …
--output-format stream-json, its tools allowed in /workspace/<model>/<scenario> only), the models side by side (--jobs),
each model's scenarios one after another, each recorded as PASS or FAIL with the exact error (Claude Code's own words,
and LiteLLM's for a call that failed) and its seconds; the run's Bedrock spend is what LiteLLM booked, by model group
(the suite's callback in the LiteLLM container). A failure that comes from the model itself stays a FAIL here: the
README's table (Models for Claude Code) says which those are.

  python3 harness-parity.py --name bne2e-parity --out DIR --models a,b [--scenarios x,y] [--jobs N]
  python3 harness-parity.py --list

The master key is read from the file MASTER_FILE names (never an argument); LiteLLM's port is LITELLM_PORT.
"""

import argparse
import base64
import io
import json
import os
import re
import struct
import subprocess
import sys
import tarfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
import zlib

CONTROL = "claude-haiku-5-5"
TOOLS = "Read,Write,Edit,Bash,Glob,Grep,TodoWrite,WebFetch,WebSearch"
SECRET = "PARITY-OWL"


def png(rgb, size=64):
    """A SIZE x SIZE PNG of one colour."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def seed_files():
    big = "".join(f"line {i}: the quick brown fox jumps over the lazy dog, entry {i * 7 % 1000}\n" for i in range(1, 1501))
    return {"notes.txt": f"Project notes.\nThe secret word is {SECRET}.\nNothing else here.\n".encode(),
            "a.txt": b"alpha 41\n", "b.txt": b"beta 1\n", "red.png": png((220, 20, 20)), "big.txt": big.encode()}


def family(model):
    if model.startswith("claude-"):
        return "control"
    if model.startswith("or/"):
        return "openrouter"
    if model.startswith("xl/"):
        return "explabs"
    return "bedrock"


def slug(model):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", model)


class Run:
    """One claude-bedrock -p session: its stream-json events, parsed."""

    def __init__(self, rc, out, err, seconds):
        self.rc, self.err, self.seconds = rc, err, seconds
        self.events = []
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    self.events.append(json.loads(line))
                except ValueError:
                    pass
        self.raw = out
        self.result = next((e for e in reversed(self.events) if e.get("type") == "result"), None)
        init = next((e for e in self.events if e.get("type") == "system" and e.get("subtype") == "init"), {})
        self.session = (self.result or {}).get("session_id") or init.get("session_id")
        self.assistant = [e for e in self.events if e.get("type") == "assistant"]

    def blocks(self, kind):
        return [b for e in self.assistant for b in (e.get("message") or {}).get("content") or [] if isinstance(b, dict) and b.get("type") == kind]

    def tools(self):
        return [b.get("name") for b in self.blocks("tool_use")]

    def parallel(self):
        return any(sum(1 for b in (e.get("message") or {}).get("content") or [] if isinstance(b, dict) and b.get("type") == "tool_use") >= 2
                   for e in self.assistant)

    def tool_results(self):
        out = []
        for e in self.events:
            if e.get("type") != "user":
                continue
            for b in (e.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    c = b.get("content")
                    text = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
                    out.append((b.get("is_error") is True, text))
        return out

    def tool_use_results(self):
        """The SDK's structured result of each tool call (tool_use_result: WebSearch's searchCount …)."""
        return [e.get("tool_use_result") for e in self.events if e.get("type") == "user" and e.get("tool_use_result") is not None]

    def text(self):
        r = (self.result or {}).get("result")
        return r if isinstance(r, str) else ""

    def ok(self):
        r = self.result or {}
        return self.rc == 0 and r.get("subtype") == "success" and r.get("is_error") is not True and not self.api_errors()

    def api_errors(self):
        """Claude Code's API errors: an assistant message with an error, its text (Claude Code's own words)."""
        out = []
        for e in self.assistant:
            if e.get("error"):
                t = " ".join(b.get("text", "") for b in (e.get("message") or {}).get("content") or [] if isinstance(b, dict))
                out.append(f"[{e['error']}] {t}".strip())
        return out

    def why(self):
        """The exact error, as Claude Code said it."""
        parts = self.api_errors()
        r = self.result or {}
        if r.get("is_error") or (r and r.get("subtype") != "success"):
            parts.append(f"result {r.get('subtype')}: {self.text() or ' '.join(map(str, r.get('errors') or []))}")
        if not self.result:
            parts.append(f"no result (exit {self.rc}): {self.err.strip()[-600:] or self.raw.strip()[-600:]}")
        return " | ".join(p for p in parts if p)[:1500]


class Suite:
    def __init__(self, a):
        self.a = a
        self.sandbox, self.litellm = f"{a.name}-sandbox", f"{a.name}-litellm"
        with open(os.environ["MASTER_FILE"], encoding="utf-8") as f:
            self.master = f.read().strip()
        self.port = os.environ["LITELLM_PORT"]
        self.logs = os.path.join(a.out, "harness-parity-logs")
        os.makedirs(self.logs, exist_ok=True)
        self.rows = []
        self.ledger = 0   # lines of the spend log read so far
        self.calls = []   # every call LiteLLM booked during the run (the suite's callback)
        self.lock = threading.Lock()

    # --- the sandbox
    def sh(self, script, *args, stdin=None, timeout=120):
        p = subprocess.run(["docker", "exec", "-i", self.sandbox, "sh", "-c", script, "sh", *args], input=stdin,
                           capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    def seed(self, path):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as t:
            for n, data in seed_files().items():
                info = tarfile.TarInfo(n)
                info.size, info.mode, info.mtime = len(data), 0o644, int(time.time())
                t.addfile(info, io.BytesIO(data))
        rc, _, err = self.sh('mkdir -p "$1" && tar -x -C "$1"', path, stdin=buf.getvalue())
        if rc != 0:
            raise RuntimeError(f"could not seed {path}: {err}")

    def cat(self, path):
        rc, out, _ = self.sh('cat "$1" 2>/dev/null', path)
        return out if rc == 0 else None

    def claude(self, model, cwd, prompt=None, resume=None, env=None, stdin_json=None, log=None, timeout=420):
        args = ["timeout", str(timeout - 20), "claude-bedrock", "-p"]
        if prompt is not None:
            args.append(prompt)
        args += ["--model", model, "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                 "--allowedTools", TOOLS, "--max-turns", "20"]
        if stdin_json is not None:
            args += ["--input-format", "stream-json"]
        if resume:
            args += ["--resume", resume]
        e = ["-e", "CLAUDE_BEDROCK_QUIET=1"]
        for k, v in (env or {}).items():
            e += ["-e", f"{k}={v}"]
        data = None
        if stdin_json is not None:
            data = "".join(json.dumps(m) + "\n" for m in stdin_json).encode()
        t0 = time.time()
        try:
            p = subprocess.run(["docker", "exec", "-i", "-w", cwd, *e, self.sandbox, *args], input=data, capture_output=True, timeout=timeout)
            run = Run(p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.time() - t0)
        except subprocess.TimeoutExpired as x:
            run = Run(124, (x.stdout or b"").decode("utf-8", "replace"), "timed out", time.time() - t0)
        if log:
            with open(os.path.join(self.logs, log), "w", encoding="utf-8") as f:
                f.write(run.raw)
                if run.err.strip():
                    f.write("\n# stderr\n" + run.err)
        return run

    # --- LiteLLM: the calls it booked since the last look (the suite's callback), and direct calls through the gateway
    def ledger_since(self):
        p = subprocess.run(["docker", "exec", self.litellm, "sh", "-c", "cat /tmp/parity-spend.jsonl 2>/dev/null"], capture_output=True)
        lines = p.stdout.decode("utf-8", "replace").splitlines()
        new, self.ledger = lines[self.ledger:], len(lines)
        rows = []
        for line in new:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
        return rows

    def gateway(self, path, body):
        """POST BODY to the gateway from inside the sandbox, as Claude Code does (its key from its environment)."""
        script = ('curl -sS -m 120 -w "\\n%{http_code}" -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" '
                  '-H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" --data-binary @- "$ANTHROPIC_BASE_URL$1"')
        rc, out, err = self.sh(script, path, stdin=json.dumps(body).encode(), timeout=150)
        body, _, code = out.rpartition("\n")
        return code.strip(), body

    # --- one scenario on one model (models run side by side: a call's spend is the run's, by model group)
    def record(self, model, scen, status, seconds, detail, errors, flags=None):
        # LiteLLM's words for a call that failed while this scenario ran on this model (its model group, or the stand-ins')
        if errors and status != "PASS":
            detail = f"{detail} || LiteLLM: {errors[-1]}"
        row = {"model": model, "family": family(model), "scenario": scen, "status": status, "seconds": round(seconds, 1),
               "detail": " ".join(str(detail).split())[:2500], "flags": flags or {}}
        with self.lock:
            self.rows.append(row)
            print(f"  {status:5} {model:28} {scen:13} {row['seconds']:6.1f}s  {row['detail'][:300]}", file=sys.stderr, flush=True)
            self.write()

    def errors_for(self, model, since):
        """LiteLLM's failures since SINCE (a time) for MODEL's calls (a stand-in's: its own group or the relay's)."""
        with self.lock:
            self.calls += self.ledger_since()
            groups = {model} | ({self.a.relay_model} if family(model) in ("openrouter", "explabs") else set())
            return [f"{r.get('group') or r.get('model')}: {r.get('error')}" for r in self.calls
                    if r.get("t", 0) >= since and not r.get("ok") and r.get("error") and (r.get("group") in groups or r.get("model") in groups)]

    def images_sent(self, model, since):
        """How many images LiteLLM's calls for MODEL (a stand-in's: the relay's) carried since SINCE."""
        with self.lock:
            self.calls += self.ledger_since()
            groups = {model} | ({self.a.relay_model} if family(model) in ("openrouter", "explabs") else set())
            return sum(int(r.get("images") or 0) for r in self.calls if r.get("t", 0) >= since and (r.get("group") in groups or r.get("model") in groups))

    def spend(self):
        by = {}
        for r in self.calls:
            g = r.get("group") or r.get("model") or "?"
            by[g] = round(by.get(g, 0) + float(r.get("cost") or 0), 6)
        return round(sum(by.values()), 6), by

    def write(self):
        total, by = self.spend()
        with open(os.path.join(self.a.out, "harness-parity.json"), "w", encoding="utf-8") as f:
            json.dump({"models": self.a.models.split(","), "or_mode": self.a.or_mode, "xl_mode": self.a.xl_mode,
                       "relay_model": self.a.relay_model, "rows": self.rows, "spend": total, "spend_by_model_group": by,
                       "calls": len(self.calls), "failed_calls": sum(1 for r in self.calls if not r.get("ok"))}, f, indent=1)
        with open(os.path.join(self.a.out, "harness-parity.tsv"), "w", encoding="utf-8") as f:
            f.write("# model\tfamily\tscenario\tstatus\tseconds\tdetail\n")
            for r in self.rows:
                f.write("\t".join(str(r[k]) for k in ("model", "family", "scenario", "status", "seconds")) + "\t" + r["detail"].replace("\t", " ") + "\n")
            f.write(f"# Bedrock spend booked by LiteLLM: ${total:.4f} ({', '.join(f'{k} ${v:.4f}' for k, v in sorted(by.items()))})\n")


# --- the scenarios: each (suite, model, dir, tag) -> (status, detail, flags)

def has(text, word):
    return word.lower() in (text or "").lower()


def sc_turns(s, m, d, tag):
    r1 = s.claude(m, d, "Remember the code word PARITY-FOX. Reply with just OK.", log=f"{tag}-1.jsonl")
    if not r1.ok():
        return "FAIL", f"turn 1: {r1.why()}", {}
    r2 = s.claude(m, d, "What is 17+25? Reply with just the number.", resume=r1.session, log=f"{tag}-2.jsonl")
    if not r2.ok():
        return "FAIL", f"turn 2 (--resume): {r2.why()}", {}
    r3 = s.claude(m, d, "What was the code word I gave you? Reply with just the word.", resume=r1.session, log=f"{tag}-3.jsonl")
    if not r3.ok():
        return "FAIL", f"turn 3 (--resume): {r3.why()}", {}
    if not has(r2.text(), "42") or not has(r3.text(), "PARITY-FOX"):
        return "FAIL", f"answers: turn 2 {r2.text()[:80]!r}, turn 3 {r3.text()[:80]!r}", {}
    return "PASS", "3 turns, history kept", {}


def sc_thinking(s, m, d, tag):
    env = {"MAX_THINKING_TOKENS": "2048"}
    r1 = s.claude(m, d, "What is 23*19? Think it through, then reply with just the number.", env=env, log=f"{tag}-1.jsonl")
    if not r1.ok():
        return "FAIL", f"turn 1 (thinking on): {r1.why()}", {}
    thought = bool(r1.blocks("thinking") or r1.blocks("redacted_thinking"))
    r2 = s.claude(m, d, "Add 3 to that number. Reply with just the number.", resume=r1.session, env=env, log=f"{tag}-2.jsonl")
    if not r2.ok():
        return "FAIL", f"turn 2, replaying turn 1{' and its thinking' if thought else ''}: {r2.why()}", {"thinking": thought}
    if not has(r1.text(), "437") or not has(r2.text(), "440"):
        return "FAIL", f"answers: {r1.text()[:80]!r}, {r2.text()[:80]!r}", {"thinking": thought}
    return "PASS", f"thinking blocks {'returned and replayed' if thought else 'not returned by the model'}", {"thinking": thought}


def sc_tools(s, m, d, tag):
    prompt = ("Do these steps in order, each with the tool named. (1) TodoWrite: a todo list of two items, 'read' and 'write'. "
              "(2) Glob: find the *.txt files here. (3) Grep: search notes.txt for the word secret. (4) Read: read a.txt. "
              "(5) Write: create out.txt containing exactly the secret word from notes.txt. (6) Edit: in a.txt replace alpha "
              "with omega. (7) Bash: run `cat out.txt a.txt`. Then reply DONE.")
    r = s.claude(m, d, prompt, log=f"{tag}.jsonl")
    used = r.tools()
    # (Claude Code 2.1.309 keeps its todo list with TaskCreate / TaskUpdate where earlier ones had TodoWrite)
    todo = [t for t in used if t in ("TodoWrite", "TaskCreate", "TaskUpdate")]
    missing = ([] if todo else ["TodoWrite"]) + [t for t in ("Glob", "Grep", "Read", "Write", "Edit", "Bash") if t not in used]
    out, a = s.cat(f"{d}/out.txt"), s.cat(f"{d}/a.txt")
    errs = [t[:200] for bad, t in r.tool_results() if bad]
    flags = {"tools": used, "missing": missing}
    if not r.ok():
        return "FAIL", f"{r.why()} (tools used: {used})", flags
    if not (out and SECRET in out and a and "omega" in a):
        return "FAIL", f"files: out.txt {out!r}, a.txt {a!r}; tools used {used}; tool errors {errs[:3]}", flags
    return "PASS", f"tools used {used}" + (f"; skipped {missing}" if missing else "") + (f"; tool errors {errs[:3]}" if errs else ""), flags


def sc_parallel(s, m, d, tag):
    r = s.claude(m, d, "Read a.txt and b.txt: make both Read calls at once, in one message. Then reply with the sum of the "
                       "two numbers in them, just the number.", log=f"{tag}.jsonl")
    flags = {"parallel": r.parallel(), "tools": r.tools()}
    if not r.ok():
        return "FAIL", r.why(), flags
    if not has(r.text(), "42"):
        return "FAIL", f"answer {r.text()[:80]!r} (tools {r.tools()})", flags
    return "PASS", "two Read calls in one message, both results back" if r.parallel() else "answered; the model made the calls one at a time", flags


def sc_think_tool(s, m, d, tag):
    r = s.claude(m, d, "Think about it first, then use Bash to run: echo $((6*7)) and reply with its output only.",
                 env={"MAX_THINKING_TOKENS": "2048"}, log=f"{tag}.jsonl")
    flags = {"thinking": bool(r.blocks("thinking")), "tools": r.tools()}
    if not r.ok():
        return "FAIL", r.why(), flags
    if "Bash" not in r.tools() or not has(r.text(), "42"):
        return "FAIL", f"answer {r.text()[:80]!r}, tools {r.tools()}", flags
    return "PASS", f"Bash after {'thinking' if flags['thinking'] else 'no thinking block (the model returned none)'}", flags


def sc_image_read(s, m, d, tag):
    t0 = time.time()
    r = s.claude(m, d, "Use Read on red.png and tell me its main colour in one word.", log=f"{tag}.jsonl")
    flags = {"images_sent": s.images_sent(m, t0)}
    if not r.ok():
        return "FAIL", r.why(), flags
    if not has(r.text(), "red"):
        return "FAIL", f"answer {r.text()[:120]!r} (tools {r.tools()}; images in the calls to the provider: {flags['images_sent']})", flags
    return "PASS", "the Read tool's image reached the model", flags


def _image_prompt(data, text):
    return [{"type": "user", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(data).decode()}},
        {"type": "text", "text": text}]}}]


def sc_image_prompt(s, m, d, tag):
    t0 = time.time()
    r = s.claude(m, d, stdin_json=_image_prompt(png((220, 20, 20)), "What colour is this image? One word."), log=f"{tag}.jsonl")
    flags = {"images_sent": s.images_sent(m, t0)}
    if not r.ok():
        return "FAIL", r.why(), flags
    if not has(r.text(), "red"):
        return "FAIL", f"answer {r.text()[:120]!r} (images in the calls to the provider: {flags['images_sent']})", flags
    return "PASS", "an image in the prompt reached the model", flags


def sc_compact(s, m, d, tag):
    r1 = s.claude(m, d, "Use Read on big.txt (all of it), then reply with its last line only.", log=f"{tag}-1.jsonl")
    if not r1.ok():
        return "FAIL", f"long read: {r1.why()}", {}
    r2 = s.claude(m, d, "/compact", resume=r1.session, log=f"{tag}-2.jsonl")
    compacted = any(e.get("type") == "system" and e.get("subtype") == "compact_boundary" for e in r2.events)
    if not r2.ok() or not compacted:
        return "FAIL", f"/compact: {r2.why() or 'no compact_boundary'}", {}
    r3 = s.claude(m, d, f"What is the secret word in notes.txt? Use Read. Reply with the word only.", resume=r2.session or r1.session, log=f"{tag}-3.jsonl")
    if not r3.ok():
        return "FAIL", f"after /compact: {r3.why()}", {}
    if not has(r3.text(), SECRET):
        return "FAIL", f"after /compact: answer {r3.text()[:80]!r}", {}
    return "PASS", f"compacted ({(r1.result or {}).get('usage', {}).get('input_tokens', '?')} input tokens before), then answered", {}


def sc_count_tokens(s, m, d, tag):
    # what Claude Code sends to /v1/messages/count_tokens (a system prompt, tools, a short history), through the gateway
    body = {"model": m, "system": [{"type": "text", "text": "You are a coding agent."}],
            "tools": [{"name": "Read", "description": "Read a file", "input_schema": {"type": "object", "properties": {"file_path": {"type": "string"}}, "required": ["file_path"]}}],
            "messages": [{"role": "user", "content": "Count these tokens, please."}]}
    code, text = s.gateway("/v1/messages/count_tokens", body)
    try:
        n = json.loads(text).get("input_tokens")
    except (ValueError, AttributeError):
        n = None
    with open(os.path.join(s.logs, f"{tag}-api.json"), "w", encoding="utf-8") as f:
        f.write(f"{code}\n{text}")
    r = s.claude(m, d, "/context", log=f"{tag}-context.jsonl")
    flags = {"http": code, "input_tokens": n}
    if code != "200" or not isinstance(n, int) or n <= 0:
        return "FAIL", f"count_tokens: HTTP {code}: {text[:600]}", flags
    if not r.ok():
        return "FAIL", f"/context: {r.why()}", flags
    return "PASS", f"count_tokens {n} tokens; /context answered", flags


def sc_switch(s, m, d, tag):
    if m == CONTROL:
        return "SKIP", "the control is the model switched from", {}
    env = {"MAX_THINKING_TOKENS": "2048"}
    r1 = s.claude(CONTROL, d, "Use Read on a.txt, then use Bash to run: echo hi-from-bash. Reply with the number in a.txt.", env=env, log=f"{tag}-1.jsonl")
    if not r1.ok():
        return "FAIL", f"turn 1 on {CONTROL}: {r1.why()}", {}
    thought = bool(r1.blocks("thinking"))
    r2 = s.claude(m, d, "Now use Read on b.txt. Reply on one line with: the number in a.txt, what the echo printed, and the number in b.txt.",
                  resume=r1.session, env=env, log=f"{tag}-2.jsonl")
    if not r2.ok():
        return "FAIL", f"turn 2 on {m}, replaying {CONTROL}'s {'thinking, ' if thought else ''}tool calls: {r2.why()}", {"thinking": thought}
    if not (has(r2.text(), "41") and has(r2.text(), "hi-from-bash")):
        return "FAIL", f"turn 2 on {m}: answer {r2.text()[:160]!r}", {"thinking": thought}
    r3 = s.claude(CONTROL, d, "Reply with the sum of the numbers in a.txt and b.txt, just the number.", resume=r1.session, env=env, log=f"{tag}-3.jsonl")
    if not r3.ok():
        return "FAIL", f"turn 3 back on {CONTROL}, replaying {m}'s turn: {r3.why()}", {"thinking": thought}
    if not has(r3.text(), "42"):
        return "FAIL", f"turn 3 on {CONTROL}: answer {r3.text()[:80]!r}", {"thinking": thought}
    return "PASS", f"{CONTROL} ({'thinking, ' if thought else ''}tools) -> {m} -> {CONTROL}", {"thinking": thought}


def code_page_events(s, lines):
    """What the Code page shows for these stream-json lines (code/server/normalize.mjs fromSdk): its error events."""
    script = ("import { fromSdk } from " + json.dumps("file://" + os.path.join(s.a.code_dir, "server", "normalize.mjs")) + ";\n"
              "let buf = ''; process.stdin.on('data', (d) => buf += d); process.stdin.on('end', () => {\n"
              "  const out = []; for (const l of buf.split('\\n')) { if (!l.trim().startsWith('{')) continue;\n"
              "    try { for (const ev of fromSdk(JSON.parse(l))) if (ev.type === 'error' || ev.type === 'local') out.push(ev); } catch {} }\n"
              "  process.stdout.write(JSON.stringify(out)); });\n")
    try:
        p = subprocess.run(["node", "--input-type=module", "-e", script], input=lines.encode(), capture_output=True, timeout=60)
        return json.loads(p.stdout or b"[]")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def sc_error(s, m, d, tag):
    # a provider's refusal: the stand-ins refuse PARITY-REFUSE as the gateway / OpenRouter would; Bedrock refuses an image
    # that is not one (its own ValidationException)
    if family(m) in ("explabs", "openrouter"):
        want = "cybersecurity policy" if family(m) == "explabs" else "content policy (stand-in)"
        r = s.claude(m, d, "PARITY-REFUSE: say hi", log=f"{tag}.jsonl")
    else:
        # (Bedrock's own words: a deployment of the suite's whose model id Bedrock does not know)
        want = "model identifier is invalid"
        r = s.claude("parity-bad-bedrock", d, "Say hi.", log=f"{tag}.jsonl")
    said = " ".join(r.api_errors()) or r.why()
    events = code_page_events(s, r.raw) or []
    page_error = [e for e in events if e.get("type") == "error"]
    page_text = " ".join(f"{e.get('message', '')} {e.get('said', '')}" for e in page_error)
    flags = {"claude_code": said[:600], "code_page": page_text[:600]}
    if r.ok():
        return "FAIL", f"no error: the request was answered ({r.text()[:120]!r})", flags
    if want and want.lower() not in said.lower():
        return "FAIL", f"Claude Code did not show the provider's words ({want!r}): {said[:600]}", flags
    if not page_error:
        return "FAIL", f"the Code page shows no error event; Claude Code said: {said[:400]}", flags
    # the page's error must carry the provider's text, not only "Claude Code reported: unknown"
    probe = want or _provider_words(said)
    if probe and probe.lower() not in page_text.lower():
        return "FAIL", f"the Code page shows {page_text[:200]!r}, not the provider's words ({probe[:120]!r}); Claude Code said: {said[:400]}", flags
    return "PASS", f"Claude Code and the Code page show it: {page_text[:300]}", flags


def _provider_words(said):
    """A distinctive part of the provider's message in Claude Code's API error text (its "message" field), or None."""
    m = re.search(r'"message"\s*:\s*"([^"]{8,})"', said)
    return m.group(1)[:60] if m else None


def sc_webfetch(s, m, d, tag):
    r = s.claude(m, d, "Use the WebFetch tool to fetch https://example.com and reply with the page's title only.", log=f"{tag}.jsonl")
    errs = [t[:300] for bad, t in r.tool_results() if bad]
    if not r.ok():
        return "FAIL", r.why(), {}
    if "WebFetch" not in r.tools():
        return "FAIL", f"WebFetch not called (tools {r.tools()}): {r.text()[:160]!r}", {}
    if not has(r.text(), "Example Domain"):
        return "FAIL", f"answer {r.text()[:160]!r}; tool errors {errs}", {}
    return "PASS", "fetched, summarised by the small model, answered", {}


def sc_websearch(s, m, d, tag):
    r = s.claude(m, d, "Use the WebSearch tool to search the web for: IANA example domain. Reply with one URL from the results only.", log=f"{tag}.jsonl")
    res = [(bad, t) for bad, t in r.tool_results()]
    flags = {"tools": r.tools(), "results": [t[:300] for _, t in res]}
    if not r.ok():
        return "FAIL", r.why(), flags
    if "WebSearch" not in r.tools():
        return "FAIL", f"WebSearch not called (tools {r.tools()}): {r.text()[:200]!r}", flags
    bad = [t for b, t in res if b]
    if bad:
        return "FAIL", f"WebSearch failed: {bad[0][:500]}", flags
    said = " ".join(t for _, t in res)
    counts = [u.get("searchCount") for u in r.tool_use_results() if isinstance(u, dict) and "searchCount" in u]
    if any(isinstance(c, int) and c > 0 for c in counts):
        return "PASS", f"searched ({max(counts)} search): {r.text()[:120]!r}", flags
    if "Web search isn't available for" in said:
        return "PASS", f"said plainly: {said[:200]!r}", flags
    # (the stand-in's search results: only a search finds them — the gateway's own search, which Claude Code counts as 0)
    if family(m) in ("explabs", "openrouter") and ("iana.org/domains/reserved" in said or "https://example.com/" in said):
        return "PASS", f"searched at the provider (Claude Code counts 0 searches): {r.text()[:120]!r}", flags
    return "FAIL", f"no search ran and the tool did not say so: the model answered as though it had searched: {said[:300]!r}", flags


SCENARIOS = {"turns": sc_turns, "thinking": sc_thinking, "tools": sc_tools, "parallel": sc_parallel, "think-tool": sc_think_tool,
             "image-read": sc_image_read, "image-prompt": sc_image_prompt, "compact": sc_compact, "count-tokens": sc_count_tokens,
             "switch": sc_switch, "error": sc_error, "webfetch": sc_webfetch, "websearch": sc_websearch}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="bne2e-parity")
    ap.add_argument("--out")
    ap.add_argument("--models", default="")
    ap.add_argument("--scenarios", default="")
    ap.add_argument("--relay-model", default="")
    ap.add_argument("--or-mode", default="stand-in")
    ap.add_argument("--xl-mode", default="stand-in")
    ap.add_argument("--code-dir", default="")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--deadline-min", type=float, default=0)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        print("\n".join(SCENARIOS))
        return 0
    # a scenario for every model, or MODEL:SCENARIO entries: that model runs those alone (a rerun of what failed on an
    # expensive one)
    entries = [x for x in a.scenarios.split(",") if x]
    want = [x for x in entries if ":" not in x] or list(SCENARIOS)
    only = {}
    for x in entries:
        if x not in want:
            mm, _, sc = x.rpartition(":")
            only.setdefault(mm, []).append(sc)
    for x in want + [sc for v in only.values() for sc in v]:
        if x not in SCENARIOS:
            print(f"unknown scenario {x} ({', '.join(SCENARIOS)})", file=sys.stderr)
            return 2
    os.makedirs(a.out, exist_ok=True)
    s = Suite(a)
    s.ledger_since()

    stop_at = time.time() + a.deadline_min * 60 if a.deadline_min > 0 else None

    def one_model(m):
        print(f"==> {m} ({family(m)})", file=sys.stderr, flush=True)
        os.makedirs(os.path.join(s.logs, slug(m)), exist_ok=True)
        for scen in only.get(m, want):
            d = f"/workspace/{slug(m)}/{scen}"
            t0 = time.time()
            if stop_at and t0 > stop_at:
                s.record(m, scen, "SKIP", 0, f"not started: past the run's {a.deadline_min} min", [])
                continue
            try:
                s.seed(d)
                status, detail, flags = SCENARIOS[scen](s, m, d, f"{slug(m)}/{scen}")
            except Exception as e:  # noqa: BLE001 — a broken scenario is a failure of its own, never the end of the run
                status, detail, flags = "FAIL", f"the scenario broke: {type(e).__name__}: {e}", {}
            s.record(m, scen, status, time.time() - t0, detail, s.errors_for(m, t0), flags)

    models = [x for x in a.models.split(",") if x]
    with ThreadPoolExecutor(max_workers=max(1, min(a.jobs, len(models)))) as pool:
        list(pool.map(one_model, models))
    time.sleep(3)   # (LiteLLM's logging callback runs after the answer)
    with s.lock:
        s.calls += s.ledger_since()
        s.write()
    total, by = s.spend()
    fails = sum(1 for r in s.rows if r["status"] == "FAIL")
    print(f"==> {len(s.rows)} scenario runs, {fails} failed; Bedrock spend booked by LiteLLM: ${total:.4f} {by}", file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
