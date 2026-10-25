# Internal names

DevOS ADE was called bedrock-now until v0.25.0. Every name you read changed with it; the names below did not. They
are identifiers that data, links, sign-ins, installed apps and running services depend on, so they keep the old name
on every install, new ones too:

- **Your data:** the Docker Compose project `bedrock-now` (a second copy: its own `COMPOSE_PROJECT_NAME`), so its
  volumes (`bedrock-now_postgres-data`, …), networks and images (`bedrock-now/portal:local`, …) keep their names. A
  renamed project would start with empty volumes.
- **Your addresses:** `bedrock-now.localhost` and its `chat.`, `admin.`, `files.`, `code.` and `terminal.` hosts,
  `bedrock-now-preview.localhost`, and remote access's Tailscale names (the Services `bedrock-now`,
  `bedrock-now-chat`, …, the tag `tag:bedrock-now`, the node `bedrock-now-node`): bookmarks, an installed app,
  certificates and your tailnet's policy point at them.
- **Your settings and commands:** `BEDROCK_NOW_*` in `.env` and the environment, `./stack`, `bin/bedrock-now-helper`
  and its launchd and systemd units (`io.bedrock-now.helper.<project>`, `bedrock-now-helper-<project>.service`).
- **Your sign-in:** the portal's cookie names, the salts that sign its sessions and links, the `X-Requested-With`
  value its pages send, and the default sign-in email `admin@bedrock-now.local` — a new value would sign everyone out,
  void every link in flight, or sign Chat in as another user.
- **The installed app:** its id (`/`) and its link scheme `web+bedrocknow` — a new one would be a second app and break
  *Open in the app*. Only its name and icon change (your browser asks before it renames an installed app).
- **Folders:** an install's own folder (`~/bedrock-now` for one made before v0.25.0; new installs go to `~/devos-ade`),
  the workspace `~/bedrock-now-workspace` (new installs: `~/devos-ade-workspace`), the trash and temporary folders
  `.bedrock-now-trash` and `.bedrock-now-tmp` in your workspace and projects, the sandbox's own files
  (`/etc/bedrock-now.bashrc`, `~/.config/bedrock-now/`).
- **The GitHub App** was renamed with the project; its client ID did not change, so sign-ins and installs already
  connected keep working. Its slug (its address, `github.com/apps/<slug>`) is written in one place:
  `GITHUB_APP_SLUG` in `code/server/oauth.mjs` (`devos-ade`). A host signed in before stores the old slug until its
  next token renewal or *Test connection*, when GitHub's own answer replaces it.

## The allowlist

`tests/brand_check.py` (run by `tests/test_brand.sh`) fails on any `bedrock-now` (or `bedrock now`, `bedrock_now`,
`BEDROCK_NOW`, in any case) outside the tests and the CHANGELOG's entries before v0.25.0 — unless a pattern below
matches it in a file the row names, or `tests/fixtures/brand-allow.txt` names that file and that text, with why it
stays. Each pattern is a Python regular expression, and the old name must lie inside what it matches; *Files* are
globs (`*`: any file). A pattern or an exemption that no longer matches anything fails the check too.

