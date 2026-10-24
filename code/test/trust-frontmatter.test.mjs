// A skill's, command's or agent's front matter and shell commands as Claude Code reads them (server/trust.mjs, the
// trust step's reading — 2.1.296's own patterns, mirrored): the block after any whitespace opener Claude Code takes (a
// \f, a \v, an NBSP, U+2028, U+3000, CRs, blank lines), up to its first "---", a BOM off; grants found there, and in this
// page's plain reading too; anything not the same both ways never plain (never trusted). The shell commands a skill or
// command runs — ```! blocks and !`…` after whitespace, inline code blanked first — each listed. All of it linear.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { frontMatter, ccFrontMatterBlock, shellBlocks, summarize, stripJsonc, pluginsOf, hashOf, checkPlugins } from '../server/trust.mjs';
import { assertLinear } from './linear.mjs';
import { TERMINAL_DIR } from './helpers.mjs';
import path from 'node:path';

// bn-coded (terminal/, or the copy the image's test stage gets)
const bnCoded = () => import(path.join(TERMINAL_DIR, 'bin/bn-coded.mjs'));

const BASH = { key: 'allowed-tools', value: 'Bash(*)' };

test('H1: every opener Claude Code reads — the grants found, never plain unless it is the plain one', () => {
  const body = 'allowed-tools: Bash(*)\npermissionMode: bypassPermissions\n---\nRun it.\n';
  const grants = [BASH, { key: 'permissionMode', value: 'bypassPermissions' }];
  // (Claude Code's own: one BOM off, "---", whitespace as JavaScript's \s up to a line feed)
  for (const [label, opener, plain] of [['plain', '---\n', true], ['trailing spaces', '---   \n', true], ['a tab', '---\t\n', true], ['CRLF', '---\r\n', true],
    ['a BOM', '\uFEFF---\n', true], ['a blank line', '---\n\n', true], ['a form feed', '---\f\n', false], ['a vertical tab', '---\v\n', false],
    ['an NBSP', '---\u00a0\n', false], ['U+2028', '---\u2028\n', false], ['U+3000', '---\u3000\n', false], ['CR CR LF', '---\r\r\n', false],
    ['spaces and a form feed', '---  \f  \n', false], ['blank lines of spaces', '---\n  \n\t\n', false]]) {
    const t = `${opener}${body}`;
    assert.notEqual(ccFrontMatterBlock(t), null, `${label}: Claude Code reads a block`);
    const fm = frontMatter(t);
    assert.deepEqual(fm.grants, grants, label);
    assert.equal(fm.plain, plain, label);
  }
  // CRLF throughout: plain, the same grants
  assert.deepEqual(frontMatter('---\r\nallowed-tools: Bash(*)\r\n---\r\nGo.\r\n'), { grants: [BASH], plain: true });
  // a BOM only once: two BOMs and Claude Code reads no front matter — this page reads its grants all the same, never plain
  assert.deepEqual(frontMatter('\uFEFF\uFEFF---\nallowed-tools: Bash(*)\n---\n'), { grants: [BASH], plain: false });
  assert.deepEqual(frontMatter('\uFEFF\uFEFF\uFEFF---\nallowed-tools: Bash(*)\n---\n'), { grants: [BASH], plain: false });
  assert.deepEqual(frontMatter('\uFEFF\uFEFF# no front matter'), { grants: [], plain: true });
  assert.equal(ccFrontMatterBlock('\uFEFF\uFEFF---\nallowed-tools: Bash(*)\n---\n'), null);
});

test('H1: the block ends at Claude Code\'s first ---; a grant either reading finds is listed; anything off is not plain', () => {
  // (a "---" inside a value: Claude Code's block ends there — this page's plain reading goes on: both said, not plain)
  const inValue = '---\ndescription: before---after\nallowed-tools: Bash(*)\n---\nGo.\n';
  assert.equal(ccFrontMatterBlock(inValue), 'description: before');
  assert.deepEqual(frontMatter(inValue), { grants: [BASH], plain: false });
  // (a closer that is not on a line of its own: Claude Code's ends there, the plain reading finds none)
  assert.deepEqual(frontMatter('---\nallowed-tools: Bash(*)\n  ---\nGo.\n'), { grants: [BASH], plain: false });
  assert.deepEqual(frontMatter('---\nallowed-tools: Bash(*)---\nGo.\n'), { grants: [BASH], plain: false });
  // (starts with --- but Claude Code reads no block: not plain — never trusted)
  for (const t of ['---\nallowed-tools: Bash(*)\n', '---allowed-tools: Bash(*)\n---\n', '---\u2028allowed-tools: Bash(*)\n---\n', '---', '----\n']) {
    assert.equal(frontMatter(t).plain, false, JSON.stringify(t));
  }
  // (a CR alone is a line break to YAML: the grant after it found, not plain)
  assert.deepEqual(frontMatter('---\ndescription: x\rallowed-tools: Bash(*)\n---\n'), { grants: [BASH], plain: false });
  // (a block of more than 64 KiB: not plain)
  assert.equal(frontMatter(`---\nallowed-tools: Bash(*)\ndescription: ${'x'.repeat(70000)}\n---\n`).plain, false);
  // (no front matter at all: nothing, plain)
  assert.deepEqual(frontMatter('# A skill\n\nallowed-tools: Bash(*)\n'), { grants: [], plain: true });
  assert.deepEqual(frontMatter(' ---\nallowed-tools: Bash(*)\n---\n'), { grants: [], plain: true });
  // (a control character in the block but a tab or a line break — or a NEL, a line break to some YAML parsers: not plain,
  // the grant after it found)
  for (const c of ['\x00', '\x01', '\x0b', '\x0c', '\x1b', '\x1f', '\x85']) {
    assert.equal(frontMatter(`---\ndescription: a${c}b\nallowed-tools: Bash(*)\n---\n`).plain, false, JSON.stringify(c));
  }
  assert.deepEqual(frontMatter('---\ndescription: a\x85\nallowed-tools: Bash(*)\n---\n'), { grants: [BASH], plain: false });
  // (a key twice, in another case: not plain)
  assert.equal(frontMatter('---\nallowed-tools: Read\nAllowed-Tools: Bash(*)\n---\n').plain, false);
});

