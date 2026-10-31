# Internal names

DevOS ADE was called bedrock-now until v0.45.0 (and before v0.25.0 the repository, the folder and the installed app
were too). Since v0.45.0 every name you read, and every name the stack uses (the Docker Compose project and its
volumes, images and networks, the hosts, the `.env` settings, the launchd labels, the signing salts, the installed
app's id and link scheme), is `devos-ade`. An existing install is moved over by `./stack update` (see
[upgrading to 0.45](upgrade-to-0.45.md)); the old address forwards to the new one for one release.

The spellings below are the only ones left in the tree. Each is either history, a compatibility path for installs
made before the rename, or an identifier that data on disk or in someone else's system depends on.

## What keeps the old spelling

- **History:** `CHANGELOG.md` (what each release was called then), and git history.
- **The migration** (`lib/migrate.sh`, `tests/test_migrate.sh`, `tests/e2e/upgrade.sh`, `caddy/legacy-on.caddy`,
  `docs/upgrade-to-0.45.md`): they move an install named `bedrock-now` to `devos-ade`, and forward the old address.
- **One release of the old environment names:** `env_fallback_old_names` (`lib/common.sh`, called first by `./stack`)
  turns `BEDROCK_NOW_X` into `DEVOS_ADE_X` when that is unset. An update started by an older `./stack` hands its state
  to the new code that way. Removed in the next minor release.
- **The old repository name:** `JongoDB-Labs/bedrock-now` is accepted by the update check (`portal/portal/updates.py`
  reads `LEGACY_REPO`) and by `lib/repo_rename.sh`, because GitHub redirects it, and an install from before the
  repository was renamed still has it as its `origin`. The constants `PRODUCT_LEGACY_NAME` / `PRODUCT_LEGACY_REPO`
  (`lib/brand.sh`, `portal/portal/brand.py`, `install.sh`) hold it.
- **Installs and apps from before v0.25.0:** the installer finds an install in `~/bedrock-now` and leaves it
  (`install.sh`); `./stack open` finds a browser app installed under the name `bedrock-now`; `./stack uninstall` takes
  that name as its confirmation.
- **The workspace folder:** an install that already has `~/bedrock-now-workspace` (or
  `~/bedrock-now-<project>-workspace`) keeps using it. Your files are in it; a new install gets
  `~/devos-ade-workspace`.
- **The update helper's shim:** `bin/bedrock-now-helper` is a one-release shim: the launchd plists of existing
  installs point at it.
- **Stored ids, kept for v0.45.0 (a follow-up is planned to migrate them):**
  - the Open WebUI model records' `meta.bedrock_now` and `meta.bedrock_now_hidden` (which models the stack added or
    hid), stored in the Open WebUI database;
  - LiteLLM's admin user id `bedrock-now-admin` and the id prefix `bedrock-now-budget` of the budget banners in Open
    WebUI's settings;
  - the import source `'bedrock-now'` stored with a copied devos-claude session, in the Code page's records.
- **A byte-exact fixture:** `tests/fixtures/legacy-icons/openai.svg` is a generic badge older installs stored in Open
  WebUI; the stack recognises it by its hash, so its text cannot change.

Kept for a different reason, and not the product's name: the abbreviation `bn` where it is an identifier (`BN_*`,
`bn-*` binaries and services, `bn-dev`, `bne2e-*`, `bn-csp-nonce`, `X-Bn-*`, `bn.*` in localStorage, `window.bn*`),
`claude-bedrock`, `~/.claude-bedrock` and `devos-claude` (they name Claude on AWS Bedrock), and the DevOS heavy lock
(`~/.local/state/devos-heavy`, `heavylock.py`, `ADE_UNDER_HEAVYLOCK`).

## The allowlist