| Name | Pattern | Files | Why it stays |
|---|---|---|---|
| Environment and `.env` names | `\bBEDROCK_NOW_(?:[A-Z0-9_]*[A-Z0-9]\b\|\*)` | * | settings and scripts read them |
| Identifiers in code | `\b_is_bedrock_now_dir\b\|\bmeta\.bedrock_now(?:_hidden)?\b\|["']bedrock_now(?:_hidden)?["']` | lib/guard.sh, lib/openrouter.sh, lib/owui.sh | a shell function; Open WebUI metadata keys stored with your models |
| The portal's hosts | `(?:[\w*${}<>:-]+\.)*bedrock-now(?:-preview)?\.localhost` | * | bookmarks, the installed app, cookies |
| Remote access's host names | `bedrock-now(?:-preview)?\.(?:<tailnet>\|[\w-]+)\.ts\.net` | * | certificates, the installed remote app |
| Tailscale Services and tag | `(?:svc:\|tag:)bedrock-now(?:-(?:chat\|admin\|files\|terminal\|code\|preview\|<project>))?\b` | * | your tailnet's policy and remote addresses |
| Tailscale's node name | `TS_HOSTNAME:-bedrock-now-node\b` | compose.tailscale.yaml | the node's name in your tailnet |
| The default sign-in email | `admin@bedrock-now\.local\b` | * | Chat's admin user |
| Trash, temporary and test folders | `\.bedrock-now-(?:trash\|tmp\|e2e)\b` | * | in your workspace and projects |
| Workspace folders, named with the new one | `^(?=.*devos-ade(?:-[\w<>%${}:-]+)?-workspace)(?:(?!bedrock-now(?!(?:-[\w<>%${}:-]+)?-workspace\b)).)*` | * | an install made before v0.25.0 keeps its folder: a line that names it names the new one too |
| The update helper | `bedrock-now-helper\b` | * | its file and its systemd units |
| launchd labels, Docker labels | `io\.bedrock-now\.[\w.%<>-]+` | * | the helper's units; the labels on the stack's containers |
| The sandbox's own files | `(?:/etc/bedrock-now\.bashrc\|ssh_config\.d/bedrock-now\.conf\|/usr/local/share/bedrock-now\|\.config/bedrock-now)\b` | * | inside the sandbox's image |
| `./stack open`'s browser profile | `(?:\.local/share\|Application Support)/bedrock-now\b` | docs/*.md | its sign-ins |
| The EC2 metadata guard | `bedrock-now-imds-guard[\w.-]*` | docs/cloud-vm.md | a systemd unit on the instance |
| Package names | `"name": "bedrock-now-(?:code(?:-web)?\|terminal-[\w-]+)"` | *package.json, *package-lock.json | npm packages of the images (never published) |
| The Compose project | `^name: bedrock-now$` | compose.yaml | the data volumes |
| The Compose project, where it is read | `COMPOSE_PROJECT_NAME:-bedrock-now\b` | compose*.yaml | images and hosts are named by it |
| The Compose project's default | `^DEFAULT_PROJECT=bedrock-now\b` | lib/common.sh | = `name:` in compose.yaml |
| Stack-owned names | `bedrock-now-(?:owner\|admin\|budget)\b` | lib/*.sh, docs/*.md | the owner marker volume, LiteLLM's admin, the budget banners |
| Signing salts | `bedrock-now\.(?:portal\.[\w{}.-]+\|terminal-launch)` | portal/portal/*.py | a new salt signs everyone out |
| The settings request | `bedrock-now-settings 1\b` | lib/settings_helper.sh, portal/portal/settings.py, docs/security.md | the portal and the helper speak it |
| The installed app's link scheme | `web\+bedrocknow\w*` | * | *Open in the app* (a page's meta tag names it too) |
| The pages' `X-Requested-With` | `[Xx]-[Rr]equested-[Ww]ith[^\n]{0,24}?bedrock-now` | * | the portal checks it |
| The old name, said as such | `(?i:formerly) bedrock-now` | * | so people can find it |

## devos-claude's old name

The command that runs Claude Code through DevOS ADE was called `claude-bedrock` until v0.28.0. It is `devos-claude`
everywhere you read or type it now: setup links `~/.local/bin/devos-claude`, the browser terminal has it, and every
page, message and document names it. `claude-bedrock` still works, so scripts, aliases and habits keep running:

- **The old command:** `bin/claude-bedrock` (and `/usr/local/bin/claude-bedrock` in the browser terminal) is a shim. It
  runs the `devos-claude` beside it with the same arguments, gives back its exit code and prints nothing of its own.
  Setup links `~/.local/bin/claude-bedrock` to it next to the `devos-claude` link. An update from v0.27.x, where
  `~/.local/bin/claude-bedrock` already points into the checkout, turns that file into the shim and adds the
  `devos-claude` link. Uninstall removes both links, and only links to its own checkout.

The names below keep the old name on every install, new ones too: renaming them would lose your data or settings.

- **Its Claude Code folder:** `~/.claude-bedrock` (`CLAUDE_BEDROCK_CONFIG_DIR` names another): your sign-in, settings,
  plugins and session history. A new folder would start empty, and `devos-claude --resume` would not find your
  sessions. The marker files inside keep their names too (`.claude-bedrock-run.*`).
- **Your settings:** every `CLAUDE_BEDROCK_*` variable (`CLAUDE_BEDROCK_MODEL`, `CLAUDE_BEDROCK_QUIET`,
  `CLAUDE_BEDROCK_USE_MY_CONFIG`, `CLAUDE_BEDROCK_OPUS_MODEL` in `.env`, …): your shell, your scripts and `.env` set them.
- **LiteLLM's tags:** each request is tagged `claude-bedrock` (the Code page's `claude-bedrock,code`, the browser
  terminal's `claude-bedrock,terminal`). The spend already logged carries them, and LiteLLM's Logs filter by them. Its
  keys keep their names too (`claude-code`, `claude-code-terminal`); none was named after the command.
- **The tool's id in *Bring your sessions* and *Bring your setup*:** `claude-bedrock` in what you allowed
  (`folder:claude-bedrock:always`, kept on your computer), in the requests between the portal, the update helper and
  the Code page (`setup-claude-bedrock`), in the folders it suggests, and in the sandbox's copies. A new id would forget
  what you allowed. The pages say devos-claude (badge DC), and `./stack sessions … --tool devos-claude` is the same as
  `--tool claude-bedrock`.

Renamed with it, after a check that nothing installed depends on them: the wrapper's file (`bin/devos-claude`, the
browser terminal's `/usr/local/bin/devos-claude`), its help and messages, the temporary file it makes when the config
folder cannot take one, the README's headings, and the e2e checks' names.

## The allowlist of claude-bedrock

As for the product's old name, `tests/brand_check.py` fails on any `claude-bedrock` (or `claude_bedrock`, `ClaudeBedrock`,
`CLAUDE_BEDROCK`, in any case) outside the tests and the CHANGELOG's entries before v0.28.0, unless a pattern below
matches it in a file the row names, or `tests/fixtures/brand-allow.txt` names that file and that text.

| Name | Pattern | Files | Why it stays |
|---|---|---|---|
| The shim | `claude-bedrock` | bin/claude-bedrock, terminal/bin/claude-bedrock | the old command, for scripts and habits |
| The shim's file and links | `(?:\.local/bin\|/usr/local/bin\|STACK_DIR/bin\|\bbin)/claude-bedrock\b` | lib/commands.sh, terminal/Dockerfile, README.md, docs/*.md, CHANGELOG.md | setup, update and uninstall look for them |
| The old name, said as such | `(?i:formerly) \x60?claude-bedrock\b\|\bclaude-bedrock\x60?,? \(?(?:its\|devos-claude's) (?:old name\|name before v0\.28\.0)` | * | so people can find it |
| Its Claude Code folder | `\.claude-bedrock\b` | * | your sign-in and session history |
| Environment and `.env` names | `\bCLAUDE_BEDROCK_` | * | your shell, scripts and `.env` set them |
| LiteLLM's tags | `x-litellm-tags: claude-bedrock(?:,(?:code\|terminal))?\b` | * | the spend logged under them |
| The tool's id in code | `(?<=[\|(:'"\[{,=\s])claude-bedrock(?=[\|)'":=,;\]}\\]\| [\|]\| ;;)\|\bsetup-claude-bedrock\b\|\bclaude claude-bedrock\b\|\bclaudeBedrock\b` | lib/sessions.sh, lib/sessions_config.sh, lib/settings_helper.sh, portal/portal/settings.py, portal/portal/static/settings.js, code/server/*.mjs, code/web/src/*.ts, code/web/src/*.tsx, code/web/dev/mock-server.mjs | what you allowed, and the requests that carry it |
| The tool's id, explained | `internal names?[^\n]{0,20}?claude-bedrock\|claude-bedrock[^\n]{0,30}?internal name` | lib/sessions.sh, lib/sessions_config.sh, lib/settings_helper.sh, portal/portal/settings.py, code/server/*.mjs, code/web/src/*.ts, code/web/src/*.tsx | comments saying which tool it is |