test('shell commands Claude Code runs each time a skill or command is used: ```! blocks and !`…` after whitespace, inline code blanked first', () => {
  const cmds = (t) => shellBlocks(t).list.map((x) => [x.kind, x.command]);
  assert.deepEqual(cmds('Status: !`git status --short`\n- Log: !`git log -1`'), [['inline', 'git status --short'], ['inline', 'git log -1']]);
  assert.deepEqual(cmds('```!\r\nnpm test\r\nnpm run lint\r\n```\nthen'), [['fenced', 'npm test\nnpm run lint']]);
  // (across lines, as Claude Code's [^`]+ reads it)
  assert.deepEqual(cmds('Run !`echo a\necho b` now'), [['inline', 'echo a\necho b']]);
  // (not after a letter; an empty one skipped; inline code blanked first — a ! inside it runs nothing)
  assert.deepEqual(cmds('a!`no` !`` ok'), []);
  assert.deepEqual(cmds('use `foo !`bar` baz'), []);
  assert.deepEqual(cmds('`code` !`yes`'), [['inline', 'yes']]);
  // (a fenced block with no closing ```: Claude Code runs nothing — listed anyway)
  assert.deepEqual(cmds('```!\nrm -rf /tmp/x\n'), [['open', 'rm -rf /tmp/x']]);
  // (a ```! block's own !` inside: both readings, as Claude Code does)
  assert.deepEqual(cmds('```!\nls\n```').length, 1);
  // the trust summary lists them with the file's grants
  const files = [{ name: '.claude/commands/go.md', size: 10, type: 'file', text: '---\nallowed-tools: Bash(git:*)\n---\nStatus: !`git status`\n```!\nmake\n```\n' }];
  assert.deepEqual(summarize(files).files[0].grants, [{ key: 'allowed-tools', value: 'Bash(git:*)' }, { key: 'runs in a shell when used (```!)', value: 'make' },
    { key: 'runs in a shell when used (!`…`)', value: 'git status' }]);
});

// Claude Code 2.1.296's own code, copied from its binary (the oracle — never used by the server; its patterns are
// quadratic on some inputs, so only small ones here): si (Gb, Pv) gives the body a skill's or command's shell commands
// are found in — its content —; cOe blanks inline code, gVn and hVn find the commands, Gtr lists them, with their places.
// blank: cOe — or, for the second reading, the lookbehind one (a span right after ! or ` not matched)
const BOM = String.fromCharCode(0xfeff), LS = String.fromCharCode(0x2028), NBSP = String.fromCharCode(0xa0);
const CC_BLANK = (x) => x.replace(/`[^`\n]+`/g, (n, r) => { const s = x[r - 1]; return s === '!' || s === '`' ? n : `\`${' '.repeat(n.length - 2)}\``; });
const LB_BLANK = (x) => x.replace(/(?<![!`])`[^`\n]+`/g, (n) => `\`${' '.repeat(n.length - 2)}\``);
// si(t) -> {content, at, matched}: the body Claude Code scans (its place in t), or the whole text when it reads no front
// matter (its content: the text as it was)
function si(t) {
  const e = t.charCodeAt(0) === 65279 ? t.slice(1) : t;
  const m = e.indexOf('---', 3) < 0 ? null : e.match(/^---\s*\n([\s\S]*?)---\s*\n?/);
  return m ? { content: e.slice(m[0].length), at: t.length - e.length + m[0].length, matched: true } : { content: t, at: 0, matched: false };
}
function ccShellCommands(e, blank = CC_BLANK, from = 0) {
  const gVn = /```!\s*\n?([\s\S]*?)\n?```/g, hVn = /(?<=^|\s)!`([^`]+)`/gm;
  const s5r = (x) => x.trim().replaceAll('\r\n', '\n');
  const n = e.matchAll(gVn), r = e.includes('!`') ? blank(e).matchAll(hVn) : [], out = [];
  for (const h of [...n, ...r]) { const y = s5r(h[1] ?? ''); if (y) out.push(`${from + h.index}\0${y}`); }
  return out;
}
// what Claude Code runs: Gtr(si(t).content)
const ccRuns = (t) => { const b = si(t); return ccShellCommands(b.content, CC_BLANK, b.at); };
const sorted = (l) => [...new Set(l)].sort();

test('the shell commands found: every one Claude Code runs (its own code as the oracle, on its real input — the body), and both readings of the whole text and the body — the union', () => {
  const mine = (t) => shellBlocks(t).list.filter((x) => x.kind !== 'open').map((x) => `${x.at}\0${x.command}`);
  const check = (t) => {
    const m = new Set(mine(t));
    for (const c of ccRuns(t)) assert.ok(m.has(c), `${JSON.stringify(t)}: Claude Code runs ${JSON.stringify(c.split('\0')[1])}, not listed`);
    const b = si(t);
    const union = [...ccShellCommands(t), ...ccShellCommands(t, LB_BLANK), ...(b.matched ? [...ccShellCommands(b.content, CC_BLANK, b.at), ...ccShellCommands(b.content, LB_BLANK, b.at)] : [])];
    assert.deepEqual(sorted(mine(t)), sorted(union), JSON.stringify(t));
  };
  // (the reviewer's: Claude Code runs only a — the lookbehind reading finds cmd too: both listed)
  assert.deepEqual(shellBlocks('!`a` b` !`cmd`').list.map((x) => x.command), ['a', 'cmd']);
  assert.deepEqual(ccShellCommands('!`a` b` !`cmd`').map((c) => c.split('\0')[1]), ['a']);
  // (M1: a !` left open in the front matter swallows the body's command in a scan of the whole text — Claude Code scans
  // the body alone, and runs it: listed)
  const fm = '---\ndescription: x !`\n---\nRun !`echo marker` now.\n';
  assert.ok(shellBlocks(fm).list.some((x) => x.command === 'echo marker'));
  assert.deepEqual(ccRuns(fm).map((c) => c.split('\0')[1]), ['echo marker']);
  assert.ok(shellBlocks('---\nx: 1\n---!`at the body start`').list.some((x) => x.command === 'at the body start'));
  for (const t of ['!`a` b` !`cmd`', '``!`x` !`y`', '!`a` `b !`c` d`', 'x `a` !`b` `c`', '`!`a`` !`b`', '!``a` !`b`', '```!\nls\n``` !`pwd` `q !`r` s`',
    '`a\n!`b` `c`', '!`a\r\nb` !`c`', ' !`a`!`b` !`c`', '`` !`a` ``', `!\`a\`${LS}!\`b\`${NBSP}!\`c\``, fm, `${BOM}---\nd: !\`\n---\n!\`x\``, '---\f\nd: `\n--- !`y` `z`']) check(t);
  // random texts of the characters that matter, front matter among them
  const parts = ['`', '!', '!`', '```!', '```', ' ', '\n', '\r\n', 'a', 'ls', '\t', LS, '$1', '---', '---\n', 'd: x', BOM, '\f'];
  let seed = 7;
  const next = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed; };
  for (let i = 0; i < 20000; i++) {
    let t = '';
    const n = 1 + (next() % 24);
    for (let k = 0; k < n; k++) t += parts[next() % parts.length];
    // (a ```! block with no closing ```: Claude Code runs nothing, this page lists it — the rest exactly the union)
    check(t);
  }
});