`tests/brand_check.py` (run by `tests/test_brand.sh`) reads every file git tracks (the tests too) and fails on any
`bedrock-now` (or `bedrock now`, `bedrock_now`, `bedrocknow`, `BEDROCK_NOW`, in any case) unless a pattern below
matches it in a file the row names, or `tests/fixtures/brand-allow.txt` names that file and that text, with why it
stays. `CHANGELOG.md` is history and is not read for it. Each pattern is a Python regular expression, and the old name
must lie inside what it matches; *Files* are globs (`*`: any file). A pattern that no longer matches anything fails the
check too, unless none of its files exist (the migration's, before they are merged).

| Name | Pattern | Files | Why it stays |
|---|---|---|---|
| The migration | `(?i:.*bedrock[-_ ]?now.*)` | lib/migrate.sh, tests/test_migrate.sh, caddy/legacy-on.caddy, caddy/legacy-off.caddy, tests/e2e/upgrade.sh, docs/upgrade-to-0.45.md | it moves an install of the old name |
| The update helper's old path in the e2e harness | `.*bedrock-now-helper.*` | tests/e2e/lib.sh | the upgrade e2e starts from releases before 0.45, whose helper has that name (and after the update, the shim of that name) |
| The old address check | `(?:\*\.)?bedrock-now(?:-preview)?\.localhost` | lib/common.sh | legacy_hosts_mode: Caddy forwards the old address only while the stack does not serve it itself |
| The old API header value | `request\.headers\.get\("x-requested-with"\) != "bedrock-now"` | portal/portal/app.py | one release: pages and scripts from before the move still send it |
| The old API header value, tested | `"X-Requested-With": "bedrock-now"` | portal/tests/test_keycheck.py | the test that the old value is still accepted for one release |
| The old environment names | `\bBEDROCK_NOW\w*` | lib/common.sh, stack, tests/test_common.sh | the one-release fallback |
| The legacy constants | `(?:PRODUCT_)?LEGACY_(?:NAME\|REPO)(?:=\| = )"[^"]*bedrock-now"` | lib/brand.sh, portal/portal/brand.py, install.sh | the old name and repository, read by the update check, the installer, `./stack open` and uninstall |
| The old repository | `JongoDB-Labs/bedrock-now[\w.\/-]*` | install.sh, portal/tests/test_updates.py, tests/test_update_git.sh, tests/test_install.sh | GitHub redirects it; installs from before the rename have it as `origin` |
| An install in the old folder | `(?:~\|\$HOME\|\$TMP/h)/bedrock-now\b` | install.sh, tests/test_install.sh | the installer finds and keeps it |
| An app or install named for the old name | `bedrock-now` | tests/test_open.sh, tests/test_lifecycle.sh | `./stack open` finds the app, uninstall takes the name |
| The installed app's old name | `named \x60bedrock-now\x60` | README.md | the browser keeps an installed app's name until you accept the new one |
| The workspace folder | `bedrock-now[\w<>%${}:-]*?-workspace` | * | an install that has it keeps it |
| LiteLLM's admin user and Open WebUI's budget banners | `bedrock-now-(?:admin\|budget)\b` | lib/owui.sh, tests/test_owui.sh | their ids are stored in LiteLLM's and Open WebUI's databases |
| Open WebUI metadata keys | `(?<![\w])bedrock_now(?:_hidden)?(?![\w])` | lib/openrouter.sh, lib/owui.sh, tests/test_explabs.sh, tests/test_openrouter.sh, tests/test_settings.sh | stored with your models |
| The stored import source | `'bedrock-now'` | code/server/harness/claude.mjs, code/server/import-plan.mjs, code/server/import-sessions.mjs, code/test/harness-claude.test.mjs, code/web/dev/mock-server.mjs, code/web/src/api.ts, code/web/src/types.ts | stored with a copied session |
| The old Tailscale names, as documented | `bedrock-now(?:-node\|-chat)?\b\|tag:bedrock-now` | docs/remote.md | installs from before v0.45.0 keep them: the page says how to switch |
| The settings request's old header | `bedrock-now-settings 1` | lib/settings_helper.sh, tests/test_settings.sh | one release: a settings change queued by the portal just before the update to v0.45.0 still runs |
| The byte-exact fixture | `bedrock-now-icon` | tests/fixtures/legacy-icons/openai.svg | recognised by its hash |

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
| The migration's links | `claude-bedrock` | lib/migrate.sh | moving an install moves the old command's link with it (`~/.local/bin/claude-bedrock`) |
| The old name, said as such | `(?i:formerly) \x60?claude-bedrock\b\|\bclaude-bedrock\x60?,? \(?(?:its\|devos-claude's) (?:old name\|name before v0\.28\.0)` | * | so people can find it |
| Its Claude Code folder | `\.claude-bedrock\b` | * | your sign-in and session history |
| Environment and `.env` names | `\bCLAUDE_BEDROCK_` | * | your shell, scripts and `.env` set them |
| LiteLLM's tags | `x-litellm-tags: claude-bedrock(?:,(?:code\|terminal))?\b` | * | the spend logged under them |
| The tool's id in code | `(?<=[\|(:'"\[{,=\s])claude-bedrock(?=[\|)'":=,;\]}\\]\| [\|]\| ;;)\|\bsetup-claude-bedrock\b\|\bclaude claude-bedrock\b\|\bclaudeBedrock\b` | lib/sessions.sh, lib/sessions_config.sh, lib/settings_helper.sh, portal/portal/settings.py, portal/portal/static/settings.js, code/server/*.mjs, code/web/src/*.ts, code/web/src/*.tsx, code/web/dev/mock-server.mjs | what you allowed, and the requests that carry it |
| The tool's id, explained | `internal names?[^\n]{0,20}?claude-bedrock\|claude-bedrock[^\n]{0,30}?internal name` | lib/sessions.sh, lib/sessions_config.sh, lib/settings_helper.sh, portal/portal/settings.py, code/server/*.mjs, code/web/src/*.ts, code/web/src/*.tsx | comments saying which tool it is |
