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
| The installed app's link scheme | `web\+bedrocknow\w*` | portal/portal/webapp.py, README.md, docs/*.md | *Open in the app* |
| The pages' `X-Requested-With` | `[Xx]-[Rr]equested-[Ww]ith[^\n]{0,24}?bedrock-now` | * | the portal checks it |
| The old name, said as such | `(?i:formerly) bedrock-now` | * | so people can find it |