test('never a command cut or left out unseen: past 200 in a file, or one over 2,000 characters, the summary is incomplete', () => {
  const file = (text) => ({ name: '.claude/commands/go.md', size: text.length, type: 'file', text });
  const many = Array.from({ length: 201 }, (_, i) => `- !\`echo ${i}\``).join('\n');
  assert.equal(shellBlocks(many, 200).more, true);
  assert.equal(shellBlocks(many, 200).list.length, 200);
  let sm = summarize([file(many)]);
  assert.equal(sm.complete, false);
  assert.ok(sm.missing.some((m) => /more than 200 shell commands in one file/.test(m)), sm.missing.join('; '));
  sm = summarize([file(Array.from({ length: 200 }, (_, i) => `- !\`echo ${i}\``).join('\n'))]);
  assert.equal(sm.complete, true);
  const long = `!\`echo ${'x'.repeat(2100)}\``;
  assert.equal(shellBlocks(long).list[0].command.length, 2105, 'never cut');
  sm = summarize([file(long)]);
  assert.equal(sm.complete, false);
  assert.ok(sm.missing.some((m) => /a shell command too long to show/.test(m)), sm.missing.join('; '));
});

test('M-b and the rest: linear in the text — distinct keys in a closed block, whitespace openers, dashes, backticks', () => {
  const keys = (n) => `---\n${Array.from({ length: n }, (_, i) => `key${i}: value ${i}`).join('\n')}\n---\nbody\n`;
  assertLinear(keys, frontMatter, 'distinct keys, a closed block', { start: 1 << 10 });
  assertLinear((n) => `---\n${'tools: x\n'.repeat(n)}---\n`, frontMatter, 'one key again and again');
  assertLinear((n) => `---${' \n'.repeat(n)}x---`, frontMatter, 'an opener of whitespace and line feeds');
  assertLinear((n) => `---${' '.repeat(n * 4)}\n${'-'.repeat(n * 4)}`, frontMatter, 'spaces, then dashes');
  assertLinear((n) => `---\n${'a: b---'.repeat(n)}\n---\n`, frontMatter, '--- inside values');
  assertLinear((n) => `---\n${`k: ${' '.repeat(200)}x\n`.repeat(n / 8)}---\n`, frontMatter, 'runs of spaces inside lines');
  assertLinear((n) => `---\n${'\r'.repeat(n * 4)}---\n`, frontMatter, 'CRs');
  assertLinear((n) => `\`\`\`!${' '.repeat(n * 4)}`, (t) => shellBlocks(t), 'an unclosed ```! and whitespace');
  assertLinear((n) => ' !`'.repeat(n), (t) => shellBlocks(t), '!` again and again');
  assertLinear((n) => '`'.repeat(n * 4), (t) => shellBlocks(t), 'backticks only');
  assertLinear((n) => `!\`${'` x '.repeat(n)}`, (t) => shellBlocks(t), 'inline code spans after !`');
  assertLinear((n) => `${'`a\n'.repeat(n)} !\`x\``, (t) => shellBlocks(t), 'open spans across lines');
  assertLinear((n) => '```!```'.repeat(n), (t) => shellBlocks(t), 'empty fenced blocks');
  assertLinear((n) => ' !`x`'.repeat(n), (t) => shellBlocks(t, 1e9), 'many commands, every one listed');
});

test('another tool\'s file: plugins and marketplaces found by its parsed keys (any depth, any case, \\u escapes); one that cannot be read the way the tool does: never trusted', () => {
  const tool = (name, text, owner = 'GitHub Copilot') => ({ name, size: text.length, type: 'file', text, tool: owner, at: '' });
  const verdict = (f) => { const sm = summarize([f]); return { complete: sm.complete, notes: sm.notes.map((n) => n.note).join('; ') }; };
  // a key spelled with \u escapes is the same key once parsed (a regex on the raw text missed it)
  let v = verdict(tool('.github/mcp.json', '{"\\u0065xtraKnownMarketplaces": {"m": {"source": {"source": "directory", "path": "./m"}}}}'));
  assert.equal(v.complete, false); assert.match(v.notes, /plugins or a plugin marketplace \(extraKnownMarketplaces\)/);
  // a nested key, in another case
  v = verdict(tool('.grok/settings.json', '{"a": {"b": [{"Plugins": {"p": "./p"}}]}}', 'Grok'));
  assert.equal(v.complete, false); assert.match(v.notes, /\(Plugins\)/);
  assert.equal(verdict(tool('.github/x.json', '{"EXTRAKNOWNMARKETPLACES": {}}')).complete, false);
  // a .json that does not parse, even as JSONC: cannot be looked at — incomplete
  v = verdict(tool('.cursor/mcp.json', '{"mcpServers": {', 'Cursor'));
  assert.equal(v.complete, false); assert.match(v.notes, /not valid JSON or JSONC/);
  // JSONC as the tools read it (comments, trailing commas): parsed, and a key in it found
  assert.equal(verdict(tool('.vscode/mcp.json', '// servers\r\n{"servers": {"x": {"command": "a"},},}', 'VS Code (older GitHub Copilot CLIs)')).complete, true, 'control');
  assert.equal(verdict(tool('.vscode/mcp.json', '{/* c */ "servers": {}, "plugins": [],}')).complete, false);
  assert.equal(stripJsonc('{"a": "x // not a comment, ]", /* c */ "b": [1,],}'), '{"a": "x // not a comment, ]",   "b": [1]}');
  // a line comment ends at \r, U+2028 and U+2029 for JSONC parsers (the key after it is read): a line break JSON and
  // JSONC readers do not agree on, outside a string, is never looked past; an open /* neither
  for (const br of ['\r', '\u2028', '\u2029']) {
    const t = `{// x${br}"extraKnownMarketplaces": {"m": {}}}`;
    assert.equal(stripJsonc(t), null, JSON.stringify(br));
    assert.equal(verdict(tool('.github/mcp.json', t)).complete, false, JSON.stringify(br));
  }
  assert.equal(stripJsonc('{"a": 1 /* open'), null);
  assert.equal(verdict(tool('.github/mcp.json', '{"a": 1} /* "extraKnownMarketplaces": {} ')).complete, false);
  assert.equal(stripJsonc('{"a": "line\u2028sep"}'), '{"a": "line\u2028sep"}', 'inside a string: JSON\'s own');
  // TOML (Codex) and YAML: no parser here — anything that could spell a key otherwise than as written cannot be looked
  // at; the rest searched whole
  assert.equal(verdict(tool('.codex/config.toml', '[mcp_servers.x]\ncommand = "a"\n', 'Codex')).complete, true, 'control');
  assert.equal(verdict(tool('.codex/config.toml', '["\\x6Darketplaces".m]\npath = "./m"\n', 'Codex')).complete, false, 'a \\x escape');
  assert.equal(verdict(tool('.codex/config.toml', '["\\u006Darketplaces".m]\npath = "./m"\n', 'Codex')).complete, false, 'a \\u escape');
  assert.equal(verdict(tool('.codex/config.toml', '[plugins."p@m"]\nenabled = true\n', 'Codex')).complete, false);
  assert.equal(verdict(tool('.grok/config.yaml', 'model: x\nservers:\n  - name: a\n', 'Grok')).complete, true, 'control');
  v = verdict(tool('.grok/config.yaml', '"mar\\\n  ketplaces": {m: 1}\n', 'Grok'));
  assert.equal(v.complete, false, 'a folded line'); assert.match(v.notes, /a backslash/);
  assert.equal(verdict(tool('.grok/config.yaml', '? x\n: 1\n', 'Grok')).complete, false, 'a complex key');
  v = verdict(tool('.grok/config.yml', 'base: &b {a: 1}\nmine:\n  <<: *b\n', 'Grok'));
  assert.equal(v.complete, false, 'a merge'); assert.match(v.notes, /a merge key/);
  assert.equal(verdict(tool('.grok/config.yml', 'k: &k x\n*k : 1\n', 'Grok')).complete, false, 'an alias as a key');
  assert.equal(verdict(tool('.grok/config.yml', 'a: !!binary bWFya2V0cGxhY2Vz\n', 'Grok')).complete, false, 'a tag');
  assert.equal(verdict(tool('.agents/plugins/marketplace.json', '{"name": "m"}', 'Codex, Cursor, Grok and GitHub Copilot')).complete, false);
  assert.deepEqual(pluginsOf('.github/hooks/h.json', '{"hooks": {}}'), { key: null, unreadable: null });
  // exact names only, never a word that holds one (a dependency named eslint-plugin-react, an MCP server my-plugin-server),
  // and only in what is parsed: a Markdown file's text is not a key
  assert.deepEqual(pluginsOf('.github/x/package.json', '{"devDependencies": {"eslint-plugin-react": "7"}, "pluginOptions": {}}'), { key: null, unreadable: null });
  assert.equal(pluginsOf('.cursor/mcp.json', '{"mcpServers": {"my-plugin-server": {"command": "node"}}}').key, null);
  assert.equal(pluginsOf('.grok/config.yaml', 'name: eslint-plugin-react\n').key, null);
  assert.equal(pluginsOf('.grok/config.yaml', 'additional_plugins: [a]\n').key, 'additional_plugins');
  assert.equal(pluginsOf('.github/copilot/settings.json', '{"Plugin-Dirs": ["./p"]}').key, 'Plugin-Dirs');
  assert.equal(pluginsOf('.agents/skills/s/SKILL.md', 'see "marketplaces": x').key, null);
  // a name a folding disk opens as marketplace.json: one
  assert.equal(pluginsOf('.claude-plugin/marketplace.jſon', '{}').key, 'a marketplace.json');
});

test('Claude Code\'s own settings: a marketplace the project adds is never trusted; a plugin it turns on is listed when installed in the sandbox (its version in the hash), never trusted when not; .mcp.json names never count', () => {
  const own = (name, text) => ({ name, size: text.length, type: 'file', text, tool: null, at: '', sha256: 'a'.repeat(64), target: null });
  const installed = (id, version = '1.0.0') => ({ id, installed: true, versions: [{ version, commit: null }] });
  const reg = (list, registry = 'ok') => ({ list, registry });
  const verdict = (f, p = null) => { const sm = summarize([f], p); return { complete: sm.complete, notes: sm.notes.map((n) => n.note).join('; '), plugins: sm.plugins }; };
  let v;
  // an MCP server, or anything of .mcp.json, named like a plugin: an MCP server, as before
  assert.equal(verdict(own('.mcp.json', '{"mcpServers": {"my-plugin-server": {"command": "node", "args": ["plugin.js"]}}}')).complete, true);
  // the keys known to be harmless in a project's file: shown, trustable
  assert.equal(verdict(own('.claude/settings.json', '{"pluginConfigs": {"p@m": {"a": 1}}, "strictKnownMarketplaces": [], "allowedMarketplaces": []}')).complete, true);
  // Claude Code 2.1.309's keys that bring plugins, by their exact names (in any case): never trusted; a key it does not
  // read (pluginMarketplaces): shown under Other settings, as any other
  for (const k of ['plugins', 'pluginDirs', 'additionalPlugins', 'syncClaudeAiPlugins', 'PREPENDPLUGINS', 'appendPlugins', 'pluginSuggestionMarketplaces']) {
    v = verdict(own('.claude/settings.json', JSON.stringify({ [k]: ['./p'] })));
    assert.equal(v.complete, false, k); assert.match(v.notes, /names plugins/, k);
  }
  assert.equal(verdict(own('.claude/settings.json', '{"pluginMarketplaces": {"m": {}}}')).complete, true);
  assert.deepEqual(summarize([own('.claude/settings.json', '{"pluginMarketplaces": {"m": {}}}')]).other.map((o) => o.key), ['pluginMarketplaces']);
  // an env variable of Claude Code's that could steer where plugins come from: never trusted, the variable named
  v = verdict(own('.claude/settings.json', '{"env": {"CLAUDE_CODE_PLUGIN_SEED_DIR": "./p"}}'));
  assert.equal(v.complete, false); assert.match(v.notes, /sets CLAUDE_CODE_PLUGIN_SEED_DIR/);
  assert.equal(verdict(own('.claude/settings.json', '{"env": {"ESLINT_PLUGIN_X": "1"}}')).complete, true);
  // a settings file a folding disk opens as .claude/settings.json: read as one
  v = verdict(own('.claude/ſettings.json', '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "evil"}]}]}}'));
  assert.deepEqual(summarize([own('.claude/ſettings.json', '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "evil"}]}]}}')]).hooks.map((h) => h.command), ['evil']);
  // enabledPlugins: a plugin installed in the sandbox — listed, trustable
  v = verdict(own('.claude/settings.json', '{"enabledPlugins": {"fmt@acme": true, "old@acme": false}}'), reg([installed('fmt@acme')]));
  assert.equal(v.complete, true, v.notes);
  assert.deepEqual(v.plugins.map((p) => [p.id, p.on, p.version]), [['fmt@acme', true, '1.0.0'], ['old@acme', false, null]]);
  // its version is in the hash: updated in the sandbox, looked at again
  const files = [own('.claude/settings.json', '{"enabledPlugins": {"fmt@acme": true}}')];
  assert.notEqual(hashOf(files, reg([installed('fmt@acme', '1.0.0')])), hashOf(files, reg([installed('fmt@acme', '1.1.0')])));
  assert.equal(hashOf(files, null), hashOf(files), 'no plugin turned on: the files\' hash alone, as before');
  // not installed there (Claude Code could fetch it), the sandbox's record unreadable, or nothing said: never trusted
  v = verdict(own('.claude/settings.json', '{"enabledPlugins": {"fmt@acme": true}}'), reg([{ id: 'fmt@acme', installed: false, versions: [] }], 'none'));
  assert.equal(v.complete, false); assert.match(v.notes, /not installed in the sandbox/);
  assert.equal(verdict(own('.claude/settings.json', '{"enabledPlugins": {"fmt@acme": true}}'), reg([], 'unreadable')).complete, false);
  assert.equal(verdict(own('.claude/settings.json', '{"enabledPlugins": {"fmt@acme": true}}'), null).complete, false);
  assert.equal(verdict(own('.claude/settings.json', '{"enabledPlugins": "fmt@acme"}'), reg([])).complete, false, 'not a list of plugins');
  // escaped and differently-cased spellings of each key: caught
  assert.equal(verdict(own('.claude/settings.json', '{"\\u0065nabledPlugins": {"x@m": true}}'), reg([])).complete, false);
  assert.equal(verdict(own('.claude/settings.local.json', '{"ENABLEDPLUGINS": ["x@m"]}'), reg([])).complete, false);
  // extraKnownMarketplaces (and its alias): code nobody here has looked at — never trusted
  for (const t of ['{"extraKnownMarketplaces": {"m": {"source": {"source": "github", "repo": "a/b"}}}}', '{"\\u0065xtraKnownMarketplaces": {}}',
    '{"EXTRAKNOWNMARKETPLACES": {}}', '{"additionalMarketplaces": {}}']) {
    v = verdict(own('.claude/settings.json', t), reg([]));
    assert.equal(v.complete, false, t); assert.match(v.notes, /adds a plugin marketplace/, t);
  }
  // checkPlugins: what bn-coded says fits, or the listing is unverifiable
  assert.deepEqual(checkPlugins({}), { plugins: null, planPlugins: null, ok: true });
  const both = (l, registry = 'ok', pl = l, planRegistry = 'ok') => ({ plugins: l, registry, planPlugins: pl, planRegistry });
  assert.equal(checkPlugins(both([installed('b@m'), installed('a@m')])).ok, false, 'out of order');
  assert.equal(checkPlugins(both([{ id: 'a@m', installed: true, versions: [] }])).ok, false, 'installed with no version');
  assert.equal(checkPlugins(both([installed('a@m')], 'maybe')).ok, false);
  assert.equal(checkPlugins({ plugins: [installed('a@m')], registry: 'ok' }).ok, false, 'your plan\'s record not said');
  assert.equal(checkPlugins(both([installed('a@m')], 'ok', [installed('b@m')])).ok, false, 'not the same plugins');
  assert.equal(checkPlugins(both([installed('a@m')], 'ok', [{ id: 'a@m', installed: false, versions: [] }], 'none')).ok, true);
});

test('line breaks YAML knows beyond \\n and \\r (NEL, LS, PS): a comment ends there for the tools\' YAML readers — never a key hidden behind one', () => {
  for (const br of ['\x85', '\u2028', '\u2029']) {
    // (front matter: the key after the break is read — never plain, its grant listed)
    const fm = frontMatter(`---\n# notes${br}allowed-tools: shell(*), write\n---\nGo.\n`);
    assert.equal(fm.plain, false, JSON.stringify(br));
    const sm = summarize([{ name: '.claude/agents/a.md', size: 1, type: 'file', text: `---\nname: a # x${br}mcpServers: evil\n---\n`, tool: null, at: '' }]);
    assert.equal(sm.complete, false, JSON.stringify(br));
    // (another tool's YAML: an alias, a complex key, a tag right after the break — cannot be looked at)
    for (const t of [`k: &k x${br}*k : 1\n`, `a: 1${br}? x\n: 1\n`, `a: 1${br}!!binary x: 1\n`]) {
      assert.notEqual(pluginsOf('.grok/config.yml', t).unreadable, null, JSON.stringify([br, t]));
    }
  }
});

test('stripJsonc and pluginsOf: linear in the text', () => {
  assertLinear((n) => '-*'.repeat(n), (t) => pluginsOf('.github/x.yml', t), 'aliases after dashes');
  assertLinear((n) => `${'- '.repeat(n)}*`, (t) => pluginsOf('.github/x.yml', t), 'dashes, an alias at the end');
  assertLinear((n) => ' ?'.repeat(n), (t) => pluginsOf('.github/x.yml', t), 'question marks');
  assertLinear((n) => '{,'.repeat(n), (t) => pluginsOf('.github/x.yml', t), 'flow openers');
  assertLinear((n) => `{${'"a": 1, // x\n'.repeat(n)}}`, stripJsonc, 'comments');
  assertLinear((n) => `[${',     '.repeat(n)}]`, stripJsonc, 'commas and whitespace');
  assertLinear((n) => `${'/* x */'.repeat(n)}`, stripJsonc, 'block comments');
  assertLinear((n) => `"${'\\"'.repeat(n)}`, stripJsonc, 'an open string of escapes');
  assertLinear((n) => `${'\\u0061'.repeat(n)}`, (t) => pluginsOf('a.toml', t), 'escapes in TOML');
  assertLinear((n) => `${'['.repeat(n)}`, (t) => pluginsOf('a.json', t), 'an open nesting');
});

test('Claude on your plan has its own plugin record: a plugin installed for Bedrock but not on your plan — Bedrock sessions get the project\'s settings, plan sessions start with your own, said why', async () => {
  const crypto = await import('node:crypto');
  const { makeTrust, hashOf, withheldText, ALL_SOURCES, USER_SOURCES } = await import('../server/trust.mjs');
  const { TRUST_EPOCH } = await import('../server/projects.mjs');
  const { Session } = await import('../server/sessions.mjs');
  const sha = (t) => crypto.createHash('sha256').update(t).digest('hex');
  const text = '{"enabledPlugins": {"fmt@acme": true}}';
  const files = [{ name: '.claude/settings.json', type: 'file', size: text.length, sha256: sha(text), text, target: null, at: '', surface: '.claude' }];
  const inst = (version) => ({ id: 'fmt@acme', installed: true, versions: [{ version, commit: null }] });
  const bed = { list: [inst('1.0.0')], registry: 'ok' };
  let plan = { list: [{ id: 'fmt@acme', installed: false, versions: [] }], registry: 'ok' };
  const call = async (req) => ({ result: { files: req.text === false ? files.map(({ text: _t, ...f }) => f) : files, hash: hashOf(files, bed), verifiable: true, over: null,
    plugins: bed.list, registry: bed.registry, planPlugins: plan.list, planRegistry: plan.registry, planHash: hashOf(files, plan) } });
  const rec = { id: 'p1', root: 'proj', name: 'proj', trust: null };
  const trust = makeTrust({ call, store: () => ({ list: () => [rec],
    trust: (id, hash, planHash) => { rec.trust = hash ? { hash, at: 1, epoch: TRUST_EPOCH, ...(planHash === undefined ? {} : { planHash }) } : null; } }) });
  let v = await trust.view(rec);
  assert.equal(v.summary.complete, true, v.summary.missing.join('; '));
  assert.match(v.summary.notes.map((n) => n.note).join('; '), /Claude on your plan has not installed: its sessions here start with your own settings only/);
  // what Trust confirms is what the dialog showed: your plan's record (or the sandbox's) changed in between — a
  // conflict, nothing stored
  const shown = v.hash;
  plan = { list: [inst('2.0.0')], registry: 'ok' };
  assert.match((await trust.trust(rec, shown)).conflict, /changed since you looked/);
  assert.equal(rec.trust, null);
  plan = { list: [{ id: 'fmt@acme', installed: false, versions: [] }], registry: 'ok' };
  bed.list = [inst('1.0.1')];
  assert.match((await trust.trust(rec, shown)).conflict, /changed since you looked/);
  assert.equal(rec.trust, null);
  bed.list = [inst('1.0.0')];
  v = await trust.view(rec);
  assert.equal(v.hash, shown, 'the same again: the same to confirm');
  assert.deepEqual(v.summary.plugins.map((p) => [p.id, p.version, p.planVersion]), [['fmt@acme', '1.0.0', null]]);
  assert.equal((await trust.trust(rec, v.hash)).conflict, null);
  assert.equal(rec.trust.planHash, null, 'no trust for your plan');
  let d = await trust.decide('/workspace/proj');
  assert.equal(d.state, 'trusted'); assert.deepEqual(d.sources, ALL_SOURCES);
  assert.equal(d.plan.state, 'untrusted'); assert.deepEqual(d.plan.sources, USER_SOURCES); assert.equal(d.plan.strictMcp, true); assert.equal(d.plan.reason, 'plan-plugins');
  assert.match(withheldText(d.plan), /turns on plugins Claude on your plan hasn't installed — started with your own settings only/);
  // each session takes its own: a Bedrock one the project's settings, one on your plan its own decision
  const s = Object.create(Session.prototype);
  s.plan = true; assert.equal(s.ownSettings(d), d.plan);
  s.plan = false; assert.equal(s.ownSettings(d), d);
  // installed on your plan too: not applied until trusted again — then both
  plan = { list: [inst('1.0.0')], registry: 'ok' };
  d = await trust.decide('/workspace/proj');
  assert.equal(d.state, 'trusted'); assert.equal(d.plan.state, 'changed'); assert.equal(d.plan.reason, undefined);
  v = await trust.view(rec);
  assert.deepEqual(v.summary.plugins.map((p) => p.planVersion), ['1.0.0']);
  assert.equal((await trust.trust(rec, v.hash)).conflict, null);
  d = await trust.decide('/workspace/proj');
  assert.equal(d.plan.state, 'trusted'); assert.deepEqual(d.plan.sources, ALL_SOURCES);
  // updated on your plan only: looked at again there, Bedrock's trust holds
  plan = { list: [inst('1.1.0')], registry: 'ok' };
  d = await trust.decide('/workspace/proj');
  assert.equal(d.state, 'trusted'); assert.equal(d.plan.state, 'changed');
  // its record unreadable: not applied, said why
  plan = { list: [{ id: 'fmt@acme', installed: false, versions: [] }], registry: 'unreadable' };
  d = await trust.decide('/workspace/proj');
  assert.equal(d.plan.reason, 'plan-plugins'); assert.deepEqual(d.plan.sources, USER_SOURCES);
});

test('a row\'s place is fixed by its name: no other folder and surface fit it, so whose each file is (shown in the dialog) is covered by the names Trust confirms', async () => {
  const { placeOf } = await import('../server/trust.mjs');
  const ROOT = '/workspace/mono/app';
  for (const [name, at, surface] of [['/workspace/mono/.github/mcp.json', '/workspace/mono', '.github/mcp.json'],
    ['/workspace/mono/.claude/settings.json', '/workspace/mono', '.claude/settings.json'], ['/workspace/mono/.claude/plugins/p/h.json', '/workspace/mono', '.claude/plugins'],
    ['/workspace/mono/.codex/config.toml', '/workspace/mono', '.codex'], ['/workspace/mono/lsp.json', '/workspace/mono', 'lsp.json']]) {
    assert.ok(placeOf({ name, at, surface }, ROOT), name);
    const parts = name.slice(1).split('/');
    for (let i = 1; i < parts.length; i++) {
      for (let j = i + 1; j <= parts.length; j++) {
        const a = `/${parts.slice(0, i).join('/')}`, sfc = parts.slice(i, j).join('/');
        if (a !== at || sfc !== surface) assert.equal(placeOf({ name, at: a, surface: sfc }, ROOT), null, `${name}: ${a} + ${sfc}`);
      }
    }
  }
  for (const [name, surface] of [['.github/hooks/h.json', '.github/hooks'], ['.claude/plugins/p/h.json', '.claude'], ['.mcp.json', '.mcp.json'], ['lsp.json', 'lsp.json']]) {
    assert.ok(placeOf({ name, at: '', surface }, ROOT), name);
    const parts = name.split('/');
    for (let j = 1; j <= parts.length; j++) {
      const sfc = parts.slice(0, j).join('/');
      if (sfc !== surface) assert.equal(placeOf({ name, at: '', surface: sfc }, ROOT), null, `${name}: ${sfc}`);
    }
  }  // which part each is in — Claude Code's (v0.23.0's listing: the project's own .claude/ and .mcp.json, the six trees
  // above it) or the other tools' — by the folded surface, as bn-coded puts it
  const partOf = (name, at, surface, type = 'file') => placeOf({ name, at, surface, type }, ROOT)?.claude;
  assert.equal(partOf('.claude/settings.json', '', '.claude'), true);
  assert.equal(partOf('.CLAUDE/plugins/p/h.json', '', '.CLAUDE'), true);
  assert.equal(partOf('.mcp.jſon', '', '.mcp.jſon'), true);
  assert.equal(partOf('.github/hooks/h.json', '', '.github/hooks'), false);
  assert.equal(partOf('/workspace/mono/.claude/skills/s/SKILL.md', '/workspace/mono', '.claude/skills'), true);
  assert.equal(partOf('/workspace/mono/.claude/ſkills/s/SKILL.md', '/workspace/mono', '.claude/ſkills'), true);
  assert.equal(partOf('/workspace/mono/.claude', '/workspace/mono', '.claude'), true, 'a .claude above that is no folder');
  assert.equal(partOf('/workspace/mono/.claude/settings.json', '/workspace/mono', '.claude/settings.json'), false);
  assert.equal(partOf('/workspace/mono/.claude/ſettings.json', '/workspace/mono', '.claude/ſettings.json'), false);
  assert.equal(partOf('/workspace/mono/.claude/plugins/p/h.json', '/workspace/mono', '.claude/plugins'), false);
  assert.equal(partOf('/workspace/mono/.mcp.json', '/workspace/mono', '.mcp.json'), false);
  // the workspace itself is never a folder above (its .claude is your own)
  assert.equal(placeOf({ name: '/workspace/.claude/skills/s.md', at: '/workspace', surface: '.claude/skills' }, ROOT), null);
  // a row by its name alone: only a folder directly under .github/
  assert.equal(partOf('.github/workflows', '', '.github/workflows', 'name'), false);
  assert.equal(partOf('/workspace/mono/.github/workflows', '/workspace/mono', '.github/workflows', 'name'), false);
  for (const [name, surface] of [['.claude/skills', '.claude'], ['.github/hooks/x', '.github/hooks'], ['.github/workflows/x', '.github/workflows'], ['.codex', '.codex'],
    ['.github', '.github'], ['.github/hooks', '.github/hooks'], ['.github/Skills', '.github/Skills'], ['.github/agentſ', '.github/agentſ'],
    // (a file Copilot reads there — forged as a row by its name alone: what it holds would never be in the hash)
    ['.github/mcp.json', '.github/mcp.json'], ['.github/LSP.json', '.github/LSP.json'], ['.GitHub/allowed_models.txt', '.GitHub/allowed_models.txt'],
    ['.github/plugin.json', '.github/plugin.json'], ['.github/copilot-instructions.md', '.github/copilot-instructions.md'], ['.github/instructions', '.github/instructions']]) {
    assert.equal(placeOf({ name, at: '', surface, type: 'name' }, ROOT), null, name);
  }
  assert.equal(placeOf({ name: '/workspace/mono/.github/mcp.json', at: '/workspace/mono', surface: '.github/mcp.json', type: 'name' }, ROOT), null, 'above too');
  // and so the whole listing is unverifiable: both parts (a sandbox that forged it is not believed for either)
  const { checkFiles } = await import('../server/trust.mjs');
  assert.equal(checkFiles({ files: [{ name: '.claude/settings.json', type: 'file', at: '', surface: '.claude', sha256: 'a'.repeat(64), text: '{}' },
    { name: '.github/mcp.json', type: 'name', at: '', surface: '.github/mcp.json', sha256: 'b'.repeat(64) }] }, ROOT).ok, false);
});

test('a file not shown whole is not looked into (it is incomplete already); an entry nested too deep to show: incomplete, never an error', () => {
  const big = `${'-*'.repeat(140000)}\n`;
  const t0 = Date.now();
  const sm = summarize([{ name: '.github/x.yml', size: big.length, type: 'file', text: big, tool: 'GitHub Copilot', at: '' }]);
  assert.ok(Date.now() - t0 < 2000, `${Date.now() - t0} ms`);
  assert.equal(sm.complete, false);
  assert.match(sm.missing.join('; '), /another tool's file over/);
  let deep = '{}';
  for (let i = 0; i < 20000; i++) deep = `{"a":${deep}}`;
  for (const text of [`{"hooks": {"Stop": [{"hooks": [${deep}]}]}}`, `{"mcpServers": {"x": ${deep}}}`]) {
    const name = text.includes('mcpServers') ? '.mcp.json' : '.claude/settings.json';
    const r = summarize([{ name, size: text.length, type: 'file', text, tool: null, at: '' }]);
    assert.equal(r.complete, false, name);
    assert.match(r.missing.join('; '), /nested/, name);
  }
});

test('fold: the same in the code container as in bn-coded (names a disk that folds them opens as one)', async () => {
  const { fold } = await import('../server/trust.mjs');
  const { fold: bnFold } = await bnCoded();
  for (const n of ['.Curſor', 'lſp.json', '.ﬂow', 'Straße', '.CLAUDE', 'ǅ', 'ﬁle', 'Ⅻ', 'ｃｏｄｅ', 'K', 'İ', 'ΐ']) assert.equal(fold(n), bnFold(n), n);
  assert.equal(fold('.curſor'), '.cursor');
  assert.equal(fold('.ﬂ'), '.fl');
  assert.equal(fold('ß'), 'ss');
  // to a fixpoint: ẞ lowers to ß, which folds to ss only on a second round (a disk that folds names opens claẞ as class)
  assert.equal(fold('ẞ'), 'ss');
  assert.equal(fold('claẞ'), 'class');
  assert.equal(bnFold('claẞ'), 'class');
  // every code point of planes 0–3 and 14: a fold is folded already, and the same whatever the case or the
  // decomposition it was written in (what a disk that folds names in full and normalizes treats as one name)
  const bad = [];
  for (const [a, b] of [[0, 0x40000], [0xE0000, 0xF0000]]) {
    for (let c = a; c < b; c++) {
      if (c >= 0xD800 && c <= 0xDFFF) continue;
      const x = String.fromCodePoint(c), f = fold(x);
      if (fold(f) !== f || fold(x.toLowerCase()) !== f || fold(x.toUpperCase()) !== f || fold(x.normalize('NFD')) !== f || bnFold(x) !== f) bad.push(c.toString(16));
    }
  }
  assert.deepEqual(bad.slice(0, 20), []);
  // and the folders of .github/ the pinned Copilot reads: the same list
  const t = await import('../server/trust.mjs');
  const b = await bnCoded();
  for (const k of ['COPILOT_GITHUB_DIRS', 'COPILOT_GITHUB_FILES', 'GITHUB_INSTRUCTIONS']) assert.deepEqual(t[k], b[k], k);
});

test('the Copilot CLI the image pins is the one whose .github/ reading was audited (a new pin: audit COPILOT_GITHUB_DIRS again)', async () => {
  const fs = await import('node:fs');
  const { COPILOT_AUDITED } = await bnCoded();
  const df = fs.readFileSync(path.join(TERMINAL_DIR, 'Dockerfile'), 'utf8');
  const pins = [...df.matchAll(/^ARG COPILOT_VERSION=(\S+)/gm)].map((m) => m[1]);
  assert.deepEqual(pins, [COPILOT_AUDITED]);
});
