# Changelog

All notable changes to DevOS ADE (formerly bedrock-now) are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.35.0] - 2026-10-28

### Added

- **Right-click menus on items throughout the ADE (JON-821).** Every item with actions has one menu, opened by a
  right-click, a long press, Shift+F10 (or the context-menu key) on the focused item, or its **⋯** button (on hover and
  focus; always shown on touch). The same list serves all four, and the menu stays inside the window. On Home, a **Recent**
  row: a Code session offers Open, Open in a new tab, Rename, Fork, Add to project, Open its folder in a terminal,
  Copy link, Archive and Delete; a Chat conversation offers Open, Open in a new tab, Copy link, Rename, Archive and
  Delete. The Code page's session list, projects, explorer, changes, review, ports and model picker have theirs;
  Browse models rows (Try it, Add or Remove, Copy id), Settings rows (Copy name, key, value, link), Activity items and
  the navigation tabs too. Text fields, the editor and the terminal keep the browser's menu. Delete asks first and says
  exactly what goes. New behind the menus: **Archive** and **Delete** for a Code session (`POST /api/sessions/ID/archive`,
  `/delete`: the transcript is deleted from the sandbox, refused while the session is running), a terminal in a session's
  or a path's folder (`/folder-terminal`, `/api/fs/terminal`), and Chat's rename, archive and delete through the portal
  (`POST /api/chats/ID/rename|archive|delete`, as the owner, rate-limited, logged). `docs/design.md` lists the menu of every
  item, page by page.

- **Local models and model servers are on Browse models, and in the Code picker (JON-816).** Browse models has a **Run
  models yourself** card with two ways in: **Download from Hugging Face** and **Add a model server (localhost by default)**.
  Both open the same form as Settings, in a panel on that page. The models you downloaded and each saved server's models
  are listed next to the providers' (filters *On this computer* and *Model servers*), with the same Add / Remove. The Code
  page's **More models…** gains **Add a local model or a model server…**. **Check server** of this computer (localhost —
  the default) no longer asks for the portal password: it only reads, behind the portal session, and the update helper
  refuses any address but this computer's, judged on the address it pins. Checking another computer on your network,
  saving, removing, keys and downloads still ask for it.
  A server's API key is stored tied to its address and is sent only there, however the address is changed; a download
  is pinned to the commit that was checked, and its `config.json` is checked again on disk before the model is served;
  trusting a self-signed certificate on a public address is warned about; and requests to the model servers are
  rate-limited.

- **Local models: download a model from Hugging Face and use it in Code, Chat and the terminal (JON-816).** Settings ›
  Models & providers has a **Local models** section (collapsed until you have one): search Hugging Face for GGUF models,
  see each quantization's size, license and whether it fits this computer's memory, and **Download** it with a progress
  bar. A downloaded model is registered with the model gateway live, in seconds, and shows up in the Code page's picker,
  Chat and the terminal marked **Local**, free, at $0 Actual (never a dollar of spend). **Remove** deletes it and shows
  the disk used. Tool use is said honestly: a model without tool support, or under 3B parameters, is chat only; under 7B
  is flagged as weak at Claude Code's tools; none is called working until it is checked, and every answer is capped at
  4096 tokens so a model that loops stops.
  - On **Apple silicon it runs natively with MLX** (`mlx_lm.server`, on the Mac's GPU through Metal; a container cannot
    reach Metal): DevOS ADE installs a pinned, hash-locked `mlx-lm` into its own `uv` environment under the stack's
    state folder (nothing system-wide; needs `uv`), runs the server as a launchd user agent on 127.0.0.1 only, and
    downloads models from Hugging Face's MLX catalog (mlx-community has the pre-quantized ones) into the stack's own
    Hugging Face folder, so disk use and Remove are exact. `mlx_lm.server` holds one model at a time and loads the one a
    request names, so the first answer after switching models waits for the load (the model gateway allows 15 minutes).
    Never `--trust-remote-code`: a repo that ships Python files, or whose `config.json` has `model_file` or `auto_map`, is
    refused with the reason (CVE-2026-5843). `./stack local-models uninstall [--models]` (and `./stack uninstall`)
    remove the agent, the environment and, on request, the models.
  - Everywhere else it runs on **Docker Model Runner** (Docker Desktop 4.71 or newer, or `docker-model-plugin` on Linux;
    GGUF models, CUDA when present) first and a host **Ollama**
    second. With neither running the section says how to switch one on, and `./stack local-models enable` does it
    after asking (it changes a Docker Desktop setting, so it never happens silently). Also `./stack local-models
    status|pull ORG/REPO QUANT|rm ORG/REPO QUANT`.
  - **Model servers: point the gateway at any OpenAI-compatible server by address** (vLLM, Ollama, LM Studio,
    llama-server, TGI, another Mac's `mlx_lm.server` …); this computer is the default. `./stack local-models server add
    NAME http://host:port` (with or without `/v1`), `server key NAME` (the key is read from the terminal, never an
    argument or URL), `server enable NAME ID|*`, `server rm NAME` (or the form in Settings › Models & providers › Local models: Check server, tick its models, Add; per-server model boxes, Edit key, Remove; all with the portal password through the update helper): the
    server is probed at `/v1/models`, what it serves is listed with its context length when it says one, the models you
    enable are registered live (seconds, no restart) as `ms/<name>/<id>`, marked Local, free, tool use unknown, capped at
    4096 tokens. `localhost`, `127.0.0.1` and `::1` mean this computer and are reached from the gateway as
    `host.docker.internal` (the Settings page says so). Probe failures say what failed: DNS, refused, timeout, TLS
    certificate (trust one self-signed server with `;trust`, never globally), 401, no `/v1/models`. Cloud-metadata and link-local
    targets (169.254.0.0/16, fe80::/10, 100.100.100.200, fd00:ec2::254, metadata names, IPv4 wrapped in IPv6) and
    non-standard numeric addresses (octal, hex, short) are always refused, the checked address is the one used, and a
    server is registered only after its address passed the check (docs/security.md). Plain http to a
    public address is allowed with a warning that prompts travel unencrypted. A server that is down is probed about
    once a minute and its models say "UNAVAILABLE" with the reason; removing a server unregisters its models and key.
  - Downloads come from Hugging Face only. A gated model needs an optional **Hugging Face token** (stored like every
    other secret, passed to the runtime's environment, never in a URL, argument or log). The runner is unauthenticated
    on this computer: keep it, and Ollama, off the network, and keep both current (llama.cpp has had GGUF-parsing
    fixes).
  - The model gateway gets `host.docker.internal` (a host-gateway entry) to reach a host Ollama or Docker Engine's
    runner. The update helper gains two fixed-field actions (`local-pull`, `local-remove`); the portal works out a
    download's size, license and tool support itself from Hugging Face, never from the page. The embedder stays
    Bedrock-only.

### Changed

- **Home and Settings no longer scroll for ever: their content is laid out as sized widgets that use the screen (JON-812).**
  On a wide window Home now puts **Get started** and **Continue** side by side at the top, the update card under them in two
  columns (what's new beside what happens), and then **Bedrock spend**, the services and models, the sign-ins and
  **Claude Code in your terminal** next to each other in three columns instead of one tall stack: a first visit that took
  about 2,400 px of scrolling now takes about 1,600 px, and a returning one about 1,600 instead of 1,900. Long lists keep
  to a size of their own and scroll inside their card (Continue, **What's new**, the models table) and nothing is cut
  off: everything stays one click away. The same goes for the rest:
  - **Settings › Models & providers** shows **Keys**, **Subscriptions**, **Local models** and **Search** one at a time (they were one
    4,700 px page); a search or a link still finds a setting in any of them.
  - Settings sections use two or three columns when the window is wide, and **Advanced** and **About this install** show
    their first ten values and fold the rest under **Show the rest** (a search opens it).
  - **Browse models** is a grid of cards, as many columns as fit.
  - On a phone Home drops what is repeated elsewhere: Recent shows four, a finished Get started step is one line, and
    the models table scrolls inside its card.
  - **Code page:** its page already fitted the window (the explorer, Projects, Git, Review, Ports and the chat each
    scroll inside their own pane); the empty chat now uses a wide window: **Pick up where you left off** and
    **Projects** are two cards of their own height beside each other under the first prompts, shown from a 720 px wide
    chat pane and a 760 px tall window. A phone and a narrow pane look as before.
  - The layout follows the page's own width, so opening the walkthrough (its wider sidebar) gives Home fewer columns
    instead of squeezing three. No page scrolls sideways at any width.

## [0.34.0] - 2026-10-28

### Added

- **Browse models: search every provider and add the ones you want (JON-520).** Settings › Models & providers now has
  **Browse models** on each provider's card (and **More models…** in the Code page's model picker): one page that
  searches what Bedrock, OpenRouter and Experiential Labs offer with your keys — by name, id or vendor — with each
  model's price per million tokens, context window, tool use, image input and how it works with Claude Code, and
  filters for provider, free or paid, output price, context size, tool use, image input and "works with Claude Code".
  Each row shows whether it is in your pickers now, with **Add** and **Remove**. Adding or removing goes through the
  same path as every other setting (your portal password, the update helper, `./stack config apply`) and applies in
  seconds — the model gateway takes the new list as it runs, without a restart — and the model then appears everywhere models show — Chat, the Code page, the terminal's Open and
  `devos-claude --models` — with its price and compatibility note. **Experiential Labs** models can now be several
  (`EXPLABS_MODELS` as a list); **OpenRouter** is edited as a list as well as `free`/`paid`/`all`; and **Bedrock** can
  serve models beyond the built-in catalog (a new `BEDROCK_MODELS`, for a foundation model or inference profile your
  AWS key can use that the catalog does not carry). **Try it** makes one short, capped call to a model and shows the
  cost first — never on an expensive model (Opus included) without you confirming.
  - The lists are read on the computer, never in your browser and never with a key in the portal: Bedrock's with
    `ListFoundationModels`/`ListInferenceProfiles` through a one-off model-gateway container (read-only, free, the
    stack's AWS sign-in), Experiential Labs' with `GET /v1/models` using the key the same way the gateway is always
    called, and OpenRouter's from its public list. Each is cached (about an hour) and refreshed in the background.
    The update helper reads them once by itself on a new or updated stack, so the first open finds them there; a list
    still being read says so (*reading it on this computer…*) and the page shows it by itself when it arrives,
    keeping what you are typing in the search. Without the update helper, Bedrock's built-in models show and the list
    says it is *read on this computer once the update helper runs*.
  - **Claude is listed even when your AWS key may not list inference profiles.** Current Claude models on Bedrock
    are served only through cross-region inference profiles. A key without `bedrock:ListInferenceProfiles` now gets
    them by their usual profile id (`us.…`, as the built-in catalog calls them), and the page says so with the
    permission that gives the exact list. The IAM guidance (README, `docs/cloud-vm.md`) adds it as an optional,
    read-only permission next to `bedrock:ListFoundationModels`.
  - **Try it** says what the call was booked at — *cost $0* for a free or local model (LiteLLM leaves its cost header
    out at $0; the figure it worked out is read instead).
  - The Code page's not-granted and ended-promotion messages (JON-521) now carry a direct action: **Pick another
    model**, and **Send again (charged)** where sending again is the way on.

### Fixed

- **Settings no longer says a model-list change restarts the model gateway.** The notes for *OpenRouter models* and
  *Experiential Labs models* still said the gateway restarts (about 30 s); since 0.32.3 such a change applies in seconds,
  as their *No restart* badge says.

## [0.33.1] - 2026-10-28

### Security

- **`bin/bump-core-services` (the maintainer's tool that moves the core-service pins) sends credentials only where they
  belong.** `GITHUB_TOKEN` went to any address that merely contained `api.github.com` (a registry's sign-in address,
  Docker Hub's next-page link); it now goes only to `https://api.github.com`. A registry's sign-in challenge could name
  any address to fetch a token from; it must now be https on the registry itself or Docker Hub's token service, and
  Docker Hub's next-page link must stay on Docker Hub. Neither token is carried across a redirect. Nothing in a running
  DevOS ADE used this path; the tool runs on a maintainer's machine.
- **The 3-day cooldown now covers the digest, not only the release.** The tool judged the cooldown on the release date
  but read the image digest afterwards, so a tag pushed again since would have been pinned. It now reads each new
  image's build time: built inside the cooldown, the move waits; built more than a day after its release, it is refused
  for a maintainer to look upstream. [docs/releasing.md](docs/releasing.md).

## [0.33.0] - 2026-10-28

### Changed

- **Updating DevOS ADE now brings every core service to its newest tested release (JON-815).** The pins had lagged
  upstream because nobody bumped them; each release now does, and *Update now* (or `./stack update`) moves them:
  LiteLLM 1.105.0 → 1.106.3, Open WebUI 0.12.0 → 0.12.4 (a security release whose advisory is not public yet: `security override: advisory pending`, recorded in `catalog/core-services-overrides.tsv`), RustFS 1.0.1 → 1.0.3, the AWS CLI
  2.37.12 → 2.38.5, SearXNG 2026.10.11 → 2026.10.24, the Node base image 24.21.0 → 24.22.1, Codex CLI 0.163.0 →
  0.164.0, gh 2.102.0 → 2.103.2, newer Starlette and certifi in the portal, shared MCP and speech-to-text images
  (`--require-hashes` locks re-made). Every image is now pinned by digest.
  - **`bin/bump-core-services` (a maintainer's tool; every release runs it).** For each pin it takes the newest stable
    upstream release at least 3 days old, so a release upstream pulls within days is never pinned; a release whose
    notes say "security fix" is only flagged for review: the wait is skipped only when a maintainer passes
    `--allow-security <GHSA/CVE id>` and the GitHub Advisory Database confirms it for that repository. It resolves the digest, rewrites `compose.yaml`, the Dockerfiles,
    the sandbox tools' versions and checksums and the pip hash locks, and prints an old → new table with release-note
    links (`--check` only reports). [docs/releasing.md](docs/releasing.md).
  - **The update card's *What's new* lists the service moves** (*Core services: LiteLLM 1.105.0 → 1.106.3 · …*), and so
    does the end of `./stack update`.
  - **`./stack versions`, one line in `./stack status` and Settings → Updates & backups → *Core services*** show each
    service's running version, the version this release pins and the newest upstream when it was made, saying plainly
    *Update now brings it to X* or *newer upstream exists; the next DevOS ADE release will bring it*.
  - **An update checks what it started.** After setup, every recreated service must run the image this release pins
    (digest match; Open WebUI's local build must be on the pinned base; the portal, shared MCP and speech-to-text
    builds must be the ones just built, which a rebuild from Docker's cache still is although its image id is new). A
    mismatch fails the update, and `./stack rollback` goes back.
  - **LiteLLM's own *The latest version is…* banner in Admin is gone** (LiteLLM has no setting for it; Caddy answers
    its one lookup route): LiteLLM only moves with a DevOS ADE release, so the banner could only confuse.
  - **What the new versions change for you.** LiteLLM 1.106.3 starts its Admin on a new *Home* dashboard; the portal
    still opens Admin on *Virtual Keys*, as before (Home is the first item in LiteLLM's menu). Open WebUI 0.12.4
    shows no *Call* button while speech-to-text is your browser's, where it used to show it and then refuse.

## [0.32.3] - 2026-10-28

### Changed

- **Settings changes apply in seconds (JON-533).** A change through the portal's Settings — or `./stack config set` —
  is now timed end to end, and only what the change needs is done on the critical path:
  - **A model-list change — the Experiential Labs set, the OpenRouter set, the Code page's default model or list — no
    longer restarts the model gateway.** LiteLLM takes the new model list as it runs, through its own model admin API
    (`/model/new`, `/config/update`), so these changes finish in about 5 seconds instead of ~25–50 s. `litellm/config.yaml`
    stays the record (a restart reads it as before); the live change is made to match it exactly — each model's params,
    its hook's `model_info`, prices and the Code page's metadata. The admin API uses the master key, which never leaves
    the host and the LiteLLM container. Settings marks these settings *No restart*.
  - **The providers' model lists come from the cache, never a network read before the change.** A new Experiential Labs
    key reuses the ids its own check just read; the gateway's catalog (which took up to ~50 s to send) and OpenRouter's
    list are read afterwards, in the background, and handed to LiteLLM live when they bring changes. A model chosen
    before its details are read runs fail-safe until then, as on `./stack up`.
  - **Open WebUI's names, tags, cost line and budget banner, and the web-search check, run after *Done*,** in a
    background follow-up (`./stack config followup`) the next change supersedes — they no longer hold up the change.
  - **Only the services whose configuration changed restart, side by side in one Compose call,** and *Verify* is a
    quick health check of what changed (a 1-token Bedrock call only after a new AWS key), not the full smoke test.
  - **Each step is named and timed on the Settings progress card** (Check · Save · Restart · Verify · Done, with the
    time each took and the step running now), and the helper's settings log carries a timestamp per line.
  - The portal picks up a change within a quarter-second and polls for its result several times a second while it runs.
  - Safety is unchanged: a failed change still rolls back to the previous `.env` and config and says what failed; the
    password step and the remote-access policies are the same.

## [0.32.2] - 2026-10-27

### Changed

- **Updates account for every second (JON-519).** Home's update card lists every step of the update with how long it
  took, from the backup to what's new: the new code, each image's download, each image's build (from Docker's cache,
  or which step was built again), your subscriptions' tools (installed or kept), each group of services, LiteLLM's and
  Chat's keys, the Open WebUI syncs, the smoke test, the clean-up of old images. No stretch is left as "Restarting the
  services". The helper's log of the job (`.state/helper/last-update.log`) has the local time of every line
  (`20:02:40 ==> Backup ready (9s)`), and `./stack setup` and `./stack update` in a terminal print each step's time. The
  first update into this version is still logged by the helper of the version before it: its card starts at setup
  and its log has no times; the updates after it show the whole job.
- **Updates spend less time waiting.** The images an update downloads come all at once, in the background, while
  setup builds; an image pinned by its digest that is already here is not asked for again. The terminal's, its egress
  proxy's and the Code page's images build in the background while LiteLLM, Open WebUI and the portal come up (the
  Code page keeps running on its current sandbox until then). Asking your subscriptions' tools what they say (for
  Settings) no longer holds up setup: each tool is asked side by side, in the background.
- **Your subscriptions' tools are installed again only when their pins change.** Each tool, once installed and
  checked, is kept in the terminal image's build cache under the hash of what it is (its version and checksums, or
  its lockfile, the platform and Node). An edit of `terminal/tools/install.sh` or of npm's flags, such as v0.31.3's
  retries, now costs a copy instead of downloading all five again; a new pin installs that tool alone, and the tools
  install side by side. The first build after this update installs them once more (the stage's own line changed).

## [0.32.1] - 2026-10-27

### Fixed

- **An Experiential Labs free alias your key does not list is no longer enabled (JON-521).** A model chosen as
  `<slug>:free` stayed in every picker whenever the key's list named `<slug>`, though the gateway refuses an alias the
  list does not name (403 "The requested model alias is not granted to this identity"): the Code page then said *The
  model's provider refused the key* with an unrelated line about Git sign-in codes, and Claude Code in the terminal
  asked for `/login`. Now a chosen id is enabled only when the key's list names it exactly, `:free` included; anything
  else is left out — never swapped for the paid alias — and setup, `./stack status` and `./stack models`, Home's model
  list and Settings › Models & providers › Experiential Labs say so, naming the alias the list has instead (*your key
  lists 'glm-5.3-uncensored' (billed on your credits)*). If the gateway still refuses a model this way, LiteLLM's hook
  makes it a plain model error (a 400: Claude Code shows it as one, with no `/login`), and the Code page says *Your
  Experiential Labs key isn't allowed to use this model* with **Pick another model**. A provider's own words under a
  Code page error no longer carry the line about Git sign-in codes. A free alias your key does list keeps its model's
  details at $0, even when the list does not name the model itself.
- **When an Experiential Labs model's free promotion ends, you decide whether to pay (JON-521).** The gateway's
  one-time notice (402 *The free promotion for GLM-5.3 Uncensored has ended … requests will be charged to your credit
  balance. Retry to continue.*) — which a retry accepts — is never sent again by anything in between: LiteLLM's hook
  makes it a plain model error (a 400, which neither LiteLLM nor Claude Code tries again), and the Code page, the
  terminal and `devos-claude` say *Experiential Labs: the free promotion for glm-5.3-uncensored has ended. From now on
  its requests are charged to your Experiential Labs credits. Send your message again to continue, or pick another
  model.*, the Code page with **Pick another model**. The model is priced from the gateway's details everywhere (the
  pickers, Home, Chat's cost line), so what it costs from then on is Actual spend. The Code page names the model in
  these messages by its own name for it.

## [0.32.0] - 2026-10-27

### Added

- **Code is a tab of the phone's bar: Home · Chat · Code · More.** It frames the Code page like Chat (its own phone
  layout: the chat first, files, the editor, Git and the rest as sheets), unlocked once with the portal password,
  instead of opening from More in a new browser tab — which, from an installed iPhone app, meant Safari and another
  sign-in. While the Code page is off (or off over remote access) the tab shows *off* and its page says how to turn it
  on. Home's Continue row, Activity's *Answer*, search and the walkthrough open sessions and files there too, in place
  once the page runs (no reload, no unlock again, no unsaved edit lost).
- **A session that needs you, on a phone:** the Code tab shows a badge (the page loads in the background in a browser
  that has used it, on a phone too), and the other tabs a banner — *Claude needs you in Code*, the session's title,
  **Answer** (that session, its card in view) and ✕ (read; it stays in Activity). The banner is built from Activity's
  own items, and a browser notification of a waiting session now opens that session too (`#code/<session id>`, also
  from the installed app's service worker): the path a push notification will take once DevOS Mobile and the
  Companion bring one. No Web Push yet.
- **Home leads with Continue: what to pick up again, one click away.** The Code sessions that need you come first
  (*Needs you*, **Answer**), then the recent Code sessions and Chat's newest conversations (**Resume**, **Open**), with
  **New session** (in the project the Code page shows: *New session in ui-sweep*) and **New chat**. On a phone too,
  where no Code tab is framed: the Code page, open in any browser that unlocked it, tells the portal what Home may show
  of its sessions (`POST /.bn/recent` on the code host, after its check: ids, states, times and short titles as text),
  which the portal keeps in memory only, per sign-in, and forgets at Sign out; Home says how old it is when the Code page
  is not open. Chat's conversations come from Open WebUI's own list, asked as the global search asks it. The portal
  still never reaches the code container (docs/security.md › The Code page). A Code page link with `?new=1` opens a new
  session's start, and `?project=` is kept through the unlock.
- **Get started: five steps for a first run, in place of the 37-step walkthrough opening by itself.** On Home, first:
  sign in, add a model provider (or confirm Bedrock's), open Code and run a first session, open Chat and ask something,
  set a budget — each ticked by what the portal sees (enabled chat models, a session the Code page reported, a chat in
  Open WebUI, a budget changed from its default, or **Keep these**). **Full walkthrough** opens the whole tour, which
  stays under the Walkthrough button; **Hide** puts the checklist away in this browser, and the walkthrough brings it
  back. A browser that used Home before keeps its Home as it was.

### Changed

- **Opening the Code page while a session waits for you shows that session, its card in view**: the one you looked at
  last if it waits, else the waiting one active most recently. On a phone no sheet covers the card (the Projects sheet
  used to open over it), and showing the Code tab again on a phone goes to the waiting session the same way.
- **The permission card on a phone:** **Allow once** and **Deny** are full-width buttons 48 px tall at the bottom of the
  card, always in view: what is asked (the command, the diff, why, the *Always* options, full width too) scrolls above
  them inside the card. Deny's message box no longer brings up the keyboard by itself: tap it to type, or tap **Deny** to
  send.
- **A phone's first sign-in opens Home** (it opened Chat), with *Get started* at its top (the walkthrough is under
  More); later visits remember the last tab, as before. What greets a first visit is one entry point,
  `window.bnWelcome.start()` (tour.js), which Home's *Get started* takes over.
- **The phone's More sheet is titled More** (it said *Desktop site*): Settings, Activity, Search and the walkthrough
  first, then Admin, Files and the Terminal under *In a new tab*, then Sign out.
- **The walkthrough on a phone:** its Back and Next stay in view at the bottom of the sheet, above the tab bar, instead
  of sliding under it while a long step scrolls.
- **Chat's Who answers on a phone** shows a visible *Who answers* label and the choice's name whole (*Open WebUI ▾*,
  not *Open WebUI — its owr*); a tap opens the system's picker with every choice in full.
- **Home's operations are compact, under Continue:** Services is one line (*All 6 services running*) that opens the
  list; Models is one line (*11 of 17 models enabled*) with the table, its notes and prices folded under it; the spend
  meters are named for where their spend comes from — *devos-claude (your terminal)* and *Code page & browser
  terminal* (they read *Claude Code* and *Terminal (browser)*). The Code card is gone: Continue has its sessions.
- **Settings speak the page's words.** Each setting's Details explains it in plain words (*On: …*, *30 by default*, the
  names the page uses) instead of `.env`'s (*true = …*, *blank = 30*, other keys' names), and a footer, *For the
  terminal*, holds its name in `.env` and the command that changes it. Badges say *Restarts the model gateway* (not
  *LiteLLM*), *the web server* (Caddy) and *the shared file server*; the page's header says *As of …*; *AWS & models*
  is now **Bedrock (AWS)**, apart from *Models & providers*, whose groups — Keys, Subscriptions, Search — are a bar of
  links at its top that stays there while it scrolls.
- **Settings on a phone: a section is a short list of cards.** Each card keeps its name, its state and value and its
  control; its summary, badges, notes, what a provider adds and the terminal command fold under its **Details** —
  Models & providers goes from about 8,100 px to 4,800 and Claude Code from 5,800 to 2,800 (folds closed), the
  remaining height being the subscriptions' Sign in buttons.
- **The Code page puts the chat first.** Until a file, a diff or a preview opens (and while the terminal is closed),
  the chat has the middle of the page instead of an empty editor beside a narrow chat; the keyboard shortcuts it listed
  are the status bar's **Keys**.

### Fixed

- **Tests:** the collapsed-sidebar check's phone step waits for the tab bar, as a phone's sign-in now lands on Home;
  the layout check's reviewed exceptions add a long session title in the Code page's top bar and phone header, until
  short session titles (JON-517).
- **A tap on Allow once timed out on a phone when you came back to a waiting session.** The Code page opened its
  Projects sheet over the session on purpose (to list who needed you), and the sheet took the tap meant for the card
  behind it. The page now opens the waiting session itself, with no sheet (see Changed); the sheet still groups the
  sessions that need you when you open it.

## [0.31.5] - 2026-10-27

### Changed

- **The model picker lists the models you can use first.** It opened on *Who answers* — six subscriptions, most not
  signed in, each with a long line — so on a phone the first model was at the bottom of the screen. The models come
  first now; *Who answers* follows them with Claude Code on Bedrock and the subscriptions that can start here, and the
  ones to sign in to are folded under one row, **Subscriptions (sign in to use)**, that opens them.

### Fixed

- **Tests: no test run spends on Opus.** The end-to-end throwaways start Code sessions on Claude Haiku, and a new
  final check, `spend/no-opus-spend`, fails a run in which a session key (the Code page, the browser terminal,
  devos-claude or Chat) spent on an Opus model (setup's one-token model probe is reported, not counted). A Code page
  check that leaves the shared session in a mode other than Default now fails.
- **A finished turn costs the same after a reload.** The Code page showed a turn's cost from LiteLLM's rows between its
  prompt and its end — but a reloaded page rebuilt its turns at the moment of the reload, so it counted only the last
  minute's rows: a first turn read $0.0049 live and $0.0007 after a reload, while the session's total stayed $0.0049
  (LiteLLM's spend, the true figure). The code container now stamps each event with its time, and a page that
  re-attaches (a reload, a second tab, a phone) rebuilds the turns at their own times.
- **A session that waits for you says so.** While a permission card, a question or a plan waited for an answer, the
  session's chip, a phone's title and the prompt box said *working*. They now say *waiting for you* (the amber dot of
  the card's lamp), the prompt box says Claude waits for your answer above, and the card takes the focus and is scrolled
  into view — also from an empty prompt box you just sent from (a key that lands on the card still answers nothing;
  text you are typing keeps the box's focus).
- **The Git panel finds the repository of the project's folder.** It said *not a git repository* for a folder that is
  none itself, even with a repository in it (a clone in the workspace, with a change waiting). It now shows the folder's
  own repository, else the one the folder is in (around it, up to the workspace), else the one directly inside it — the
  one you picked, else one the session changed files in, else the first; with several, the picker offers the others —
  and says which it shows. The picker names each choice short (a project by its name, a repository by its folder), so
  the side panel shows it whole, with the rest in its title. It looks for a `.git` entry (no git runs to find it), and every command still runs only in a
  repository's own top folder (docs/security.md › The Git panel).
- **The Git panel no longer errors over a folder that has just been removed.** Removing a project (or any folder the
  panel was reading) while its status, history, a file's changes or its remotes were on their way left a failed request
  and a console error on the page: a read of a folder that is gone was answered as a refusal. Such a read now answers
  *not a git repository*, the same as for any folder that is not one, so a trailing refresh of a folder that has just
  gone passes quietly.

## [0.31.4] - 2026-10-26

### Added

- **Tests: a layout sweep.** `tests/e2e/browser/layout_sweep.py` measures every page and state in the browser for what
  collides or is cut off: text over text, a control or a badge over a title, a title, label or button cut by an
  ellipsis or a box that hides it, a page that scrolls sideways, pointer targets under 24 × 24 px (WCAG 2.2, 2.5.8),
  and controls you can Tab to that no scrolling brings into view. Each finding is kept once, with every size, theme and
  state it was seen at and a cropped screenshot. Every end-to-end run has its fast run as `browser/layout-no-overlap`
  (12 widths from 320 to 1920 px, both themes, the main pages): it fails on a finding that
  `tests/e2e/browser/layout-allowlist.json` does not list with a reviewed reason. For releases,
  `tests/e2e/ui-sweep.sh --layout full` measures every 40 px from 320 to 1920 at 600 and 1000 px high, every Settings
  section and walkthrough step, the menus and info panels, and a Code page session against its mock backend.

### Fixed

- **Code page:** a message's Restore and Fork sit inside it wherever the conversation is narrower than 640 px (at
  560–640 px they were cut by the list's edge, focusable but out of reach); a model's details in the model picker
  show in full as a tooltip where the menu cuts them.
- **Tests:** the check of Home's Check for updates accepts the update card scrolled into view as far as a short page
  goes; the check of a session on another provider's model switches a Haiku session of its own, not one an earlier
  check may have left in Plan mode.
- **Tests:** the layout check's reviewed exceptions also cover the sign-in form's Show button, which sits inside the
  password field's reserved right padding by design, and a long Code session title cut in the Projects list (its full
  text in the tooltip) until sessions get short titles (JON-517).
- **Tests:** the layout check matches its reviewed exceptions: it compared a finding's signature without the check's
  name, so no exception ever matched.
- **Tests:** the Code page's browser check of Auto mode expects its reviewer to be Claude Haiku, as it has been since
  v0.28.1 (it still expected Sonnet 5.5 and failed).
- **Layout: nothing collides or is cut off between the sizes checked before** (390, 820 and 1440 px). The sweep found
  problems in v0.31.0 at sizes no check had tried; each was fixed where it starts:
  - **The Code page's top bar** kept its controls on the right at their size: squeezed, they ran over the model and
    effort pickers (1100–1160 px), shrank the menu button to 10 px and cut the Editor button off. As the bar narrows it
    now sheds words first (the session title, which the chat's head shows, then the brand's name and the meters'
    labels), so the project's name stays whole instead of "W…"; the cost pill's figure is centred in a touch screen's
    taller pill, no longer on its top edge.
  - **Short windows:** the icon rail and the collapsed sidebar no longer push Sign out and the walkthrough below the
    window at 600 px tall (their spacing tightens under 760 px; under 560 px the sidebar scrolls). A pending
    permission card no longer squeezes the conversation to a 13 px sliver: the card scrolls inside first. More's sheet
    scrolls instead of putting its title above the top of a phone.
  - **Cut-off words:** the Code page's side tabs show icons rather than "EXPLOR…"; the terminal panel keeps the word
    Terminal and its note no longer wraps over the chat; a phone's prompt box keeps its mode's name; a phone's menus
    wrap a model's description rather than losing its switching cost, and the model picker shows a model's compatibility
    note whole (its own rule to wrap was overridden); Who answers above Chat on a phone shows the whole choice; search
    results show a setting's whole name; a session title cut in a list shows in full on hover.
  - **Out of reach:** a user message's Restore and Fork sit under its text in a narrow conversation (they ran past its
    left edge).
  - **The command palette** wraps a command's name and what it does instead of ending them in "…" (a phone showed 7 %
    of some); **the empty editor's shortcut list** scrolls inside the editor instead of running over the terminal panel
    in a 600 px window.
  - **Targets of 24 px at least** (WCAG 2.5.8): Settings' Details, the other folds and links on Home (Open Code, the
    update line and a release's link, Credentials, the version on a phone), a tab's close, a message's Restore and Fork,
    a code block's Copy, a tool's file, Thought, the file tree's ⋯ (on a touch screen it no longer overlaps the next
    row's), New session, and the Code page's project line on a phone.
- **Accessibility and polish from the UX audit:** the Settings section list holds list items only; the model picker is
  a dialog named Model (it holds a search, which a menu may not), its choices in menus and a model's star a menu
  checkbox; an editor tab no longer holds its close
  button (Delete closes it from the keyboard); the Code page has a main landmark and a heading; a Markdown preview reads
  in the UI font; the Code page's toasts sit below the chat's head, never over its controls, and "notifications not
  allowed" is no longer an error; a focused resize handle shows a 5 px teal bar; the sidebar's pop-out arrows are no
  longer faded below 3:1, and the "off" badge on the selected Code tab is readable.

## [0.31.3] - 2026-10-26

### Changed

- **Adding a provider key says at once whether it works (UX-05).** Save waits until the field has a key, and an empty
  or unchanged Save, or a key of the wrong shape, never asks for the password: it is said under the field. OpenRouter's,
  Experiential Labs' and OpenAI's or Groq's (speech-to-text) keys are then checked with the provider by the portal — the
  free call setup makes, within 8 seconds instead of about 20 — before the password: a rejected key is said right under
  the field, with a link to where keys come from, and stays there to fix; no answer in time offers **Save anyway** (the
  update helper checks it again). Each key's form has a *Get a key at …* link (the AWS key: AWS's access keys page; a
  search backend: its own) and shows the key's shape (`sk-or-v1-…`). A change the helper refuses opens its form again
  with what you typed and the reason under the field, its address a link, and the progress box marks the step that
  failed (✕).
- **Error pages with a way back (UX-10).** A portal page that is not there and a host name that is not this install's
  (127.0.0.1, a typo) are now DevOS ADE pages in the sign-in card's design, with its fonts: *Go to Home* and *Search*
  (`/?search` opens the search), or *Go to DevOS ADE* with its address. They show nothing of the address asked for,
  run no script and keep a strict policy; under an unknown name Caddy passes on no cookie and reaches no other route of
  the portal. A preview's new-tab link opened outside the Code page now says to open it from the Ports panel.
- **Sign-in (UX-11).** A wrong password says only *That password is not right.*; the hint below says what to do once:
  *Forgot it? Run `./stack password --show` in* this install's folder (on this computer; over remote access without the
  folder). A **Show** button shows the password as typed.
- **Home's update card leads with Update now (UX-20)** when the update helper runs, with `./stack update` folded under
  *From a terminal instead*; when it was checked is said once, in the line above the card.
- **Search ranks where a setting is changed first (UX-22):** when the words typed start words of a Settings section's or
  setting's title, Settings comes above the walkthrough and the docs, its sections first (*budget* → Spending &
  budgets).

### Fixed

- **Tests:** the end-to-end check of Home's automatic-update switch keeps its stand-in update helper's heartbeat
  fresh until Home has seen it before it clicks the switch again; on a slow run it clicked while Home still showed the
  switch disabled and gave up.
- **Tests:** the walkthrough's tablet check records every toast from before its click, so the 1.8 s hint that the
  walkthrough is under the compass button is never missed on a slow run.
- **Setup and updates ride out a slow download.** Building DevOS ADE's images downloads Python, npm and Debian
  packages, with each tool's default patience: pip gave up on one read after 15 s, and the build — setup's, an
  update's, or a test run's — failed on a connection that was only slow (seen on 2026-10-26: `files.pythonhosted.org`
  read timed out). pip now retries 10 times with a 60 s timeout, npm 5 times (up to 5 minutes for one package), and
  apt 5 times, in every image and in the Code page's and subscriptions' installs. Nothing else changes: the same
  pinned, hash-checked packages.

## [0.31.2] - 2026-10-26

### Fixed

- **The built-in SearXNG on Home and in `./stack`, like the other services.** Home's Services list it while it is on
  (*SearXNG · web search (built-in) · ready*, or what Docker says when it is not: *starting*, *unhealthy*, *exited*);
  with `WEBSEARCH_SEARXNG_BUILTIN=off` it is not listed, as speech-to-text is not while it is off. The portal still has
  no way to SearXNG: its state and health come from `./stack`'s record of the containers, `.state/status/services.json`
  (written by `./stack status`, up, setup, restart and Settings' switch, and by the update helper once a minute; a
  record nobody rewrote for 5 minutes says how old it is). `./stack restart searxng` and `./stack logs searxng` work as
  for the others (Settings › Diagnostics › Restart a service offers it while it is on); while it is off both say so.
- **Settings on a phone: each setting's control under its name.** A card with a switch or a button on its right
  (Change, Add key, Set the gateway) squeezed its name, its description and an option's info panel into about two
  thirds of the card. Where a card is narrow — a phone, a tablet's column, a desktop next to the walkthrough — the
  control now sits under the name line and the words use the card's full width, on every card; wider cards keep the
  control beside them.
- **The collapsed sidebar names its icons on keyboard focus too.** Tab through the icon rail (a collapsed desktop
  sidebar, or a tablet's) shows each icon's name beside it — the walkthrough's button its progress too — as hovering
  shows its tooltip; the Code tab's name is never its badge's count.
- **Tests:** a plain `docker build --target test portal` (what `portal/e2e/install/run.sh` builds on) passes again: the
  tests that read the repository's catalog skip without it, as the others always have, and the install check builds
  with the repository's files, as `portal/test.sh` does. The end-to-end suite checks the built-in SearXNG's row on
  Home, its restart and logs, the narrow Settings cards on a phone, a tablet and a desktop, and the collapsed sidebar
  with the Code tab.
- **Llama 3.3 70B uses Claude Code's tools.** Bedrock takes the tools for it but hands its tool call back as the text
  Llama wrote, in Meta's documented form (`{"type": "function", "name": …, "parameters": {…}}`), so Claude Code showed
  that text and ran nothing. LiteLLM's hook (`lib/litellm-hooks/bn_hooks.py`) now reads Bedrock's answer: one that is
  nothing but such calls, each of a tool the request offered and with every argument that tool requires, becomes those
  tool calls, as Bedrock returns them for the other models; anything else (a word around it, a code block, an unknown
  tool, JSON that does not parse) stays text. Bedrock also refused, for Llama alone, a tool result's turn with Claude
  Code's reminders in it ("Conversation blocks and tool result blocks cannot be provided in the same turn"): they now
  go at the end of the result. Its badge is now **works**, its note in the model picker and `devos-claude --models`
  says how, and the harness parity suite runs it with Bedrock's family. README › Models for Claude Code says what
  still differs: no thinking blocks, no image input, and calls it often gets wrong at first.

### Changed

- **An update restarts only what it changed, and setup again is faster.** Setup and `./stack update` (Home's
  **Update now**) recreated LiteLLM, Caddy (twice) and the terminal's gateway at every run, whatever had changed; they
  now leave every service whose image and configuration are the same running, and Docker Compose recreates the others.
  Measured on a throwaway with the terminal and the Code page on: `./stack setup --yes` run again went from 74 s to
  48 s and recreates nothing (before: LiteLLM, Caddy and the terminal's gateway, each time); a changed Caddyfile
  recreates Caddy alone. A real update from v0.30.2 through Home's Update now went from 98 s to 84 s (its setup step
  from 93 s to 79 s; LiteLLM still restarts there, as its configuration changes).
- **A changed configuration file still restarts its service.** Compose sees changes to the compose files and `.env`,
  not to the content of a mounted file, so `./stack` now gives each service the checksum of the files it reads only
  when it starts: LiteLLM's `config.yaml` and hook, the Caddyfile and its `*.caddy` files, the terminal's gateway's
  file, the built-in SearXNG's `settings.yml` (as before) and the sandboxes' managed settings. A changed file recreates
  that service and no other, at setup, update and `./stack up` alike ([what setup and an update
  restart](docs/advanced.md#what-setup-and-an-update-restart)). A container running unhealthy is still recreated.
- **Images are built side by side, services started in groups.** Setup builds all its images in one step (the
  portal, shared-mcp, Open WebUI, the terminal, its egress proxy and the Code page), then starts Open WebUI, the
  portal, Caddy and shared-mcp in one compose call, and the terminal with what fronts it in another: each service
  starts as soon as what it depends on is up. Home's update card shows these steps (*Images*, *Open WebUI + portal +
  shared-mcp*) as it showed the ones before. If the joint build fails, each image is built on its own, as before, so
  the failure is reported where it belongs.
- **Tests:** unit tests (`tests/test_recreate.sh`) check, with the hash Docker Compose itself compares
  (`docker compose config --hash`), that nothing changes when nothing changed, and that a changed mounted file, `.env`
  value or pinned image changes exactly the services that use it; setup's bring-up never forces a recreate; the
  images are built once. The update e2e (`tests/e2e/upgrade.sh`) checks that Home's card lists every step the
  update's log reports, in order and with its time, and allows a service the new release adds.

## [0.31.1] - 2026-10-26

### Changed

- **A new Code page session starts on Claude Sonnet, not Opus.** Wherever no model had been picked — a new browser, a
  phone, the installed app — a session started on Claude Opus, the dearest model: one trivial first turn cost $0.184 on
  Opus against about $0.005 on Haiku. The Code page's default is now Claude Sonnet (the stack's current Sonnet), unless
  Settings › Claude Code › Default model for new sessions (`CODE_DEFAULT_MODEL`) names one.
- **devos-claude starts on the same default** — on your computer and in the browser terminal: Settings' Default model
  for new sessions while it names an enabled model, else the Sonnet slot, else the main model (only when no Sonnet is
  enabled). `--model` and `CLAUDE_BEDROCK_MODEL` still pick another. `devos-claude --models` marks the default and says
  which rule applied (*Settings … is blank, so the Sonnet slot*). Plain `claude` in the browser terminal starts on the
  Sonnet slot too.
- **The model you pick is kept for your sign-in, not per browser.** The code container keeps your last pick (`GET` /
  `PUT /api/prefs`, in its own volume), so a new browser or a phone starts its next session where you left off. A
  default set or changed in Settings after your pick wins over it until you pick again. A browser's pick from before
  this version is taken over the first time it opens the Code page.
## [0.31.0] - 2026-10-26

### Added

- **Web search works out of the box: a built-in SearXNG.** Claude Code's WebSearch now searches on every model with
  no key and nothing to set up: a SearXNG container of the stack (on by default; `WEBSEARCH_SEARXNG_BUILTIN=off`
  removes it) asks Startpage, Yahoo, Yep and Mojeek — the keyless engines that kept answering in testing — and LiteLLM
  hands Claude Code the results, booked at $0. Only the query leaves this computer, from its own internet address; those
  engines may rate-limit it after many searches, so a key gives steadier results. The container is reached by LiteLLM
  alone (an internal network of the two; no port, no Caddy route; never the portal, Open WebUI, the terminal, the Code
  page or their sandboxes), has a network of its own to the internet, runs read-only without capabilities, and has its
  own secret key, made once by setup and never printed (docs/security.md › The built-in SearXNG). `./stack websearch
  status`, `./stack status` and `./stack code status` say *built-in SearXNG (free …)*; `./stack websearch check` makes
  one real search through it.
- **Settings › Models & providers › Search:** a card for each option — the built-in SearXNG (its switch), AgentCore
  Web Search, Tavily, Brave Search, Perplexity and your own SearXNG — with the one in use marked, and the WebSearch card
  saying which and why (*auto: no key set up, so the built-in SearXNG*). Each card's **i** button opens what a search
  costs and its free tier (checked on each pricing page in October 2026, linked), what is sent (the query only), how
  steady and private it is, and where to get a key; it works with a keyboard, a screen reader and a tap.

### Changed

- **`WEBSEARCH_BACKEND=auto`** still takes what you set up first — AgentCore Web Search while its gateway is usable,
  then a Tavily, Brave Search or Perplexity key, then your own SearXNG — and now falls back to the built-in SearXNG
  instead of no search (`builtin` picks it by name; `off` still turns web search off). README › Web search for Claude
  Code has a table of the options with their cost, setup and notes; the walkthrough's provider step says where to pick
  one. The harness parity suite takes `E2E_WEBSEARCH=builtin` for real results.

## [0.30.2] - 2026-10-26

### Security

- **Web search never shows a search key or your SearXNG address's token.** A search service's error text is kept as
  the reason Settings › Models & providers › Search and `./stack status` show; a service that echoes what it was sent
  could put your search key, the setup key or your SearXNG URL there. They are now taken out of it, as it is kept and
  as it is read (so a reason kept by v0.30.0 is cleaned too). What to do when SearXNG fails and `./stack websearch
  status` show its address as `https://host/…`, as Settings does, and Settings no longer shows a `user:password@` of
  a URL setting (the SearXNG URL, the alert webhook).

## [0.30.1] - 2026-10-26

### Fixed

- **Tests:** a Code page check in the end-to-end suite that fails (or skips) now stops and closes the sessions it
  left: the ones it opened, and any still working or waiting for an answer. One turn left hanging — Bedrock
  unreachable, a question that never came — no longer fails the later checks at the Code page's limit of four sessions
  working at once, or leaves the next check's page showing that session instead of a new one. What was closed is
  printed under the check's line in the run's log. `tests/test_e2e_harness.sh` checks it against the Code page's mock
  backend.

## [0.30.0] - 2026-10-26

### Added

- **Web search for Claude Code on every model:** Claude Code's WebSearch now searches on Bedrock's models (Claude
  and the others) and OpenRouter's, which run no web search of their own: LiteLLM runs it (its web search
  interception) and the model gets real results, cites the pages found, and can read one with WebFetch. Only the query
  goes to the search backend. The first backend is **Amazon Bedrock AgentCore Web Search** on your own AWS key — no
  other key, the query stays inside AWS, $7 per 1,000 searches on your AWS bill — through an AgentCore gateway your AWS
  admin sets up once per account (`./stack websearch aws-setup` prints the commands; DevOS ADE never changes IAM).
  Setup checks it (free: the gateway, found by itself when your key may list them, and your key's permission; then one
  search) and names what is missing with the command for your admin (`bedrock-agentcore:InvokeGateway`, …). Or your
  own Tavily, Brave Search or Perplexity key, or a SearXNG URL (`./stack config set WEBSEARCH_…`, or Settings › Models
  & providers › Search: a card for WebSearch — the backend in use, its check, the command for your admin with *Copy* —
  and one for each backend; on the Code page, WebSearch's *not available* result links there). Each search is booked
  like model spend, on the key of the session that searched, against its budget.
  `./stack websearch status | check | aws-setup`; `./stack status` and `./stack code status` say which backend is in
  use. Without one, WebSearch still says it is not available (README › Web search for Claude Code). The harness
  parity suite's WebSearch scenario now requires a real search whose answer cites a page it found, on every family.

## [0.29.0] - 2026-10-26

### Added

- **Settings › Models & providers:** one place where every API key and subscription simply adds models. A card for
  each provider — Bedrock (the AWS key, or this EC2 machine's role), OpenRouter, Experiential Labs, and each of Your AI
  subscriptions (Claude Code, Codex, Copilot, Cursor, Grok, Gemini CLI) — says whether it is on (*On*, *Not set up*,
  *signed in · ChatGPT* …), how many models it adds to every picker (*Adds 24 models to every picker*, how many of
  them free) and where you pick which; its one action adds, replaces or removes the key (*Add key*, *Replace key*), or
  signs the tool in or out (*Sign in* opens it in the terminal, where its own sign-in starts). A provider with its key
  or sign-in is in Chat's *Who answers*, the Code page, the terminal's *Open* and `devos-claude --model` with nothing
  else to set up; without one it sends nothing, and its card says so. Keys stay on this computer: on your devices each
  card says where they are added, with the terminal command. Under the cards, the two lists that narrow the pickers:
  *Models for Claude Code* and *Hidden in Chat's model picker* (a card says when the first leaves its models out).
  Home's model table links there (*More models*).
- **Code page:** a provider without its key shows in the model picker, under *More providers*, as a greyed item that
  opens its card (*OpenRouter models — … Settings › Models & providers › OpenRouter takes it*); before, its group was
  simply missing. `/.bn/models` says which of OpenRouter and Experiential Labs has a key.

### Changed

- **Look:** DevOS ADE now uses the DevOS design system, so it looks like the rest of DevOS. Page and section titles
  are in a serif (Source Serif 4), the interface in Inter and code in JetBrains Mono. All three are the DevOS
  website's own fonts, served by your computer: nothing loads from a CDN. Light mode is on warm paper and dark mode
  uses the DevOS apps' warm "Ink" colours. The accent is ADE's teal, taken from its icon: it marks the main buttons,
  the page you are on, links, progress and switches.
  - **Portal:** buttons and chips are pills and cards have the website's rounder corners. Each page has a small teal
    label above its title and a soft teal wash behind its head.
  - **Code page:** the same colours and fonts. A permission card has an amber edge, like the apps' cards that need
    you, and Claude's headings are in the serif.
  - **Terminal:** the Ink colours, with a teal cursor and a teal current window.
  - **Unchanged:** the layout, and every control and its name. Text keeps AA contrast or better (the numbers are in
    `docs/design.md`). Form fields' borders now reach 3:1, and a disabled button is dashed instead of faded, so its
    label stays readable.
  - **Before you sign in:** the sign-in page's style sheets and fonts are reachable then, as `login.css` already was.
- **Settings:** the AWS key (from *AWS & models*), OpenRouter's and Experiential Labs' keys and models (from *Chat &
  voice*) and *Your AI subscriptions* with *Use my Claude plan in the Code page and Chat* (from *Claude Code*) moved to
  *Models & providers*; each old section says where they are now, with a link. Greyed items that waited for one of them
  — OpenRouter's and Experiential Labs' models in Chat's *Who answers*, Claude on your plan, a Chat sign-in — name the
  new place and open the card (`catalog/setup-links.tsv`); so do `./stack subscriptions`, `./stack costs` and the Code
  page's own words. In each subscription's card, *Sign in* (the terminal's and the Code page's, and Chat's on its own
  line) replaces *Sign in (terminal and Code page)* and *Sign in (Chat)*, and *Check again* is once for each sandbox,
  under the cards. `./stack config` lists the section too.

## [0.28.2] - 2026-10-25

### Added

- **Tests:** a harness parity suite, `tests/e2e/harness-parity.sh` (opt-in, by hand): does a model of another vendor
  work as Claude Code's model with no difference but what it was trained on? It runs real Claude Code sessions
  (`devos-claude -p … --output-format stream-json`) in the terminal's sandbox image, through this checkout's terminal
  gateway, LiteLLM config and hook, on each provider family — Claude Haiku as the control, GPT-6 Luna and Mistral
  Large 3 on Bedrock, an OpenRouter model, two Experiential Labs models — side by side, in a few minutes. Fourteen
  scenarios each, from turns with `--resume` and thinking replayed to Claude Code's tools, images, `/compact`, a model
  switch mid-session, a provider's error, WebFetch and WebSearch; each one's PASS or FAIL with the exact error, and
  the Bedrock spend LiteLLM booked (about $0.50 for every family). The stand-in for the Experiential Labs gateway
  (`tests/e2e/explabs-mock.py`) refuses what the gateway refuses (its llms.txt: an unknown field of a message or a tool
  call, duplicate tool call ids, an image for a text-only model, a parameter the model does not list …) and, for this
  suite, answers through a real model on Bedrock; without a key it stands in for OpenRouter too.

### Changed

- **Models for Claude Code:** the README says what still differs from model to model, as the harness parity suite
  found it (README › Models for Claude Code): WebSearch on Bedrock and OpenRouter, no thinking blocks where the
  provider returns no reasoning, no image input for a text-only model, Llama's tool calls written as text — and
  Mistral Large 3, which gets an image but misreads it (a plain red picture read as white or blue): its note in the
  model picker and `devos-claude --models` now says so.

### Fixed

- **Code page:** an error from the model's provider shows the provider's own words. A refused request said only
  "Claude Code reported: unknown" (the Agent SDK's name for an error it does not classify), with Claude Code's text —
  LiteLLM's `litellm.BadRequestError: BedrockException - {"message": …}` and its model group line — on a line of its
  own above. The page now says what happened in a sentence ("The model's provider refused the request", "… is limiting
  requests right now" …) with the provider's message in the box below it ("API Error 400: This model doesn't support
  the image field for user messages. …"), LiteLLM's wrapping left out so that it fits.
- **Claude Code on Bedrock's other models (GPT-6, Mistral):** an image read with the Read tool no longer ends the
  turn with `400 … This model doesn't support the image field for user messages`. Bedrock's Converse refuses an image
  inside a tool result for those models, though it takes one in a message; LiteLLM's hook now moves a tool result's
  images right after the results, in the same message, under a line naming the call (what LiteLLM already does for
  OpenRouter and Experiential Labs).
- **WebSearch with a model on Bedrock or OpenRouter:** Claude Code's WebSearch now answers "Web search isn't available
  for <model> in DevOS ADE. Use WebFetch with a URL." — never results made up from memory. WebSearch asks the model for
  Anthropic's web search, which the provider runs, and Bedrock runs none: for Claude it failed with LiteLLM's advice to
  set up a search of LiteLLM's own, and GPT-6 or Mistral answered from what they knew under "Web search results for
  query: …", as though they had searched (OpenRouter searches for a few models only, at a price LiteLLM does not
  book). The Experiential Labs gateway runs the search itself, its fee in the cost it reports: its models are
  unchanged.

## [0.28.1] - 2026-10-25

### Added

- **Tests:** `tests/e2e/free-models.sh` (opt-in, no AWS, never the real gateway) checks that free models stay free end
  to end: a Code page session, a Chat conversation with its title and tags, and `devos-claude --model
  xl/deepseek-v4.1-flash:free -p …` in the terminal, against a stand-in for Experiential Labs, each on a key of its own.
  Every request must be on the free model at $0 (the Claude models are priced there, so one that fell back would
  show) and booked to the key it came on, Chat's answer, title and tags to Open WebUI's; each key's spend must stay
  $0, and Home's Equivalent must price the same usage.

### Changed

- **Auto mode's reviewer runs on Claude Haiku, not Sonnet 5.5:** about half a cent for its first check in each
  5 minutes instead of $0.13, and a twentieth of a cent for each further one. It's still a Claude model judging
  each action, whatever the session's model, on the Code page, in `devos-claude` (on this computer and in the
  browser terminal) and for `claude` typed in the terminal. It uses Claude Code's own setting,
  `CLAUDE_CODE_AUTO_MODE_MODEL`, set to your Haiku model while that is a Claude Haiku. Without one it stays on
  Sonnet 5.5, as before. `./stack code status` and `./stack terminal status` say which.

### Fixed

- **A new Code page session starts on the model you picked last**, an Experiential Labs or OpenRouter one too, whether
  or not Settings › Claude Code › Models lists it (that list narrows the picker; it never overrides a choice you made).
  Before, a pick the list did not name gave way to the default Claude model without a word. If the model you picked is
  not served any more (its key removed), the session starts on the default and says so.
- **Claude Code's background work no longer runs on Haiku behind a free model.** Its titles, summaries and Explore
  subagent (its "haiku" model) and its subagents now run on the session's model when that is not one of Bedrock's
  Claude models and is free, or paid and cheaper than Haiku per token (input plus output, the prices the cost views
  use). This applies on the Code page (a switch to or from such a model restarts the session's Claude Code at your
  next prompt) and in `devos-claude --model …` (on this computer and in the browser terminal). With a Claude model,
  a dearer one, or one whose price isn't known, they stay on Haiku.
- **Chat's titles, tags and follow-up suggestions run on the chat's own model**, so a chat on a free model stays free.
  They ran on Haiku whatever the chat's model (Open WebUI's task model). Open WebUI uses each chat's own model when no
  task model is set, and setup now sets none unless you pin one: **Settings › Chat & voice › More › Chat title and tag
  model** (blank: each chat's own) — pin Haiku there if you chat with an expensive model. It applies at the next
  `./stack setup` or update.
- **Home's Equivalent cost view prices Experiential Labs' free tiers too**, and is there while OpenRouter or
  Experiential Labs is on. Before, it priced only free OpenRouter models, so with Experiential Labs' free models it
  showed the same figure as Actual. Now *Equivalent: what the same usage would have cost with no free tiers: free
  OpenRouter and Experiential Labs models priced at their paid versions. Everything else is already at its real
  price.* An `xl/<id>:free` model is priced at its model's prices (from the gateway's details the stack caches); a call
  the gateway reported at $0 on a priced model, not on your own provider key, at that model's list price (a
  promotion). Calls on your own provider key (BYOK) are billed by that provider: they stay $0 in both views and Home
  says how many, as it does for $0 calls whose usage does not say which (a streamed answer). Chat's cost line under a
  free tier's answer adds *≈ $… at paid rates*, and `./stack costs` shows the last 30 days of Experiential Labs usage
  (free tiers at $0, with what they would have cost) and says what Equivalent is. Actual is unchanged: a free model
  is never shown as dollars spent.

### Docs

- **README: "Why does Actual move when I use free models?"** Background work (now on the model you picked), Auto
  mode's reviewer (now Claude Haiku) and Bedrock prompt-cache writes, and where to see which request it was (Admin › Usage).

## [0.28.0] - 2026-10-25

### Changed

- **Claude Code's command is `devos-claude`** (formerly `claude-bedrock`). It is the name setup links into
  `~/.local/bin`, the browser terminal runs, and every page, message, help text and document gives: `devos-claude
  --resume <id>`, `devos-claude --models`, Home's command, the Code page's *Open in the terminal* and the import sheets
  (badge **DC**, was CB). `./stack sessions … --tool devos-claude` works where `--tool` does.
- **The old name keeps working.** `bin/claude-bedrock` (and `/usr/local/bin/claude-bedrock` in the browser terminal) is
  now a shim: it runs `devos-claude` with the same arguments, gives back its exit code and prints nothing of its own.
  Setup links `~/.local/bin/claude-bedrock` beside `~/.local/bin/devos-claude`. An update from v0.27.x needs nothing
  from you: where `~/.local/bin/claude-bedrock` points into the checkout, the update turns that file into the shim and
  adds the `devos-claude` link (a link to another checkout, or a file of yours, is left alone). `./stack uninstall`
  removes both links, only those to its own checkout.
- **What keeps the old name, and why** ([internal names](docs/internal-names.md#devos-claudes-old-name)): its Claude
  Code folder `~/.claude-bedrock` (your sign-in and session history), every `CLAUDE_BEDROCK_*` setting, LiteLLM's
  request tags (`x-litellm-tags: claude-bedrock`, and its `,code` and `,terminal` forms: the spend already logged under
  them) and the tool's id in *Bring your sessions* and *Bring your setup* (what you allowed is kept under it).
- **Tests:** the brand check knows devos-claude's old name too: it may stay only as the shim, an internal name of
  docs/internal-names.md's new allowlist, the old name said as such, or in the CHANGELOG's entries before v0.28.0. New
  unit tests: setup and update link both names, an update from a v0.27.x checkout (its old wrapper linked from
  `~/.local/bin`), the shim's arguments, input and exit codes, uninstall of both links. The e2e runs `devos-claude`,
  checks that `bin/claude-bedrock` gives the same help and a failure's exit code, and that neither link in your
  `~/.local/bin` changes; `tests/run.sh` fails if the suite changes them.
- **An update says it runs in the background, and shows how far it is.** Home's update card says "Updating in the
  background: keep working, or close DevOS ADE …", the step that runs and how long it has taken ("Terminal, 2 min so
  far"), and the steps done with their times, so a slow step never looks stuck; "Updated to vX" when it ends (and in
  Activity, as before). While an update runs, Settings says "An update is finishing: new settings appear when it's
  done", and loads its list again when it is. A rollback does the same.
- **An update restarts faster when your AWS key, its region and the model catalog are unchanged:** the last model
  check's answers are kept (a week at most), so LiteLLM starts once with the models found instead of twice around a
  new check (in the last measured update: 58 s for the full catalog, then the check). A new key, region, catalog or
  LiteLLM checks again, and so does `./stack models --recheck`, at once.
- **Services count as started as soon as they are:** while one starts, its health check runs every second instead of
  at its first 10 s interval, so a restart no longer waits about 10 s more for each service it brings back (setup ran
  again recreated LiteLLM, Caddy, the terminal's gateway, the terminal and Chat's sandbox, each healthy about 10 s
  after its start). After it has started, the checks are as before.

### Fixed

- **Tests:** the shell suite passes on Linux (bash 5.2) as it does on macOS (bash 3.2): 14 tests failed there, the
  same in serial and parallel runs. None was a bug of DevOS ADE itself; each test now checks the same thing on both:
  - four tests that set up the portal's folders (`test_requests_dir_is_private`, `test_up_rewrites_portal_origin`,
    `test_setup_key_created_before_probe`, `test_ensure_portal_dirs_creates_what_compose_mounts`) reached the real
    `docker info`, which the isolation guard refuses: on Linux the portal's folders ask Docker whether it runs
    rootless. Those test files now answer it as rootful Docker Engine, as the one rootless test already does;
  - eight tests read a file's mode with BSD's `stat -f %Lp` first, which on Linux prints the file system's status
    before the mode (OpenRouter's and speech's `.env`, a terminal command's record for Home, speech's probe and notice
    files): a shared `perm_of` (GNU's `stat -c %a` first) reads it on both;
  - two of the project folders' tests took their temporary folder for macOS's: on Linux the tests' folders are in
    `/tmp`, where the sandbox mounts a project at `/projects/<name>` (said as hidden), and their home is in `/tmp`
    too, so "your home folder or a folder around it" came before "a temporary folder itself".
  Every test runs on both, except where the machine decides: on Linux, three are skipped without PyYAML (two) or the
  de_DE.UTF-8 locale (one), and the one about case-insensitive spellings needs macOS's case-insensitive file system.
- **Tests:** the e2e's check of Home's automatic-updates switch no longer fails at random on a slower computer. When the
  portal asked it to wait before a second request, the switch's dialog could close during the wait and the second
  Confirm found nothing to click. The check now opens the dialog again from the switch, and keeps its stand-in helper
  fresh while it waits.
- **Tests:** the unit test that an automatic update's fetch keeps your own ssh command no longer fails at random on a
  busy computer. Its stand-in git recorded the ssh command on every call, and the helper's heartbeat (every 3 s while
  a fetch runs) asks git for the checkout's HEAD and branch: a fetch slower than 3 s had its record overwritten with
  an empty one. Only the fetch records it now.

## [0.27.1] - 2026-10-25

### Changed

- **Tests:** the shell suite runs several tests at a time: about 3 minutes instead of 16 on a 16-core Mac.
  `tests/run.sh -j N` runs N at once (default: one less than the computer's CPUs, at most 8; `-j 1`: one after another).
  Each test runs as before, in a process of its own with its own home and `.env`, and now with a temporary folder of
  its own too. What it prints is the same, line for line: each test in its file's order, the isolation guard's line and
  the counts. Every guard is as strict: a test that writes in this checkout's `.env`, `.state/`, `litellm/` or
  `backups/`, makes a folder in your real home or calls the real docker, aws, tailscale, gh, glab (or curl to this
  computer) fails by name, and with it the suite (the tests running at the same moment fail too: the one that did it
  is among those named). The few slow tests of the last run on that checkout start first; Ctrl-C ends the tests
  running then. Eight checks that piped `printf` into `grep -q` could fail at random with Linux's bash 5 (grep ends
  early and the writer gets SIGPIPE, which pipefail reports: 32 times in 20,000 there): they read a here-string now.
- **Tests:** an end-to-end run builds the images of the same files once. Every run is a Compose project of its own,
  and its setup built each image again under that name (Open WebUI, the portal, shared-mcp, the sandbox, its egress
  proxy, the Code page) — the same images for every stage of a release run. Now the first run of a tree keeps what
  setup built as `bne2e-cache/<name>:<key>` (key: the throwaway's git tree, the image, how it is built), and a later
  run of the same files tags those as its own: setup's image builds took 12 s and now take under half a second
  (measured here; Docker's build cache already made a rebuild of unchanged files quick, and the rest of setup — 4½ to
  8 minutes on this busy Mac — is starting and checking the services). Only setup's builds: an update or a rollback in
  the run builds for real. `E2E_IMAGE_REUSE=0` builds everything; `setup/image-cache` says what was reused.

### Fixed

- **Experiential Labs:** a conversation's second message no longer fails after a model's reasoning. On the Code page
  (and with `claude-bedrock`), a model that answered with its reasoning (a "Thought" block, e.g.
  `xl/glm-5.3-uncensored:free`) got the next message refused: `400 … Invalid value for 'messages.3.thinking_blocks'`.
  Claude Code sends the earlier answer back with its thinking, and LiteLLM put that in a field of its own the gateway
  does not take. The gateway now gets the history without LiteLLM's own fields (`thinking_blocks`,
  `provider_specific_fields`), the earlier thinking as `reasoning_content` — the gateway's field for it: it keeps the
  model's thinking on the lanes that use it and is dropped with a disclosure elsewhere, never refused. A call LiteLLM
  moves to the gateway's Responses API (GPT-5.4 and later with tools and thinking) is unchanged: there LiteLLM sends
  that thinking as reasoning items, which the gateway takes. Chat (Open WebUI) sends an earlier answer as plain text;
  its history goes through the same cleaning. `tests/e2e/explabs.sh --mock` now sends a
  second message after thinking, and its stand-in refuses LiteLLM's fields as the gateway does.
- **Experiential Labs:** a refresh of the model list killed hard (the computer shut down, SIGKILL) left its temp
  folder in `.state/` (`explabs-tmp.…`); the next refresh removes those older than 10 minutes, and only those. Where
  `ps` gives no process start times (BusyBox), the background refresh's pid file takes its process's start time from
  `/proc/<pid>/stat`; where neither has one, it is judged by its age and its process's command — never by the pid
  alone — and its log says so once.
- **Tests:** the check that no script removes files through an unquoted path (`tests/rm_scan.py`) also covers `rm`
  called as `\rm`, `/bin/rm` or `/usr/bin/rm`, behind `env`, `nice`, `timeout`, `busybox`, `command`, `sudo`, `exec`
  or a bare `eval`, `xargs … rm` without `-0` or `-d`, `find` with an unquoted path and `-delete` or `-exec rm`, an
  `-exec rm` with an unquoted argument, and the strings given to `eval`, `sh -c` and `bash -c`. It finds nothing in
  the scripts.
- **The sandbox's egress proxy passes no X-Bn-* header on from a site.** Its own X-Bn-Egress marks its refusals and
  failures; a site's response that carried one is now relayed without it, so no site can pass itself off as a refusal.
  Nothing in DevOS ADE read that header from a site's response (only the isolation test did), so this is hardening.
- **Tests:** the sandbox's isolation check (`terminal/terminal-isolation`) no longer fails when the sandbox's proxy
  gives its DNS-rebinding probes no answer for a moment (Docker's DNS slow after a restart). Such a probe is asked
  again, up to three more times 10 s apart with a longer limit; only a refusal for the address passes. Any other
  answer is judged at once: a page reached through the proxy fails without a retry. A no-answer that remains fails
  saying the proxy did not answer and that it is the environment.
- **Tests:** every end-to-end run left its Open WebUI image (`bne2e-…/open-webui:local`) behind; teardown removes it
  now, with the other images the run built.

## [0.27.0] - 2026-10-25

### Added

- **Experiential Labs as a model gateway** (optional, off without a key): one OpenAI-compatible gateway in front of
  many models, on its credits or your own provider keys connected there. **Settings › Chat & voice › Experiential Labs
  key** (from this computer only), or `./stack config set EXPLABS_API_KEY`, which asks for it without echo; the key is
  checked with the gateway first, never shown back, and reaches only LiteLLM. **Experiential Labs models**
  (`EXPLABS_MODELS`): exact gateway ids, blank = `qwen3.8-27b`. They appear as `xl/<id>` in Chat (named and tagged
  *Experiential Labs*, a group of the Who answers menu; while there is no key, as for OpenRouter, a choice that takes
  you to Settings › Chat & voice › Experiential Labs key), on the Code page and in
  `claude-bedrock` (a group of their own) and on Home. Each model is sent **only the parameters it takes**, from the
  gateway's own model details (`supports_temperature`, `supports_top_p`, `supports_tools`, `chat_max_tokens_field`, …;
  from its public catalog, `GET /api/models/<id>` without the key for each chosen model, joined with the key's own
  list, `GET /v1/models`; with a list read with the same key, `./stack up` reads them in the background and never
  waits for them):
  so a model that refuses a sampling parameter answers instead of failing with `all_routes_failed`; the output cap is
  always sent (as `max_tokens` when a model names no field). Without the details (the list could not be read) no
  sampling, penalty or logprob parameter is sent, tools and the cap still are, and `./stack status` says so. **Costs are what the gateway
  reported** for each call (`usage.cost`), in spend, budgets, Home and Chat's cost line; a call on your own provider key
  (`usage.is_byok`) counts $0 here and Chat's line says *on your own provider key* (streamed: *on your own provider key
  or a free tier*, as LiteLLM drops the flag from a stream). README › *Optional: Experiential
  Labs*; docs/security.md › *Experiential Labs*; an opt-in check of one real completion: `tests/e2e/explabs.sh`.

### Removed

- **The Code page's plain fallback page**, unused since the frontend build replaced it (2026-10-16); an image without
  the build now says so instead ("This image has no Code page build: run ./stack update").

### Fixed

- **Tests:** the sandbox's isolation check (`terminal/terminal-isolation`) no longer fails on a moment of this
  computer's DNS. Its public-site probes are tried again, up to three more times 15 s apart, only while this computer's
  DNS answers one of their names with a private or loopback address, which the sandbox's proxy rightly refuses. A
  failure that remains says first that this computer's DNS answered that name with that address, and so does a
  DNS-rebinding probe that tested nothing. Its refusal checks are judged once, as before.

## [0.26.0] - 2026-10-25

### Added

- **Greyed out means "set it up here".** Everything greyed because of a setting or a sign-in now says where it is
  turned on and takes you there: in the Terminal's *Open* menu, Chat's *Who answers* and the Code page's terminal panel's
  *Open…* (a tool not in the sandbox, the terminal off or not over remote access, the Code page off, no internet,
  Claude on your plan off, a Chat sign-in missing, OpenRouter without a key) choosing it shows *Go to Settings* beside
  the menu, named for where it goes; elsewhere it is a link or an item of its own — the Code page's *Who answers* (a
  tool that is not signed in opens in its terminal panel, where its own sign-in starts), its Auto and Bypass notes, its
  model list's scope, its previews over remote access (when their setting is what is off) and a read-only project
  folder; Home's update tools, Terminal and Code cards on your devices, and its voice note. Settings opens at the row,
  highlighted, a switch of its own focused. One table says what each says and where it goes
  (`catalog/setup-links.tsv`).
- **Every choice in those menus acts on the button beside it** — *Open*, *Use this model*, *Open it here*, *Use Open
  WebUI*, and *Open it in …* for the folder a tool works in —, never on a change of the menu: arrowing through a closed
  menu changes it on some systems, which opened Claude Code from the Code page's *Open…* or started a tool in Chat.
- **Your AI subscriptions, one place to connect them:** each tool's row has its next step — *Sign in (terminal and
  Code page)*, *Sign in (Chat)*, or the setting that puts it in the sandbox — and Claude's row has the switch for
  Claude on your plan (it was a row of its own). Its note on where logins live and how to sign out is shorter. The
  walkthrough's subscriptions step says that greyed items take you to their setting.

### Fixed

- **A variable in your shell could send the OpenRouter or speech-to-text key to another server.**
  `BEDROCK_NOW_TEST_OPENROUTER_API` and `BEDROCK_NOW_TEST_STT_API`, meant for the test suite, were honoured in any
  shell: set to another https address, `./stack` sent the OpenRouter key there when it checked the key or read the
  model list or the credits, and the OpenAI or Groq speech-to-text key when it checked that key. They now count only
  with `BEDROCK_NOW_TESTING=1` (as the test addresses of `lib/host.sh` already did); otherwise they are ignored, with a
  warning, and the keys go only to `openrouter.ai`, `api.openai.com` and `api.groq.com`.
- **Your subscriptions are Chat models whatever the terminal's way out is.** With *Sandbox internet access* on the
  direct way (`TERMINAL_EGRESS=host`) they were greyed in Chat ("off while the sandbox reaches the internet
  directly"). Chat's sandbox now goes out through an egress proxy of its own then — the terminal proxy's image and
  rules, public addresses only, never this computer's services or your network (`compose.code-egress.yaml`; `./stack
  test` checks it) — and the terminal's own way out is not changed. With no internet (`off`) they are greyed, saying
  why. Leaving the direct way removes Chat's proxy before anything starts again (`./stack up`, the terminal's and the
  Code page's setup, update and enable, `./stack project apply` and `add`, `./stack restore`), even when that start
  fails.
- **The Code page's terminal address, typed or from a bookmark** (`code.<host>/.bn/terminal`): it opens the terminal
  like the Code page's own *Open the terminal in a new tab*, instead of a blank page saying "open the terminal from
  the Code page". Only a navigation you start does (`Sec-Fetch-Site: none` with a user's navigation). A link opened
  from another app (mail, chat, a PDF reader) counts as typed: it opens your terminal page or its *Open … here?*
  question, never a launch. A link on another website gets the sign-in or a card with a button to the Code page. The
  session and the Code page's unlock are still needed. Safari may not send `Sec-Fetch-User`, so a typed address there
  can show the card: that fails closed and only costs convenience.
- **Settings › Your AI subscriptions shows Claude's plan switch with the Code page off too**, saying it takes effect
  with the Code page.
- **Changing *Sandbox internet access* frees the Docker networks it no longer needs before making new ones.** When
  Docker has no address range left, it says so and how to free one, instead of Compose's "all predefined address pools
  have been fully subnetted".
- **The Code page's unit tests run on a Mac:** the ones that need the sandbox's Linux tools skip there and say why, and
  fail instead of skipping inside the image.
- **Tests:** the Plan-mode end-to-end check decides on every run.
- **The app icon's torus is the DevOS apps' size.** It filled most of its tile (about three quarters), larger
  than DevOS Companion's and DevOS Mobile's beside it in the Dock. Every icon now has it at their share of the
  tile, measured from their Dock icon (458 of 824 px): the installed app's, the Apple touch icon, the favicons
  and the sidebar's logo. Your installed app picks it up at Chrome's next icon check (it may ask first).
- **Removing the speech-to-text key in Settings** asked "OpenRouter's models disappear from Chat and the API". Each
  key's Remove now says what it does: for the speech-to-text key, that it is refused while Speech-to-text uses OpenAI
  or Groq, and that LiteLLM, Chat and the portal restart.

## [0.25.2] - 2026-10-25

### Fixed

- After an update that changes the app's icon, the portal and the installed app show the new one at once (icons were
  cached for a day). The icons, the logo and the favicons are revalidated on every load (a 304 while unchanged), and
  their addresses in the pages and the app's manifest carry the file's version (`?v=`), so a new icon is a new address
  that Chrome's installed-app check notices; `/favicon.ico` is the 32 px icon itself instead of a permanent redirect.

## [0.25.1] - 2026-10-25

### Fixed

- **Chat's Python runner works**, with numpy, pandas and matplotlib. Open WebUI runs Python blocks with Pyodide in a
  sandboxed frame of its own, which sends no cookie: the portal answered its `pyodide.js` with 401 (before this
  release too). Chat now serves Open WebUI's static `/pyodide/` files without the session check — GET and HEAD of one
  file name, nothing that says who you are passed on, Chat's own policy (docs/security.md, *Chat's one public route*)
  — and the stack builds its own Open WebUI image with the wheels of `open-webui/packages.txt` in it, each checked
  against Pyodide's lock: Chat's page still talks only to itself, so any other package is not available, and says so.
  `./stack status` says what is ready and what was left out; a build that could not download a wheel goes on without
  it and tries again at a later `./stack up`, at most once an hour.
- **A project's settings dialog with long files in both parts** (Claude Code's and the other tools') could not open or
  trust: both parts' texts went to the code container in one answer, which could pass its 4 MiB. The answer is now
  measured in bytes as it is sent; when it would not fit, the other tools' texts are left out first (agents do not
  start there, said), Claude Code's part shown whole.
- **More than 200 notes or files of the other tools** no longer keep the dialog from trusting Claude Code's part: the
  page cuts each part on its own, and the code container cuts them the same way. When the other tools' part is not
  shown whole, *Trust* confirms Claude Code's part alone (a token of its own): agents are not trusted with what you
  were not shown.
- **A session of an agent of your subscriptions taken up again** — from the list, as a fork, or when its process
  ended — in a project whose settings its tool cannot use yet opens the settings dialog first, as a new one does, and
  goes on once you trust them; it no longer stops at "not trusted". A new one whose settings could not be read opens
  the dialog too.
- **Plugin files never keep Claude Code on Bedrock from a project:** a file under the project's `.claude/plugins/`
  that cannot be read or shown (binary, over 256 KiB, a link out, a FIFO), or a plugin tree past its bounds, made
  Claude Code's part unverifiable (as in v0.23.0). The plugin files are still in Claude Code's hash, but judged with the
  other tools' part, with bounds of their own: such a file — and a `.claude/plugins` that is no folder, or a plugin
  file whose name cannot be shown — now keeps agents from starting there, and only them. Past what the dialog can
  show, it now cuts the texts and lists every row, as a start does: a Trust there holds at the start (it said
  "changed" at every start).
- **`./stack test` and the e2e's check of Chat's policy** accept a `report-uri` of Chat's own origin (a path: `/` and
  then neither `/` nor `\`, with no `\` anywhere), and still refuse one that names another host (`//host`, `/\host`,
  which browsers read the same, or a scheme); a `report-to` group, as before.
- **A project trusted in v0.23.0 that cannot be carried over** (its settings not shown whole today) no longer reads
  its settings a second time, with their texts, at every start there.
- **A repository whose git config has a name like José, or a description in another script,** no longer makes an
  agent's every edit ask in Accept edits (nor the watchlist say it could not check everything): UTF-8 text in a value
  is plain. A control character, a line separator or a direction override in a value still is not, and keys, section
  and subsection names stay ASCII.

### Changed

- **The walkthrough is up to date with v0.24:** Accept edits as it works now — with Claude Code, its own (file edits
  and file commands in the workspace go ahead, its protected paths still asked); with an agent of your subscriptions, ordinary files of the project, and
  always asked for git's folder, `.github`, editor, hook and tool settings and links, every edit asked where the
  repository's git settings can run a program, and why, under the agent's turn; a new Code step, *A project's own
  settings* (what Claude Code's part and the other tools' part hold, who needs which, *Trust* in the dialog for what it
  shows whole, v0.23.0's trusts carried over); where the switch for Claude on your plan is (off by default; its row
  says what Anthropic's support article and its legal page each say); and in the Chat step, what Chat's page loads,
  HTML previews on a click by default and the Python runner's packages.

### Security

- **Chat's one public route, deliberately:** the Python runner's static files — GET or HEAD of one plain file name
  under `/pyodide/`, matched on the request target exactly as it arrived (never a cleaned or decoded path: any `%`,
  `..`, `//`, `;` or query and it is the signed-in route as before), sent on as exactly that path, with no cookie,
  `Authorization` or `X-Portal-*` header passed on and nothing set in return; what is there is public and the same for
  everyone — Pyodide's console pages and the build's report of what it vendored are not there (docs/security.md). The
  build downloads each wheel over https only, follows a redirect only to https on the lock's own host, gives each
  download a deadline a watchdog keeps (a server that drips a byte at a time cannot outlast it), and leaves out a file
  name two packages of the lock share.
- **Accept edits asks where a remote's URL could run a program:** a transport helper (`<name>::…`, a name that starts
  with a digit and an empty one included: `1abc::…`, `::…`), or a scheme other than git's own (`https://`, `http://`,
  `ssh://`, `git://`, `file://`, `git+ssh://`, `ssh+git://`, exactly so, in lower case; `9x://` is another) in a
  remote's, a submodule's or a branch's remote URL (git runs `git-remote-<name>` for those), and a colour setting under
  a slot git does not document. The Code page's Git panel refuses those names in a URL you give it, as before.
- **Your subscriptions' agents in Accept edits ask for every edit while a git hook is a link** (since v0.24.0, every
  such edit in that repository could go ahead): `.git/hooks/pre-commit -> ../../scripts/pre-commit.sh`, a common setup, left
  `scripts/pre-commit.sh` a plain file an agent could change without asking — and git runs it at your next commit;
  `.git/hooks -> ../githooks` the same for `githooks/*`. Now a link at or under any folder git runs hooks from — each
  git folder's `hooks/` (a submodule's too, `modules/` 8 levels deep, names with `/` included), `core.hooksPath`
  (`.husky/pre-commit -> …`) and, whatever the config says, `.githooks`, `.husky` and `.husky/_` (a `core.hooksPath` in
  your computer's own git config is not visible to the sandbox), in any spelling a disk that folds names opens — and no
  edit there is plain; a hooks folder that cannot be listed whole neither. `core.hooksPath` is plain only in printable
  ASCII. Edits to scripts a hook calls by name (`npm test`, `make lint`, `scripts/check.sh` …) still go ahead without
  asking, as with Claude Code's own Accept edits. Not looked into: the hooks of another repository inside the project
  (a nested one, or one made with `--separate-git-dir`; git runs them when you commit, check out, merge, rebase or push
  there), and a `core.hooksPath` in your computer's own git config naming another folder (the sandbox does not see
  it). The watchlist says when a hooks folder it watches — `.git`'s, a `core.hooksPath` a config here names, and
  `.husky` — is a link, or holds a link directly in it.
- **The watchlist says when it cannot read a repository's git layout whole** — a `gitdir:` or `commondir` that leads
  outside the folder, to no folder or through a link on its way, a `.git` or `modules/` that is a link, a config git
  reads that is a link, too large or not plainly written (as Accept edits reads one: no key on a section's line, no
  continued line, no comment after a value, at most 5,000 lines), an include outside the folder — and the cards say
  that not every file could be checked, and why, instead of taking what it saw as all there is. Submodules are
  followed 8 levels deep (`modules/` within `modules/`, names with spaces or `/`), 16 in all.
- **Chat's sweep stops everything first:** it used to freeze what it found one process at a time, so a process that
  forked fast enough could start one the sweep had not seen yet. Now every process in Chat's sandbox but bn-coded and
  the init is stopped at once, the sandbox sorted while nothing runs, what is not spared killed, and the rest let go
  on.

## [0.25.0] - 2026-10-24

### Changed

- **DevOS ADE, formerly bedrock-now** (ADE: agentic development environment). Everything you read says DevOS ADE: the
  portal's pages, its sidebar and sign-in, the installed app's name (*DevOS ADE*, *DevOS ADE (bn-dev)*), Settings,
  Activity, the walkthrough, the Code page (*Code · DevOS ADE*), the terminal (*Terminal · DevOS ADE*), `./stack`'s
  output, dialogs on your computer, the README and the docs. The repository is
  [JongoDB-Labs/devos-ade](https://github.com/JongoDB-Labs/devos-ade); the one-liner is
  `curl -fsSL https://raw.githubusercontent.com/JongoDB-Labs/devos-ade/main/install.sh | bash`, and the old
  addresses redirect.
- **A new icon:** the DevOS torus with a teal ribbon, on a black tile — the installed app, the favicons, the Apple
  touch icon and the sidebar. Your browser asks before it gives an installed app its new name and icon.
- **New installs go to `~/devos-ade`**, with the Code page's workspace in `~/devos-ade-workspace`. An install made
  before v0.25.0 is found in `~/bedrock-now` (the installer says it is installed, and changes nothing) and keeps its
  folder and its workspace.
- The GitHub App that *Sign in with GitHub* uses is renamed too (`GITHUB_APP_SLUG`: `devos-ade`). Its client ID is the
  same, so hosts already signed in keep working without signing in again; each takes the App's new name from GitHub's
  own answer (the App's installations, asked with the host's token) at its next renewal or *Test connection*, and
  *Choose repositories* then leads to its page under that name.
- The update check's and the price update's user agents, the comment of SSH keys the Code page makes from now on, the
  commits it makes when you set no identity (`DevOS ADE Code page <code-page@devos-ade.invalid>`) and the sandbox
  proxy's refusals say DevOS ADE. OpenRouter lists the stack's requests under *DevOS ADE*.
- **Upgrading: nothing to do.** `./stack update`, Home's *Update now* and the nightly automatic update bring it as
  usual. Your folder, your addresses (`bedrock-now.localhost` and its hosts), `.env` and its `BEDROCK_NOW_*` names, the
  Compose project and its volumes, the update helper and your sign-in stay as they are: no data moves and nobody is
  signed out ([docs/internal-names.md](docs/internal-names.md) lists what keeps the old name, and why). `./stack
  update` moves `origin` from `JongoDB-Labs/bedrock-now` to `JongoDB-Labs/devos-ade` once (only when it is exactly the
  project's GitHub address: a fork or a mirror is never touched). **An install older than v0.22.1** does not see this
  release on Home after the rename (its check does not follow GitHub's redirect to the new name: *could not check*),
  so *Update now* is not offered and its nightly automatic update, which waits for that check, may not start: run
  `./stack update` in its folder — that always works (git follows the redirect) — and Home works again after it.
  `./stack uninstall` asks you to type `devos-ade` (`bedrock-now` still works).
- **LiteLLM's public model hub is declared off** (`general_settings.enable_public_model_hub: false`): no model list
  for visitors who are not signed in, and Admin's *AI Hub* page no longer logs an error asking for the unset
  setting. It was off already (LiteLLM's default); its switch in Admin is now read-only, set by the stack's config.

### Fixed

- A long install folder no longer runs past the sign-in card: paths, commands and keys wrap inside their card,
  dialog or note on every portal page (the sign-in hint and its wrong-password note, Settings, Home, the walkthrough).
- The Code page on a tablet: the terminal drawer stops at the status bar instead of covering its top
  (*Connected*, *Run*, *Ports*, the model).

## [0.24.0] - 2026-10-24

### Added

- **Your subscriptions as Chat models.** Each one signed in — Codex (ChatGPT), GitHub Copilot, Grok, and Claude on
  your plan while its switch is on — is a model in Open WebUI's menu (not Cursor: it has no switch that turns its
  tools off), answering in the same chat, streamed, with
  its thinking: the provider's own agent through the interface it ships for other apps (Codex's app server, ACP; the
  Claude Agent SDK), with its own login, without tools, in Chat's own sandbox (none of your files there), in an empty
  folder of the conversation's own.
  A chat is one of the agent's own sessions, taken up again each turn. Under each answer: *on your ChatGPT plan ·
  tokens in / out* — never dollars. Chat's *Who answers* lists them too.
- **Who answers on the Code page.** The model picker switches a session to Claude on your plan, Codex, Copilot,
  Cursor or Grok (a new session in the project's folder, your conversation so far going with it), with the tool's own
  models: its answers, tool cards and diffs, its permission questions on the same cards, the modes (Read only and Plan
  refuse its changes, Accept edits allows its edits to plain files of the folder — never to `.git/`, `.github/`,
  `.vscode/`, `.claude/`, `.mcp.json` or a tool's own settings, through a link, or outside it: those are asked), the watchlist, files, Git, Review, history in the list with a
  badge, and usage *on your plan* (tokens, the plan's own limits), no budget in dollars. In a project, once its own
  settings are trusted.
- **Settings › Claude Code › Use my Claude plan in the Code page and Chat** (`CODE_CLAUDE_PLAN`, off by default):
  Anthropic's support article allows the Agent SDK on a plan; its legal page says other apps may not route requests
  through one on their users' behalf — your choice, quoted where you make it.

### Changed

- **Docker Compose 2.24.4 or newer is needed** (2024 on): the compose files use `!override` and `!reset` (Chat's
  sandbox's network). `./stack setup` and `./stack update` say so and stop on an older one, before anything changes
  (an update from an earlier version: before its setup — `./stack update` finishes it once Compose is updated).

### Security

- **Chat's own sandbox for your subscriptions' Chat models** (`subs-chat`): the sandbox's image, a home of its own, and
  **sign-ins of its own** — each Chat tool's folder a volume of Chat's alone (`subs-chat-claude`, `subs-chat-codex`,
  `subs-chat-copilot`, `subs-chat-grok`), signed in there once more with the tool's own flow (`./stack subscriptions
  login TOOL --chat`; Settings › Your AI subscriptions shows a *Terminal & Code page* row and a *Chat* row for each,
  with their own Sign in, Sign out and Check again; Chat's picker shows a tool not signed in for Chat as *Sign in for
  Chat…*, leading there). Nothing copies a login between the terminal's sign-ins and Chat's, and neither can plant a
  file the other's tools run. No workspace, no project folder, no LiteLLM key or MCP token, not on the terminal's
  network, and off the network entirely while the sandbox's way out is the direct one (`TERMINAL_EGRESS=host`: your
  subscriptions are not Chat models then, greyed out saying why); each tool
  started there with its tools switched off, every permission refused, and at the first sign of a tool call the
  agent's process killed there and then, with what it started, nothing it says after reaching the answer (which says
  so, never naming the tool: its title is the agent's words; that session is dropped) — and whatever left its process
  group (`setsid`, `setpgid`) is killed too, when an agent is killed or ends and every 5 seconds: each frozen first,
  the sandbox looked at again until nothing new appears, then killed by pid with its start time checked again — all but
  bn-coded's own, an agent running now (never the one being ended) and what `docker exec` put in (`./stack
  subscriptions login TOOL --chat` and the sign-in it runs, a health check); an agent's end reaches the code
  container 2 s after it exits even while something it started holds its output, and a turn waits at most 10 s after
  a tool's first sign. Without its overlay Chat's sandbox is on a network of its own with no way out, and it does not
  start where a lookup of one of the stack's names does not answer. Open WebUI reaches Chat's models
  through the main Caddy's internal site (`caddy:8098`) with a key (`CODE_CHAT_KEY`) — the code container shares no
  network with Open WebUI; no login is read, refreshed or passed on.
- The Code page's agents: their tool calls on your permission cards; only in the modes that ask, by an allowlist of
  each tool's own mode ids (an ACP agent that starts in another — or reports none — is moved to an allowed one, taken
  once it reports it; one that cannot leave, or switches itself away, ends its session);
  in a project's folder only while its own settings are trusted — Claude Code's and the other tools' (`.codex/`,
  `.cursor/`, `.grok/`, `.gemini/`, `.copilot/`, `.agents/`, `.claude-plugin/`, what the pinned Copilot CLI reads of
  `.github/` — its folders whole, any file directly there but GitHub's own, images and instructions, any other folder
  by its name alone —, a `lsp.json`, Claude Code's plugins, `.vscode/mcp.json`, in its folder and the folders above it
  to the git root, with a `.mcp.json` and `.claude/settings*.json` there), listed whole in the trust dialog, checked
  when it starts, once it has opened, and before every turn (a running agent ends when they change). The other tools'
  files are a part of their own, with a hash of their own: **Claude Code on Bedrock and on your plan decide on Claude
  Code's part alone**, exactly the listing of v0.23.0, so a cloned repository's `.github/` or `.cursor/` — however many
  files, whatever their names — never takes a project's CLAUDE.md and settings away from them; when the other tools' part cannot all be shown, *Trust* covers
  Claude Code's part alone and agents do not start there, the dialog says so — as it shows Claude on your plan's own
  state, and a linked worktree or submodule. Names are compared as a disk that folds them opens them (`.curſor` is
  `.cursor`, `.mcp.jſon` is `.mcp.json`), from each folder's own entries; a folder that cannot be listed makes its part
  unverifiable (one in another tool's own tree: theirs alone); outside a repository, and when the workspace itself is
  the git root, the walk up stops below the workspace (its settings are yours: such a project is asked about again
  where v0.23.0 listed the workspace's `.claude` trees). The git root is
  a `.git` with a `HEAD`: an empty `.git` folder no longer ends the walk up. A project trusted in v0.23.0 stays trusted for
  Claude Code on Bedrock and on your plan while its Claude Code settings are as they were and read whole today
  (without plugins turned on): until it is first looked at — its settings dialog, or a session started there — the
  project list still marks it (the shield: *look at them again*); that first look carries the trust over without
  asking and the mark goes (never over a Stop trusting or a Trust given meanwhile). Otherwise it is asked about again. The other tools' settings are asked about the first
  time an agent starts there. A project's Claude Code settings that add a plugin marketplace (`extraKnownMarketplaces`), or bring plugins by
  another of Claude Code's keys, cannot be trusted; each plugin its `enabledPlugins` turns on is listed in the dialog
  when it is installed in the sandbox already (its version is part of what you trust), and one that is not installed
  there cannot be trusted. Claude on your plan checks its own installed plugins: a plugin it has not installed, and its
  sessions there start with your own settings only, saying why. Another tool's file that names plugins or a
  marketplace by the tools' exact keys (parsed, at any depth — never a dependency named `eslint-plugin-react`), or that
  cannot be read the way the tool reads it, cannot be trusted either. What *Trust* confirms names the project and the
  reading. A link in `.github/` (whatever its name) is never trusted; only a real folder no pinned tool reads is
  listed by its name alone. **Accept edits approves an agent's edit only where the
  repository's git config is plainly harmless** — read with a strict grammar, every key, by its exact name, one that
  never names a program or a path git or git-lfs loads (`core.hooksPath` only as a plain folder of the repository) —
  and asks for every edit otherwise, saying why; never in
  the Workspace itself, nor in a folder of your computer with no repository visible. It also asks for `.idea/`,
  `.zed/`, `*.code-workspace`, `.pre-commit-config.yaml`, `.githooks/`, lefthook's and lint-staged's files,
  `.yarnrc.yml`, `.pnpmfile.cjs`, other agents' folders (`.roo`, `.kiro`, `.continue`, `.amazonq`, `opencode.json`),
  git's folders wherever a `gitdir:` file puts them, in any spelling a folding disk opens (to a fixpoint: `claẞ` is
  `class`), and whenever an entry named like one of those is a link on the way; the watchlist also sees a git folder's
  `info/attributes`, `commondir` and a rebase's to-do list. An agent's config option other than
  its mode, model and thinking level must say *ask*, whatever its name, and a session taken up again leaves an
  approve-everything mode as a new one does.
- A conversation carried to another harness (or to a Chat model's new session) goes in as a quote that holds no
  instructions, its role-like tags defanged and its tags marked with a random mark of their own: an earlier answer
  cannot speak as you.
- Chat's Claude attaches no file and reads none: `CLAUDE_CODE_DISABLE_ATTACHMENTS=1`, `--tools=`,
  `--strict-mcp-config` and `--setting-sources=` (each required by bn-coded), managed settings of Chat's own (every
  file read denied, no hooks, no Bypass or Auto); an `@` in Chat's text is no file's name (`＠`: every one not right
  after a letter or a digit).
- **What an answer can make your browser fetch, in Chat:** Open WebUI's site (locally and over remote access) loads
  images, audio, video, frames, fonts, scripts and style sheets, and sends requests and forms, to itself only, with no
  Referer; by default an html code block opens in Open WebUI's Artifacts panel only on a click, under the Code page's
  artifact viewer's policy (`connect-src 'none'`) as well, and its frame cannot be sent to another site. What Open
  WebUI's page itself would load from elsewhere no longer loads: Kokoro's in-browser speech, Python packages Pyodide
  does not bundle, favicons of cited pages. (Open WebUI's Python runner does not work in this stack yet — nor did it
  before this release: its frame's request for Pyodide is refused by the portal's sign-in; v0.24.1 is to fix it.) What a page can still do — a name the browser looks up on its own, a
  WebRTC request, a popup from a tool's embed — is in docs/security.md (*What Chat's page and an artifact can still
  do*).

(Dev installs that ran a pre-release of this version kept the terminal's sign-ins in volumes of their own,
`<project>_subs-*`: those are not carried over — the terminal's sign-ins are in its home again, so sign in once more
there; `./stack uninstall` removes the old volumes.)

## [0.23.0] - 2026-10-23

### Added

- **Your AI subscriptions, in the sandbox.** Your own plans through each provider's own, unmodified app, signed in
  with that app's own sign-in (a link and a code in your browser): **Claude Code on your Claude plan** (`claude-sub`:
  the same Claude Code in its own config folder, `~/.claude-subscription`, started without the stack's `ANTHROPIC_*`
  variables — `claude` and `claude-bedrock` stay on Bedrock), **Codex** (ChatGPT; `codex login --device-auth`),
  **Gemini CLI** (an organisation's Code Assist, or your own Gemini API key — Google AI Pro and Ultra no longer work in
  it), **GitHub Copilot CLI**, **Cursor CLI** and **Grok Build** (SuperGrok, the X Subscription). Each is in the
  sandbox's image, pinned and checked when it is built (Codex's and Copilot's release files by SHA-256, Gemini CLI's and
  Grok's npm lockfiles, Cursor's by a SHA-256 recorded here — Cursor publishes none; one that fails is left out and
  said), its self-update off; `TERMINAL_AI_TOOLS` (all, none or a list) keeps fewer. The update downloads them once
  (about 500 MB, 1.5 GB unpacked); `TERMINAL_AI_TOOLS=none` in `.env` before updating leaves them out. Each login stays in its own app's file in the sandbox:
  bedrock-now never reads, copies or passes one on, and backups leave them out. `subscriptions` in the terminal and
  `./stack subscriptions status|login TOOL|logout TOOL` here.
- **Who answers, on each page.** The Terminal tab's **Open** menu (Claude Code on Bedrock, a shell, one of your tools —
  each in a window of its own, starting with its sign-in when it has none), the same **Open…** menu in the Code page's
  terminal panel (in the project's folder), and Chat's **Who answers**: a Bedrock or OpenRouter model (a new chat with
  it), or one of your tools **itself** in place of Open WebUI, in the workspace or a project folder — you type into the
  real app. As Chat models your subscriptions are planned (greyed out for now, each with its provider's terms for that
  use); so are your own API keys.
- **Settings › Claude Code › Your AI subscriptions**: each tool, its version, whether it says it is signed in and which
  kind (its own status command — never the login), **Sign out** (its own) and **Check again**, through the update
  helper with the password. *Tools in the sandbox* (`TERMINAL_AI_TOOLS`) under More.
- **Walkthrough**: *Your AI subscriptions and keys* in *Your own tools* (marked New for browsers that went through it).

### Changed

- Claude Code 2.1.309 in the sandbox, with the Agent SDK 0.3.309 (2.1.301 fixed sign-outs after a short `claude auth
  status`). The sandbox's terminal takes the pickers' words from its address (ttyd `--url-arg`), and only with a
  **launch token** the portal makes on your click: an address with words and no valid token — a link from anywhere —
  starts nothing; the terminal asks *Open … here?* first. `bn-session` checks the words again against a fixed list.

### Security

- A login made in the sandbox can be read by anything running there (Claude, a command it runs, a page it reads):
  said by `subscriptions login` and `./stack subscriptions login`, in Settings › Your AI subscriptions, the walkthrough,
  the README and [docs/security.md](docs/security.md#your-ai-subscriptions), with how to sign out and where to revoke it.
- `claude-sub` gets no stack MCP server (Chat's knowledge bases, the shared bucket): `CLAUDE_SUB_STACK_MCP=1` gives it,
  said each time. The other tools get none of the stack's variables either.
- The Code page's terminal menu asks the portal for a launch token with a request of its own; an address alone (a
  link in an answer, a preview) only gets the terminal's *Open … here?* question. `@terminal` does not read a pane of
  your subscriptions' tools (their screens may show sign-in codes): one their launchers or `bn-session` marked, or whose
  processes are one of them (a command line naming them, a path resolved against its folder, its program), or one
  whose processes cannot be looked at whole — a guard against an accidental read, not a boundary.
- `./stack subscriptions` runs the sandbox's command by its path with the system's `PATH`, reads at most 16 KiB of its
  status (a sign-in's or sign-out's output at most 256 KiB, before anything reads its lines), marks each line it shows
  as the sandbox's, and keeps your keyboard away from every sign-in but the two that ask something back; Settings'
  messages for those jobs are never the sandbox's text.
- The tools in the sandbox's image: the build also refuses a setuid or setgid file and any link that is absolute or
  leads anywhere but inside the tools' folder (a link's target is what runs), and stops when it cannot check.
- A folder the pickers name is at most 251 bytes — what ttyd still hands on whole; a longer one would have opened the
  tool in the workspace instead of where *Open … here?* said.
- `./stack test` shows what a failed check read quoted and as printable characters only (a container's answer, the
  sandbox's among them), and the update helper's message for a test names the failed checks alone.

## [0.22.1] - 2026-10-23

### Changed

- **Ready for the project's rename on GitHub** (nothing you see changes now, and nothing breaks on the day): Home's
  update check follows GitHub's redirect from the repository's old name to its new one — one redirect, on the same
  host, for the same request, to the project's repository under its other name only; any other redirect is still
  refused — and takes release links under either name. `./stack update` moves `origin` to the new address once, after
  the rename: only when `origin` is exactly the project's GitHub address (`https://`, `ssh://` or `git@`, kept in the
  same form), and only when the new address answers with every tag of the old one at the same commit (looked up over
  https, never ssh, at most once a day); a fork, a mirror or any other address is never touched, and until the rename
  it does nothing. The installer recognises a checkout under either name, and `./stack open` finds the installed app
  under either name.

## [0.22.0] - 2026-10-23

### Added

- **Bring your setup: your Claude Code setup and Git name and email from this computer, in the Code page's sandbox.**
  The ⋯ menu (also a project's ⋯, the command palette, Settings › Claude Code › **Bring your setup…**, and the Git
  panel's *Use yours from this computer…*) › **Bring your setup from this computer…**: *Look on this computer* (the
  update helper asks you on its screen first — *Allow once* or *Always*, per tool: Claude Code, `claude-bedrock`,
  Git), which lists names and sizes only; *Pick and open* the items you want; *Check and copy* each one as it will
  be. Offered, each its own choice: `CLAUDE.md` (replace the sandbox's, or add yours after it), skills, agents,
  commands, output styles, key bindings, `settings.json`'s `permissions`, `statusLine`, `outputStyle` and `hooks`,
  MCP servers (user scope, and a folder of this computer's local scope) and plugins (installed again from their
  marketplace, a command it runs shown first), and `user.name`/`user.email` (Code page sessions and the Git panel then
  commit as you). Before copying, each says about how many tokens it adds to every request on Bedrock, the programs it
  brings that the sandbox does not have (`uvx`, Docker, a program of your computer), paths of your computer,
  `permissions.allow` rules that run commands without asking, MCP servers on `localhost` or a private address, and
  OAuth sign-ins to make again. The sandbox's own settings are kept (rules and hooks added to them); anything else of
  its own is left as it is unless you choose to replace it (then into its trash folder). In a terminal:
  `./stack sessions config import` (`list`, `scan`, `open`, `consent`).

### Security

- **Bring your setup offers an allowlist, nothing else**, and never reads `env`, the account and state in
  `~/.claude.json`, credentials, a keychain, `~/.ssh`, Git's credential helpers, `~/.aws`, `~/.config/gh`, history
  or sessions; an unknown key, kind, event or shape is dropped. Each offered item is mounted alone, read-only, into
  the throwaway reader container (no network, read-only, no capabilities, as you, a time limit), never through a link
  on the way from your home folder; a look reads names and sizes only, an open only the rows you picked (of the
  helper's own record, never a path). Allowed only on this computer, per tool, and taken back from anywhere; a look
  or an open is never started over remote access.
- **Secrets are never copied silently**: in a copied file or setting they are redacted unless you keep one; an MCP
  server's `env` and `headers` values that look like a secret (by name or shape; a long random value too) are each
  left out unless you tick them; one in its URL, arguments or command keeps the server out unless kept. Keeping one
  needs the portal password (through the portal and the update helper, as an import's keeps). A preview never holds
  a secret; it is made from the same plan as the copy, whose digest (the items, your choices, the sandbox's
  destination as it is) refuses a copy of anything that changed since the check.
- bn-coded writes a setup item only into a fixed destination of the sandbox's `~/.claude` (or its `~/.gitconfig`
  through `git config --file`), never through a link, only while it is as the page showed it, by a temporary file or
  folder renamed into place; what it replaces is moved into `~/.claude/.bedrock-now-trash/`, never deleted (an MCP
  server of the sandbox's own too, put back when the new one is not taken). Which programs the sandbox has is looked
  up, never run — and only names that can exist there: a path only this computer has is never sent to the sandbox.
  Nothing is ever written back to the computer.
- **What lets Claude act without asking is said in its own words** — a whole tool allowed (*any shell command without
  asking, in every session*), a skill's, command's or agent's front matter grants (`allowed-tools`,
  `permissionMode: bypassPermissions`, hooks, MCP servers; front matter that cannot be read), ``!`…` `` commands,
  hooks, a status line, a stdio MCP server's command line — and from another device it is copied only with the portal
  password. A secret by its shape alone (a capability URL's random path, a token in an `mcp-remote` URL or a plugin
  marketplace's URL) keeps that server or marketplace out unless kept, and is shown masked to every device. Copying a
  tool's settings again never takes out the other tool's rules, and lists what it takes out first.

### Fixed

- **Command palette: Tab, Shift+Tab and Enter typed quickly run the entry they chose.** The selection went back to the
  first entry a moment after a query changed, so a Tab typed before that was undone and the next Shift+Tab could land
  on another entry.
- `./stack sessions` (and Bring your setup): the reader's failure now says why (its message was read after it was
  removed).

## [0.21.1] - 2026-10-23

### Security

- **A project's front matter is found where Claude Code finds it.** The trust step (a project's ⋯ › *Claude Code
  settings…*) looked for front matter only after a plain `---` line; Claude Code 2.1.296 also reads it after `---`
  followed by other whitespace (a form feed, a vertical tab, an NBSP, U+2028, U+3000, CRs, blank lines …), and ends it at
  the first `---` anywhere. A skill or agent of a cloned repository could so hide `allowed-tools: Bash(*)`,
  `permissionMode: bypassPermissions` or hooks from the summary you trusted. The block Claude Code reads is now found
  the way it does (one BOM off, its opener and closer); a grant found there or in the plain reading is listed, and a
  text that starts with `---` and does not read the same block both ways leaves the summary incomplete — never trusted.
  Reading front matter is linear in its length (a key twice was told by comparing every key with every other).
- **The trust summary lists the shell commands a project's skills and commands run** each time they are used
  (``!`…` `` and ```` ```! ```` blocks, read as Claude Code reads them — in the body after the front matter too — and a
  second, more cautious way — the union),
  beside what their front matter grants; one too many or too long to show leaves the summary incomplete.
- **Settings trusted before this version are looked at again.** A project's (or a folder of this computer's) trusted
  settings were trusted as the old summary showed them: after the update they are not applied until you trust them
  again (the page says so once per project: *bedrock-now reads Claude Code settings more strictly since v0.21.1 — look
  at them again*, with *Claude Code settings…*).

### Fixed

- **Importing sessions from the Code page: the update helper no longer throws the request away before reading it.**
  Since v0.21.0 its tidying of the request folder kept update, settings and diagnostic requests but deleted the Import
  sheet's (`ses-*.json`) before reading them, so a look, a read, suggestions or a copy keeping a possible secret asked
  from the page did nothing on a running helper (`./stack sessions` in a terminal was not affected).

## [0.21.0] - 2026-10-23

### Added

- **Your Claude Code and claude-bedrock sessions from this computer, in the Code page.** A folder of this computer's
  ⋯ › **Import sessions from this computer…**: *Look on this computer* (the update helper asks you on this computer's
  screen first — *Don't allow*, *Allow once*, *Always for this folder*), pick sessions from the list (titles, dates,
  sizes), then *Check and copy*: each one's possible secrets (AWS and Amazon Bedrock keys, GitHub/GitLab/Slack/
  Anthropic/OpenAI and other tokens, private keys, JWTs, `Authorization` and cookie headers, passwords in URLs, values
  set to a secret's name — in text or as a JSON field named `password`, `token`, `api_key` … — and `.env`-style lines)
  listed with their length (a token's public start only) and **redacted by default**, its thinking blocks taken out when it ran
  elsewhere than Bedrock, **only what you typed, Claude's text, its thinking, its tool calls and compaction summaries
  copied by default** — every transcript rebuilt by allowlist: tool outputs, attached files, MCP and web results,
  command and hook output, what Claude Code adds to your turn in tags of its own (reminders, teammates' and other
  sessions' messages, task notifications) and its own notes each become one line saying so and its size, a kind of
  record it does not know is dropped (*Include tool outputs* brings the outputs, scanned — on the computer, or with the portal
  password from another device; `--with-tool-outputs` in a terminal) —, the transcript shown exactly as it would be
  copied; *Copy into the sandbox* keeps the session's id, its tool calls with their results' ids and its subagents'
  transcripts, and it resumes on any model of the catalog (first open in Manual).
  Badged CC or CB in the project. Keeping a finding needs the portal password (the update helper makes that copy).
  Copy one way: nothing is ever written to `~/.claude` or `~/.claude-bedrock`; copying again replaces a copy not
  continued since, else comes in as a new session. **Continue in this project** forks a session into another
  project's folder, its path rewritten. **Suggested from your computer**: the folders your tools kept sessions for,
  with how to add them here. In a terminal: `./stack sessions import --project NAME` (asks there), `scan`, `fetch`,
  `list`, `consent` (`--always`, `--once`, `--revoke`), `suggest`. Settings › Claude Code › **What bedrock-now may read
  on this computer** lists what you allowed; *Take back* works from any device.

### Security

- **An imported session keeps only what is known to be safe, by allowlist**: what you typed, Claude's text, its
  thinking, its tool calls and compaction summaries; tool outputs, attached files and everything else Claude Code
  recorded are left out unless you ask for the outputs (on the computer, or with the portal password). A scan of
  text is best effort: the redaction is a safety net, not a guarantee; the sheet says how many things were left out.
- Reading your session stores is allowed only on this computer, per tool and folder, and taken back from anywhere
  (the code container then forgets what it read); a request over remote access never asks or allows. The stores are
  read by a throwaway container of the code image (no network, read-only, no capabilities, as you, a time limit) that
  mounts only that folder's store folders read-only, opens each file without following a link and only if it is a
  regular file (no FIFO can hang it), bounds every size and count, and prints its findings in fixed JSON lines;
  `./stack` prints store text as printable ASCII only, a refusal in the sandbox's words apart and labelled. A read
  names rows of the helper's own last look, never a path; every file staged in the code container is checked against
  its SHA-256 and the look's list.
- What needs the portal password (a look, a read, suggestions, a copy that keeps a possible secret) goes to the
  portal (`POST /.bn/sessions` on the code host), which checks it and writes the update helper's request in its own
  request folder (fixed fields, never a path); the Code page's backend never sees the password and has no folder to
  write requests in. Every dialog on the computer's screen ends after 2 minutes.
- The secret scan finds names and values together — a JSON field, a number or a list under a secret's name, a
  name/value pair such as Kubernetes' env, SSM or CloudFormation, a `--flag` and its value, assignments with the name
  anywhere in an identifier, `.netrc`, SQL, XML, YAML blocks, passwords on command lines and in URLs —, treats a value as
  a placeholder only when all of it is one (a shell default holding a value is none), ends an unquoted value only at a
  space or a quote, reads URLs run by run (nested ones in a query too) and command lines word by word, never steps
  over text one of its own matches needs, reads ambiguous text both ways and redacts the union (quote marks and
  apostrophes, a closing quote glued to more, a type before =, <token>), shows only a token's public start (nothing of a password), merges overlapping
  findings, never backtracks (patterns only find where a token starts; loops take the rest — timed on hostile 7 MiB
  inputs for every shape), and runs once per check or copy in a worker thread with a deadline (past it: not copied).
  Every bound fails closed: JSON nested too deep is not copied, said so; titles are scanned whole before they are cut. A kept finding is named by its file and a keyed hash of what it is, never a position; a
  copy names the digest of what was checked. A kept thinking block is never changed: one that would change is left out.
  bn-coded puts the files beside a transcript in only after the transcript went in. Store text reaches the page as text
  only (direction-changing and invisible characters shown, lengths and counts capped), titles and paths scanned too.

## [0.20.2] - 2026-10-23

### Fixed

- **Voice with Bedrock speech-to-text, now that AWS no longer accepts audio for the Voxtral models.** Since October 2026
  Bedrock answers every recording sent to Mistral Voxtral Small and Mini with "Model does not support audio modality"
  (text still works, so the model check said ok, and every press of the microphone failed). bedrock-now now recognises
  that answer as its own state: an install with Bedrock speech-to-text on switches to your browser's speech recognition
  once — at `./stack up`, `./stack update` (and Update now) or `./stack setup` — with Chat restarted, and says so
  plainly on Home (the voice line and one notification), in `./stack status` and in `./stack stt status`: "Bedrock
  speech-to-text was turned off: AWS no longer accepts audio for the Voxtral models (since October 2026). Voice uses
  your browser's speech recognition; or use your own OpenAI/Groq key: ./stack stt set openai|groq." `./stack stt set
  bedrock` and Settings › Voice refuse Bedrock with the reason (Settings shows it unavailable), the model check lists
  voxtral-* as "no audio (AWS)", setup no longer turns it on by default, and Chat shows a fixed message instead of AWS's
  raw answer. Any other failure (network, permissions, throttling) is handled as before, and a check that gets no answer
  within 20 seconds changes nothing; `./stack test` (and Settings' smoke test) only reports the refusal as a failed
  check. The Bedrock path stays: half a second of audio decides at each of those checks, so it works again if AWS takes
  audio again (docs/voice.md).
- **An image build in a log (Update now, Settings) could wait for good** (v0.20.1). The "still building" ticker was
  stopped with a TERM to a process group of its own: a build that ended before that group existed, or a caller that
  ignores TERM, left the build step waiting for a ticker that waited for it — and an update has no time limit. The
  ticker is now ended by KILL to its own PID, which can be neither missed nor ignored.
- **The README and the walkthrough no longer say every model call is billed to Bedrock under "your team's" access
  key.** Models run on Amazon Bedrock in your own AWS account — with an IAM user's access key or an EC2 instance role —
  and the only other places a call can go are the ones you turn on: OpenRouter with your own key (billed by OpenRouter;
  some models free) and speech-to-text through OpenAI or Groq with your own key. They also say that Chat's microphone
  uses the browser's own speech recognition unless you choose otherwise, which sends what you say to the browser's maker.

## [0.20.1] - 2026-10-22

### Security

- **A probe into the sandbox can no longer hold `./stack test` — or the update helper running it — for ever.** A
  `timeout` inside the sandbox binds nothing there (a process in it can stop it), so every probe `./stack test` and
  `./stack project` make into the sandbox now also has a watchdog on this computer: after its deadline the probe and all
  it started are ended, and the check says it could not check (timed out), never that it passed. The update helper's
  jobs have limits too — a smoke test 10 minutes, a project folder change 45; a settings change or a restart only once
  its log has said nothing new for 20 minutes, or after 4 hours — after which the job is ended, said as failed ("no
  progress for 20 minutes" / "after 4 h"), and the helper goes on (backups and updates keep their own handling). An
  image build, which says nothing until it ends, now says in such a log every 2½ minutes that it is still building, so a
  slow first build is not taken for a stuck one; a wait that hangs still is.

### Fixed

- **`./stack project add` with Docker not running at all** no longer refuses ("couldn't ask Docker…"): nothing can be
  mounted then, and the next `./stack up` starts the sandbox with the checked list — only when `docker info` says at
  once that it cannot connect to the daemon. It still refuses when Docker hangs or fails any other way (its
  containers may still run). The folders the running sandbox has mounted are compared as Docker names them and as
  they resolve (`/tmp/ws` is `/private/tmp/ws` on a Mac).

## [0.20.0] - 2026-10-20

### Added

- **Folders of this computer as Code page projects.** `./stack project add ~/src/my-app` (or Settings › Claude Code ›
  **Project folders** › **Choose on this computer…**, a folder chooser the update helper opens on this computer's
  screen — no request names a folder) mounts the folder into the sandbox at the same path, or at `/projects/<name>`
  with *Hide its path* (your path then stays out of what Claude Code sends the model; programs in the sandbox can
  still find it); the sandbox restarts (~15 s, now by default) and open sessions resume with your next prompt.
  Read-write by default, said plainly (what Claude writes there can run on your computer when your tools open the
  folder: git hooks, `.envrc`, VS Code tasks, npm scripts); *Read-only for Claude* mounts it read-only, and the page
  greys out editing, new files, staging and commits there. Removing a folder or making it read-only never waits more
  than 30 minutes for turns to end, and if the sandbox then fails to start it stays down rather than going back to the
  wider access; a change the running sandbox does not have yet is said as pending ("applies when the sandbox
  restarts") in Settings, on the Code page and in `./stack project list`, as Docker reports it. Refused: your home
  folder and those around it, its hidden folders and `~/Library`, system folders, temporary and runtime folders and
  folders of sockets (`/tmp`, `/private/var/folders`, `tmux-<uid>` …: a socket is a way to run commands on your
  computer), a folder holding a socket, a `.claude` folder (not a worktree in `.claude/worktrees`), the workspace and
  this checkout (and folders inside or around them, or around another project), folders holding keys or logins (`.ssh`,
  `.aws`, gh/glab/gcloud logins,
  `.netrc`, an `.npmrc` with a token, another bedrock-now folder, a Time Machine backup …), paths Docker would
  misread; at most 16; every `./stack up` checks them again. `./stack project remove|mode|list`; Settings lists them
  (Remove and Make read-only from any device, Add only on this computer); `./stack code status`, `terminal status`
  and `test` show them; backups keep the list. The workspace may no longer be a temporary folder itself or lie
  behind a folder of sockets (a folder of yours inside a temporary folder still is fine). A linked git worktree or a
  submodule's checkout is added with a plain note: git won't work on it inside the sandbox, since the main
  repository's `.git` (its hooks and configuration) is never shared — add the main repository to use git there.
  Nothing in a folder is opened after it is added (its `.git` and the like are read once then), names from inside it
  are printed as printable ASCII only, and a folder the sandbox still has mounted is not added again until applied.
  `./stack test`'s probes in the sandbox have a time limit, and its write probe never opens a file already there. A
  removed folder's sessions are listed under *Folders no longer added*, read only. The project's trust step, the Git
  panel, Git hosts, Review and the watchlist work in them as in a folder of the workspace. New project has a fourth
  option, *A folder of this computer*, that says where one is added.
  [docs/security.md](docs/security.md#folders-of-this-computer)

## [0.19.0] - 2026-10-20

### Added

- **The sidebar folds to its icons for more room** (desktops): the button at its top, or Ctrl+\ (⌘\ on a Mac) with
  the focus in the portal, turns it into the icon column a tablet shows — each icon with its name as a tooltip and
  for screen readers; Search, the Activity bell, the version and the walkthrough stay, the walkthrough opening as the
  tablet's card beside the icons — and Chat, Code, Admin, Files and the Terminal get the width. The browser remembers
  it, from the first paint of the next load. Tablets keep their icon rail and phones their tab bar, unchanged; with
  reduced motion it switches without the slide.

## [0.18.1] - 2026-10-19

### Changed

- **The sandbox's own words stay apart on every page and route**, not only in the Git panel: when opening, saving,
  renaming or uploading a file, the explorer, the terminal window, Run, the launch configurations, the ports, the
  permission rules, plugins, MCP, projects (a new project, its trust, Remove) or a session's start fail in the
  sandbox's (or Claude Code's) own words, the page says what failed — "Save failed", "Could not start a session" — and
  shows the words in a box of their own, labelled *the sandbox said:* (or *Claude Code in the sandbox said:*), under
  "bedrock-now never asks you to enter a code except in Git hosts › Sign in, right after you press it." The same for
  free text in answers that went well — a launch configuration's or a task's reason, the permission rules' files, a
  search, a plugin, marketplace or MCP action's outcome, an MCP server's error, an error in Claude Code's stream, a
  process that ended, a file restore or a watchlist file not put back, Review's Undo — and for the WebSocket's refusals
  (a prompt, a model or mode switch, each said as what did not happen). A permission prompt's or a blocked action's
  reason is labelled as Claude Code's (or its classifier's), a turn that ended otherwise than the SDK says reads
  "Ended with an error", and a terminal window is named only by bn-coded's own name for it. bn-coded's own fixed
  texts still read plainly: the lists of them are checked equal to what it writes.
- **Sign-in while no app is set up (gitlab.com, GitHub Enterprise) says so plainly**: "Sign-in needs an app
  registered with GitLab once (2 minutes; only a public ID, no secret): Set up sign-in" opens the exact steps in the
  dialog (GitLab's form requires a redirect URI: `http://localhost/`; a GitHub App for an organization's repositories
  under the organization or *Any account*, installed from its page; GitHub's required private key made and its
  downloaded .pem file deleted, never used); the field is **GitHub app client ID (Iv…)** / **GitLab application
  ID**; the waiting Sign in button says "Paste an app ID first"; and "Already use gh on this computer?
  `./stack git-host import gh` Copy" is right there. With bedrock-now's own GitHub App, the dialog only says where to
  install it (*Choose repositories*).
- **Activity names a gh command or a repository path only in their own shapes**: the command gh says it runs as
  bn-gh makes it — one of gh's own commands and the next word, or gh api with an HTTP method (GET, POST, PUT, PATCH,
  DELETE, HEAD) and an endpoint path (no `:` or `@`) —, the path git asks a login for as a URL path; anything else the
  sandbox says there is left out, never shown as a line of Activity.

### Fixed

- **The Git panel's "not a remote URL (https://…, ssh://… or user@host:path)" refusal** read as bn-coded's own again:
  its "…" became "?" on the way, so it never matched the list and showed in the box; it says "..." now, and a test
  checks every fixed text still matches as it arrives.
- **A file in a folder that is not there yet is "not there" (404), no longer "not in the workspace" (400)**: the
  sandbox looked only one folder up, so a file Claude Code was about to write in a new folder (the page polls for it)
  read as outside the workspace; it now resolves the nearest folder that is there. A path that leaves the workspace —
  by "..", or through a link — is still refused.

## [0.18.0] - 2026-10-19

### Added

- **Sign in with GitHub works with no setup.** bedrock-now's own GitHub App is registered
  ([github.com/apps/bedrock-now](https://github.com/apps/bedrock-now)) and is the default for github.com: Git hosts'
  Sign in with GitHub needs nothing in Settings. Install the app on the repositories it may reach (*Choose
  repositories* in the host's row): *Contents: Read and write* and *Metadata*, user tokens of 8 hours renewed with a
  refresh token. An app of your own (Settings › Claude Code › More) stays optional — for GitHub Enterprise, or to
  authorize your own; gitlab.com has no bedrock-now application, so Sign in with GitLab there needs one of yours.

- **Claude knows how git gets a login here.** Every Code page session's instructions now say that git's logins come
  through the sandbox's credential helper and SSH agent (not `~/.gitconfig`, `~/.ssh` or the environment) and list
  the connected Git hosts — host names, kinds and accounts only, never a token — with whether Claude may use each,
  or that none is connected. Asked whether it has git access, Claude no longer says nothing is set up while its git
  works. After you change Git hosts, a session's next prompt restarts its Claude Code to take the new list.
- **gh in the sandbox.** The terminal image has the GitHub CLI (gh 2.102.0, checksum-checked), never logged in.
  While *Let Claude use this host* is on for github.com (or a `*.ghe.com` host), each gh command gets that host's
  token through the same broker as git — in that command's environment only, within the same 30 a minute, each use
  in Activity as gh's, with the command gh says it runs. gh can do far more than git with it (issues, pull requests,
  repository settings, deleting repositories when the token may), and the switch's warning says so. Otherwise gh
  runs without a login and says in one line how to allow it. A GitHub Enterprise Server host gets no login for gh
  from here (gh would send it to any host a command names): `gh auth login` in the terminal serves it.

## [0.17.0] - 2026-10-19

### Added

- **Projects in the Code page.** A project is a folder of the workspace the page works in: the sidebar's Sessions
  tab is now **Projects** (each project with its sessions, the open ones grouped Needs you, Working, Done), and the
  top bar's **project chip** shows and switches it (on a phone: ☰ or the project's name at the top). New sessions
  start in the project's folder, so Claude Code reads its `CLAUDE.md` and `.claude/` settings; the file tree,
  Search, the `@` picker, the Git panel, Review, Run & test, launch.json, the watchlist and Memory follow it. **New
  project**: an empty folder (`git init` ticked by default), a clone (the Git panel's Clone dialog and Git hosts), or
  a folder of the workspace. A project's ⋯: *New session*, *Open a terminal here*, *Connect a git repository* (`git
  init` if needed, then its remote), *Rename*, *Remove from Code…* (the record only; the folder goes to the trash only
  when ticked and named again). **Add to project…** lists a session (or several) in another project; it still runs
  in its own folder. The command palette has *New session in …* and *Switch project: …*; `?project=<id>` links pick
  a project of the list and never create one. Sessions from before are under the **Workspace** (`/workspace`, always
  there); the limits on open sessions are for all projects together. The records are kept by the code container
  (`code-state` volume), not in the workspace. A project is not a boundary: every project is in the one sandbox
  ([docs/security.md](docs/security.md#projects)).
- **A project's own Claude Code configuration applies only once you trusted it.** Everything under a project's
  `.claude/` (settings, skills, commands, agents …), its `.mcp.json`, and the skills, commands, agents, output styles,
  workflows and routines of the folders above it up to the git root (a monorepo's) — hooks, permission rules, granted
  tools, env, MCP servers — is shown first (the project's ⋯ › *Claude Code settings…*, and before a new session
  there), with *Trust this project's Claude Code settings* or *Start without them*; until trusted (or once it changed
  — a pull adding a skill too) a session there runs with your own settings only and only the stack's MCP server, and
  says so. Sessions in a project run Claude Code with `--project-config-root` (its folder), so no `.claude/` below it
  is read. What the page cannot show in full is never trusted. The Workspace's own apply as before.

### Changed

- **Every Code page session starts Claude Code with `--project-config-root`** (its folder; the Workspace's too):
  skills in `.claude/skills` folders below a session's folder are no longer picked up (put them in the project's own
  `.claude/skills`), and `claude mcp add --scope project` is refused there ("Project-scope MCP server changes are
  unavailable…") — add MCP servers in the page's MCP panel or with user scope.
- The Git panel's repository picker lists projects; a clone becomes a project of its own; a repository in a folder
  that is not a project has *Open as a project*.
- A session in a project checks the watched files of the workspace's own top folder too (its git hooks, `.envrc`,
  `.vscode`, `.claude`), not only its project's.
- tmux's `-c` gets every `#` doubled (a folder named like a tmux format is that folder); *Remove from Code* with the
  folder never moves anything through a link and counts sessions open through one; a project records file that
  cannot be read no longer breaks the session list; names and folders also refuse line separators, invisible
  operators and tag characters.
- bn-coded's file, search, git, Run & test, launch.json, watchlist and Permissions ops take a project's folder as
  their root (checked in the sandbox: a real folder of `/workspace`; every path still confined to `/workspace`, also
  through symlinks); sessions are listed from every `/workspace` folder's transcript store, each by its own checked
  working folder, and resume there. The session list holds up to 300 sessions.

## [0.16.0] - 2026-10-18

### Added

- **Sign in with GitHub / Sign in with GitLab** — a third way to connect a Git host, next to an access token and an SSH
  key: *Connect a git host…* shows a code, large, with *Copy*; you open the host's page it links to (the page never
  opens it), enter the code and approve. GitHub's device flow with a GitHub App (no client secret: GitHub's PKCE web
  flow needs one, so it is not used) reaches only the repositories you install the app on (*Choose repositories*),
  its token renewing itself every 8 hours for 6 months; GitLab's Device Authorization Grant with a non-confidential
  application asks for `read_repository`, `write_repository` and `read_user`. A GitLab of your own or GitHub
  Enterprise takes its address and its application ID. The token is handed to git exactly like an access token — for
  one operation, only for the host of the URL you confirmed — and renewed before an operation when it expires within
  5 minutes (once for operations at the same moment, written before git gets it); a renewal the host refuses marks the
  host **Sign in again** and fails the operation with that, without trying again. Remove revokes a GitLab sign-in on
  GitLab too, and says where to revoke a GitHub one. The code container keeps no network of its own: its requests to
  the host go through the sandbox's way out (bn-coded's new `net.tunnel`; the egress proxy's CONNECT by default), with
  TLS from end to end in the code container, strict (the system's roots; a CA of yours only for a server of your own):
  the sandbox sees ciphertext and can at worst block a sign-in. Starting a sign-in works only from the computer running
  bedrock-now.
- **Settings › Claude Code › More: GitHub app client ID, GitHub app name, GitLab application ID**
  (`GIT_GITHUB_CLIENT_ID`, `GIT_GITHUB_APP_SLUG`, `GIT_GITLAB_CLIENT_ID`): public values, blank = bedrock-now's own
  apps once they are registered (until then: README › *Your own app for sign-in*, a minute and no secret); changed only
  from the computer running bedrock-now.

### Changed

- **The walkthrough's Connect a git host** and Settings' Git hosts row mention Sign in with GitHub / GitLab;
  `./stack git-host import` points to it (gh: it reaches less; glab's OAuth login: sign in with GitLab instead).
- **What git in the sandbox says when a Git panel operation fails** (push, pull, fetch, clone, Test connection,
  stage, unstage, discard, commit, status, log, diff, branches, remotes; Claude Code's words for Write message), and
  git's own words where it says why a folder is not a repository or a log could not be read (bn-coded's own fixed
  reasons and refusals read as they are), are never shown as a sentence of ours: the toast or the panel says what
  failed, and the words are in a box of their own, labelled *git in the sandbox said:*, under the line "bedrock-now
  never asks you to enter a code except in Git hosts › Sign in, right after you press it." — the box scrolls, so the
  line stays in view. A hostile sandbox cannot word its text as a message from bedrock-now asking for a code.
- **Names, titles and errors on the Code page show more invisible characters** as `⟨U+…⟩`: Hangul fillers (U+115F,
  U+1160, U+3164, U+FFA0), the Mongolian vowel separator, the combining grapheme joiner, the soft hyphen and
  variation selectors — the text/emoji presentation ones (U+FE0E, U+FE0F) only where no emoji comes before them:
  an emoji stays an emoji.

## [0.15.0] - 2026-10-18

### Added

- **Check for updates.** Under Home's title a line says *Up to date · checked 12 min ago ·* **Check for updates**, or
  *Update available — v0.x.y* (it leads to the update card); a click asks GitHub now instead of waiting for the daily
  check or Home's 3-hourly one. It says *Checking for updates…*, then the answer — a newer release shows the update card
  and scrolls to it — or *GitHub could not be reached — try again later*, or *GitHub's limit for this hour — try again
  after 14:05* (GitHub's 60 requests an hour without an account; the button waits until then, and the portal asks
  nothing before; another refusal from GitHub waits up to an hour). **About this check** at the end of the line says
  why, and that nothing about the install is sent. The same line is in Settings › Updates & backups › *Daily release
  check*, and Ctrl/⌘+K has *Check for updates*. A click asks at most every 30 s and 20 times an hour, never while a
  check runs (it gets that one's answer; the daily check waits for it too), with the same conditional request (a 304
  when nothing changed). It works with `UPDATE_CHECK=false` — a click is an explicit request — while the daily and Home
  checks stay off. It sends nothing about your install. `POST /api/update/check`: a session, `X-Requested-With` and the
  portal's own Origin; over remote access too.

### Fixed

- **Tests:** the end-to-end suite's sandbox check failed when `nip.io` (the public name it uses to test that a name
  resolving to a private address is refused) could not be resolved itself. That outside outage now reads as "DNS
  rebinding not checked" instead of a failure; a name that resolves and is not refused still fails.

## [0.14.1] - 2026-10-18

### Fixed

- **An update could leave the portal unreachable** — "This site can't be reached" for `http://bedrock-now.localhost`,
  every portal check of the smoke test `000` and the update reported as failed, with no portal left to roll back from.
  Docker Desktop had kept forwarding the portal's port to the Caddy container the update replaced: this computer's
  port accepted every connection and reset it while Caddy answered in its new container. Wherever Caddy is recreated
  — setup (so `./stack update` and Home's **Update now**), `./stack up`, restore and rollback, a Settings change that
  restarts it (the Code page or the terminal on or off, remote previews), `./stack code|terminal|remote enable` and
  `disable`, `./stack restart caddy` — the port is now checked from this computer before the portal is used; when only
  the forward is broken, Caddy is recreated once and that is said ("Caddy recreated: the portal answers again"), or how
  to go on ("restart Docker (on a Mac: quit Docker Desktop and open it again), then `./stack up`").

## [0.14.0] - 2026-10-18

### Added

- **`./stack git-host import gh|glab [--host HOST]`**: the login of the GitHub CLI or the GitLab CLI on this computer
  as a Git host of the Code page — kept as its access token, with where it came from, the account and the scopes
  shown in the host's row. The token is read from the CLI (`gh auth token`, `glab config get token`) and handed to the
  code container on the stdin of `docker compose exec -T` — never a command line, an environment variable, a file,
  the browser or the portal; nothing prints it — after the account, the scopes and what it reaches were shown and
  confirmed (`--yes`: without asking). gh's own OAuth token, or a classic token gh was given, reaches every repository
  your account can (a fine-grained one, what it was given), and gh goes on using it — removing it here does not sign gh
  out: the page says where to revoke it, by the token's kind. glab: a personal access token only — an OAuth login of
  glab's is refused (its single-use refresh tokens would break glab or the Code page), as is anything glab or GitLab
  cannot confirm. The Git hosts dialog shows the command, with *Copy*; a plan names the login (*via HTTPS token
  'GitHub' (gh's login, octocat)*); **Remove** says where to revoke a token on the host (classic and fine-grained
  GitHub tokens each at their own page); *Let Claude use this host* on gh's token says how far it reaches.

## [0.13.0] - 2026-10-18

### Added

- **The walkthrough covers what a developer uses**, in six parts: *Set up* (now with **Connect a git host**: GitHub,
  GitLab or any https/ssh server, with an access token — fine-grained on GitHub with *Contents: Read and write*,
  `read_repository` and `write_repository` on GitLab — or an SSH key the Code page makes; **Open Git hosts** opens the
  Code page's dialog, and the step ticks itself off once a host is connected), *Your apps (one sign-in)*, *Chat*,
  **Code with Claude** (open and ask, the permission modes and cards, picking a model from the whole catalog and its
  badges, the workspace with its real folder, files, search and previews, @-mentions and comments on a plan's lines,
  **Clone a repository**, review, commit and push, Run & test and previews of dev servers, the browser terminal, what
  the sandbox can reach, plugins and MCP servers; where the Code page is off, one step on how to turn it on), **Your
  own tools** (`claude-bedrock`, the models from your own code, the shared store) and **Keep it running** (Home,
  Activity and Ctrl/⌘+K search, where the money went, updates, backups and rollback, the portal from your phone). Steps
  that can tick themselves off do: the update helper running, remote access on, a git host connected (as the Code tab
  reports it), as well as before.
- **New since you last looked.** A browser that went through an earlier walkthrough finds the steps it has not opened
  marked **New**, and the button says how many (*15 new* beside **Walkthrough**; under More, *15 new steps since you
  last looked*) until each one is opened; the walkthrough does not open again by itself. A first visit has nothing
  marked new. (`bn.tour` keeps the ids of the steps opened, in this browser only.)
- **The models from your own code** — a walkthrough step and a README section: LiteLLM's API on this computer, at the
  port this install uses (read from the Settings snapshot, `LITELLM_PORT`), OpenAI-compatible (`/v1/chat/completions`,
  `/v1/models`) and Anthropic-compatible (`/v1/messages`); a key per tool in Admin › Virtual Keys with its own budget;
  curl and Python (openai, anthropic) examples to copy, with `YOUR_KEY` — never a key. LiteLLM's port listens on
  `127.0.0.1` only; over remote access LiteLLM is the Admin site, behind the portal sign-in, not an endpoint for tools.
  *What you get* has a row for it.

### Changed

- **Settings' Open Git hosts, an Activity item of a Git host and the walkthrough** open the Git panel's dialog in the
  Code tab in place, when its page is running (a message to it, only `hosts` or `clone`): the page is no longer
  reloaded, so unsaved edits in its editor stay. Otherwise they open its address with `?git=` as before.
- **Git hosts on the Code page are easier to find.** The Git panel's Git hosts control is a labelled **Hosts** button
  (it was an icon), there whenever the folder is a repository, not only with a remote. While no connected host covers
  the remote — or none is connected — a one-line hint says so, with **Connect a git host** (it replaces the small
  *connect a token* link). A new session's welcome offers **Clone a repository** and **Connect a git host**, and the
  not-a-repository state says *Connect a git host…* while none is connected. The Code page tells the portal how many
  hosts are connected (a number only) for the walkthrough.

### Fixed

- **Open Git hosts on a locked Code page** (Settings › Claude Code › Git hosts, an Activity item, the walkthrough)
  opened the Code page without its Git hosts dialog: the unlock form kept `?session` and `?prompt` but not `?git`. It
  keeps `?git=hosts` and `?git=clone` now (nothing else, and no URL with them).
- **`./stack update`'s What's new** cut a long release title at 120 bytes — mid-word ("… credentials that never en"),
  and on a Mac possibly inside a character. It is now cut at a word, with "…".
- **Tests:** the end-to-end check of nightly backups failed when it ran between 2:00 and 5:00 — inside the default
  backup window, where turning nightly backups on starts that window's backup at once and the helper refuses the next
  change while it runs ("Another action is still running"). It now waits for that backup and for the helper to be idle.

## [0.12.0] - 2026-10-17

### Added

- **Remote repositories on the Code page: Git hosts, clone, fetch, pull, push.** Connect GitHub, GitLab or any
  https/ssh git server under the Git panel's **Git hosts** (also Settings › Claude Code › Git hosts) with an access
  token or an SSH key the Code page makes (ed25519; its public half shown with links to add it to your account or as
  a deploy key). Then **Clone a repository**, and in the Git panel **Fetch**, **Pull** (a fast-forward only),
  **Push** and **Publish branch** — each showing where it goes before anything is sent ("Push main →
  github.com/owner/repo (main) via HTTPS token 'GitHub'"; every push, the first fetch from a remote URL) — **Open a
  pull request** after a push to GitHub or GitLab, branches (switch, create, track a remote one), a remote's URL, and
  a picker for the repositories in the workspace (a clone in a folder of it). The credentials are kept by the code
  container in a volume of its own (`code-state`), never in `.env`, the portal or the sandbox: an operation you start
  gets its host's token through a channel only its git process has, or an SSH login signed by the code container (the
  key never enters the sandbox), only for the host of the URL you confirmed — URL rewrites, proxies, credential
  helpers and ssh commands in the repository's configuration are neutralised, and no hook, filter or merge driver
  runs. Claude's own git gets no credential unless you turn on **Let Claude use this host** for a host (off by default;
  only from the computer running bedrock-now; each use in Activity). Adding a host, a token or a key works only from
  that computer too. The sandbox image trusts github.com's, gitlab.com's and bitbucket.org's SSH host keys
  (`/etc/ssh/ssh_known_hosts`). README: *Remote repositories*; docs/security.md: *Git remotes and Git hosts*.

### Fixed

- **Hints that showed `./stack config set KEY VALUE`** (remote previews, sandbox internet access) — `config set` asks
  for the value after the key; the hints now say so. `.env.example` explains that `name:PORT` in
  `TERMINAL_EGRESS_ALLOW` opens that port instead of 80/443/22 for that name.

- **Tests:** right after a pull that changed LiteLLM's hook, the shell suite failed once with an unnamed live-state
  guard (a `./stack up` test re-rendered into the checkout's `litellm/`). It no longer does; `tests/run.sh` names the
  test that trips a guard and lists every failure on its last line.

### Docs

- **README: Git remotes.** *What you get*'s Code page row says Git with remotes (Git hosts: clone, fetch, pull,
  push), and Settings › Claude Code lists **Git hosts** (it opens the Code page's dialog, where the tokens and keys are
  kept).
- **README checked against the code of v0.11.0.** *What you get* has a row for Activity & search, and its rows say
  what v0.10–v0.11 added: `claude-bedrock --models` / `--model`, the Code page's models from the whole catalog,
  @-mentions and comments on a plan's lines, the Terminal's internet through its egress proxy (not this computer's
  services or your network). The Code page's list of subsections links *Models for Claude Code*; *Updating* has a
  paragraph for updates from v0.10.0 or earlier (a blank or `on` `TERMINAL_EGRESS` now reads as `internet`, the way
  back with **+ this computer**, the terminal recreated, what `./stack rollback` puts back); Troubleshooting has rows
  for a *chat only* model, a site the egress proxy refuses (`TERMINAL_EGRESS_ALLOW`, or `host`), Ctrl/⌘+K inside
  Chat or the Code page, and Search without its docs index (Docker Compose older than 2.17); *Testing* says that
  `tests/run.sh`'s last line names every failure, and that a test tripping a guard fails by name. Corrected:
  `./stack config set` takes names only and asks for each value — `./stack config set CODE_MODELS anthropic` and
  `./stack config set REMOTE_PREVIEW true` stopped with "… is not a bedrock-now setting" (README, docs/remote.md);
  `./stack code disable` leaves the browser terminal on (`./stack terminal disable` turns both off); the sandbox has
  GNU `make` now; `BUDGET_TERMINAL` changes on Settings › Spending & budgets like the other budgets;
  `TERMINAL_EGRESS_ALLOW`'s `name:PORT` allows that port *instead of* 80, 443 and 22 for that name (`*,name:PORT`
  adds it); `host` reaches this computer's `127.0.0.1` on Docker Desktop, what listens on every address on Linux;
  Activity's note on an update that turned the Code page on says "internet: public addresses only"; "Settings → Code
  page" is Settings › Claude Code; Settings' Claude Code section, and what can be changed there, include *Models for
  Claude Code*, *Default model for new sessions* and *Sandbox internet access* (opened further only from this
  computer; the terminal restarts); the phone's More sheet has Activity and Search; `./stack logs terminal-egress`;
  the status bar's buttons are 40 px on a touch screen; the egress proxy in the prerequisites, `./stack test`, the
  security model and the repo layout. Every link and anchor in the README and `docs/` resolves.

## [0.11.0] - 2026-10-17

### Added

- **Rich @-mentions on the Code page.** Besides files, `@` now offers `@terminal` (the last 200 lines of the terminal
  panel's current window; `@terminal:500` for more), `@diff` (the changes the Review pane lists), `@problems` (Run &
  test's failed runs with the end of their output) and `@file#L5-10` (those lines of a file). The editor's selected
  lines go in with **Alt+K** (or the *Lines 5–10 to the prompt* button a selection shows, or the command palette);
  the terminal panel, the Review pane and the Problems list have an *Add to prompt* button too; an `@file#L5-10` typed
  in the box (or in a link's draft) becomes a chip as well. Each chip shows exactly what will go — nothing goes that
  is not a chip; it goes after your text as a block of quoted context — between markers with an id made for that
  prompt, labelled as data from the workspace, not instructions, in a fence its content cannot close (a line inside
  that looks like a marker is marked `⟨quoted⟩`), invisible and
  direction-changing characters shown, long lines and large blocks cut (and said), at most 80,000 characters in all
  — and the conversation folds it away under your prompt. The terminal's lines come from a new read-only op of the
  sandbox's spawn server, `terminal.capture` (`tmux capture-pane` with fixed arguments, a checked pane id, escapes
  taken out). What a mention quotes is the workspace's text but goes as part of **your** message, so read the chips
  before you send in *Auto* or *Bypass* mode ([README](README.md#chat-and-sessions),
  [docs/security.md](docs/security.md#context-mentions-and-plan-comments)).
- **Comments on a plan's lines.** When Claude presents a plan (Plan mode), **Comment on lines** shows it line by line:
  a comment on any line (a click, or Enter on it; ↑/↓ move between lines, Esc cancels) goes back with **Keep
  planning…** as `line N:` with the line quoted and your comment, or, when you approve, as your next message in that
  session. Works by keyboard and on a phone.
- **Activity**, the portal's notification centre: a bell at the top of the sidebar (on a phone **More → Activity**,
  and a dot on More) with the number of unread items, and a panel of them, newest first — a budget at
  `BUDGET_ALERT_PCT` of its monthly limit or used up (**Change the budget**), an update available (**What's new**),
  Code sessions that need you (**Answer**), the update helper's jobs (updates, rollbacks, clean-ups, Settings
  changes, backups, diagnostics) and the last `./stack` command typed in a terminal, running and then finished or
  failed, for a week; a model check that could not check every model; failed OpenRouter requests. **Mark as read**,
  **Mark all as read** and dismiss are kept in the browser (ids and times only). Optional **browser notifications**
  (the browser asks once) for new items while a portal tab is open and not looked at — fixed words only, no push
  service. The server
  side derives everything from status files that exist already (`/api/activity`); nothing new is stored
  ([README](README.md#activity-and-search), [docs/security.md](docs/security.md#activity-and-search)).
- **Search** in the portal: **Ctrl+K** (**⌘K** on a Mac), the box at the top of the sidebar, or **More → Search** on
  a phone. It finds the portal's pages, every Settings section and setting by name or key (Enter opens it, lit up),
  Code sessions and workspace file names (asked from the Code tab's frame while this browser has it open; Enter opens
  the file in its editor), Chat conversations (Open WebUI's own search, asked by the portal as you), the walkthrough's
  steps, and the sections of the README and `docs/` (an index built into the portal's image; they open on GitHub at
  your release). Keyboard-driven (↑ ↓ Enter Esc), grouped; matching is linear-time with capped inputs.
- **Every model of the catalog for Claude Code**, not only Anthropic's: the Code page's model picker lists every
  enabled chat model — Claude on Bedrock, Bedrock's other providers (GPT-6, Grok, Llama, Mistral) and the OpenRouter
  models you enabled — in groups (*Starred*, *Anthropic*, *Other providers on Bedrock*, *OpenRouter: free*,
  *OpenRouter*), with a search, prices (a free model shows **free**, $0 — never spend), a star per model kept in this
  browser (starred first), and a badge for how each works as Claude Code's model: **works** (a tool call round-trips
  through LiteLLM's translation), **chat only** (it answers but cannot use tools), **not tested**, **fails** (behind
  *Show all models*). Picking one that is not "works" says what to expect. Checked live with Claude Code 2.1.296
  through LiteLLM 1.105.0 (one turn that must run a shell command): GPT-6 Sol and Luna, Grok 4.7 and Mistral Large 3
  work; Llama 3.3 70B is chat only (it writes its tool calls as text); OpenRouter's models are "not tested", or "chat
  only" when their listing names no tool use ([catalog/code-models.tsv](catalog/code-models.tsv),
  [README](README.md#models-for-claude-code)).
- **Settings › Claude Code › Models for Claude Code** (`CODE_MODELS`): which models the Code page's picker and
  claude-bedrock's `/model` menu list — *All enabled* (the default), *Anthropic only*, or *Pick…* (a filtered checklist
  in the same groups) — and **Default model for new sessions** (`CODE_DEFAULT_MODEL`; blank: the main model). A list for
  convenience, not a limit: every key may use every model, budgets unchanged. LiteLLM restarts on a change (about
  15 s).
- **claude-bedrock** (on your computer and in the browser terminal): `claude-bedrock --models` lists the models with
  prices and how each works (`--models all`: every enabled one); `--model <id or name>` (and `CLAUDE_BEDROCK_MODEL`)
  takes any of them — an OpenRouter id with or without `or/`, an alias as its slot's full id — and an unknown one is
  refused before Claude Code starts, naming the choices; Claude Code's `/model` menu lists the same models by name,
  price and how they work instead of its alias rows (a `modelPicker` in the wrapper's `--settings`). The launch line
  says `openrouter ·` for an OpenRouter model, `free ($0)` for a free one, and "chat only" / "not tested" where it
  applies.
- **LiteLLM caps a request's output at the model's limit** (`lib/litellm-hooks/bn_hooks.py`, copied next to the config): Claude Code asks for up to 32,000
  output tokens and Bedrock's Llama 3.3 70B refused anything over 8,192 — it answers now. OpenRouter's limits come from
  its model list, which also gives each model's tool use. For another vendor's model on Bedrock the hook also leaves
  out Claude Code's running token count after each tool result (a system message of its own, `<total_tokens>…`):
  LiteLLM turned it into a note after the result, and GPT-6 sometimes ended its turn on that note with no answer, or
  asked what to do.

### Changed

- **The Code page turned on by an update nobody watched** is now an item in Activity, with the same **Keep** and
  **Turn off**, instead of a banner on Home (a **Keep** pressed on the banner still counts).
- The portal's image gets the search's docs index through `compose.portal-docs.yaml` (`additional_contexts`: BuildKit
  sends only `README.md` and `docs/*.md` from this folder), which `./stack` adds only where Docker Compose reads it
  (2.17 or newer). With an older Compose the portal builds as before, without the docs index; `./stack` says so when
  it builds the portal, and the search too. `compose.yaml` itself is unchanged for older Composes.
- Browser notifications from Activity say only what kind of thing happened, never a session's title, a prompt or a
  job's message (those stay in the panel).
- Settings is marked busy (`aria-busy`) while it reads the settings again and draws itself anew (when it is shown, after
  a link to a place in it, Reload or a finished change), so assistive technology waits for the new page.
- **The status bar's quick actions are bigger and say what they do**: *Terminal*, *Run*, *Ports*, the permission mode
  and the model are 28 px buttons (40 px on touch screens) with an icon and a label, each with a tip — what it does
  and its shortcut — on hover and on keyboard focus. New shortcuts: `Alt+R` opens Run & test, `Alt+P` Ports &
  previews. The mode opens the mode menu, the model the model picker. On a phone they stay in the ⋯ sheet.
- **The cold-cache line** shows only for models that write the prompt cache at a price (Claude's, and those with
  cache prices): not for Llama, Mistral or a free model.
- **A session's Stop at the budget on another provider's model** goes by what LiteLLM billed: Claude Code prices a
  model it does not know at its own rates (a free model would have been stopped at the budget of a paid one), so its own
  stop is left out there and the next prompt is refused once the spend logs reach the budget. A switch between Claude
  and another provider restarts the process for it at the next turn.
- **The Default model's confirmation** in Settings names the model's price and how it works with Claude Code.
- **The sandbox's internet no longer reaches this computer's services** (the browser terminal and the Code page). The
  sandbox now sits on internal networks only; its one way out is an egress proxy of its own (`terminal-egress`,
  `compose.terminal-proxy.yaml`: a small Node program with no dependencies, on the terminal's pinned Node image, built
  here; about 20 MB of memory idle, 45 kB of disk beside the layers it shares). It passes HTTP and HTTPS — and ssh
  for git, by CONNECT — to public addresses on ports 80, 443 and 22, checked after its own DNS lookup and connected to
  exactly the address it checked (no DNS-rebinding window), and refuses loopback, private (RFC 1918), shared/CGNAT
  (Tailscale's too), link-local (the cloud's metadata address), multicast, reserved and IPv6 unique-local and
  link-local addresses, the IPv6 forms that carry such an IPv4 address, Docker's names and addresses for this computer
  (`host.docker.internal`, the host gateway, ports published on its `127.0.0.1`), names that are never public
  (`localhost`, `.local`, `.internal`, container names) and IP addresses written in other than `a.b.c.d`. Anything that
  ignores the proxy has no route at all. Every process in the sandbox is told about it (`HTTP_PROXY`/`HTTPS_PROXY`,
  `NODE_USE_ENV_PROXY`, ssh's `ProxyCommand`; Run & test and launch.json's dev servers keep them), while Claude Code's
  way to LiteLLM through its gateway and the dev-server previews stay direct. Refusals are logged without paths
  (`./stack logs terminal-egress`); `./stack test` and the e2e suite check them from inside the sandbox. The internal
  networks resolve no outside names either (no way out by DNS) with Docker Engine 26.0 or later (25.0.4, 23.0.11;
  Docker Desktop 4.29+: CVE-2024-29018); `./stack test` says so on an older engine.
- **Settings › Claude Code › Sandbox internet access** (`TERMINAL_EGRESS`) is a choice of three: **Internet only**
  (`internet`, the new default), **+ this computer** (`host`: the sandbox itself on the internet, with this computer's
  services and your network — how v0.10.0 and earlier always worked) and **Off**. Opening it further works only from
  the computer running bedrock-now; closing it works from anywhere. The terminal restarts with the change (its shells
  and open Code sessions end). `TERMINAL_EGRESS_ALLOW` (only these names; `name:PORT` or `*:PORT` opens another port)
  and `TERMINAL_EGRESS_DENY` (never these; while it is set, no IP addresses either, which a name list could not
  match) in `.env` narrow the proxy further.
- **Upgrading:** nothing to edit. A blank `TERMINAL_EGRESS` — and an explicit `on` (`true`/`1`/`yes`), which only ever
  meant "the internet" — now reads as `internet`, so an updated install loses the sandbox's way to this computer's own
  services and your network, and keeps the internet; `off` stays off. The update's *What's new* says so once, with the
  way back (*+ this computer*, or `TERMINAL_EGRESS=host`). `./stack rollback` to v0.10.0 removes the proxy, puts
  `internet` and `host` back to blank (that version's on; `off` stays) and says that the sandbox then reaches the
  internet directly again, this computer's services and your network included.
- **`make` in the sandbox**: the terminal's image has GNU make (Debian's, refreshed weekly with the other packages), so
  Run & test now offers a Makefile's targets (`make -- <target>`, the image's own `/usr/bin/make`) instead of only
  listing them.

## [0.10.0] - 2026-10-17

### Changed

- **The Code page is on by default**, with the browser terminal it runs in (its sandbox): a new install's setup
  turns both on, with the workspace `~/bedrock-now-workspace` (created with mode 700) and the terminal's own key and
  budget, and says so — no extra question, also with `--yes`. `./stack update` does the same on an install that never
  chose (`CODE_ENABLED` blank or absent in `.env`) and says so in its *What's new* ("Code page: on — …; ./stack code
  disable turns it off"); an explicit `CODE_ENABLED=false` or `TERMINAL_ENABLED=false` stays off. A folder that cannot
  be created or used leaves it off with the reason and setup goes on; an image that does not build is turned off
  again and tried once more at the next setup or update, then no more (`./stack code enable` once the cause is fixed:
  an offline or full machine does not rebuild 1.6 GB at every update); `./stack rollback` of the update that turned
  it on turns it off again (the data it restores has no key for the sandbox), keeping a switch you turned off since.
  An update nobody watched (Home's **Update now**, the nightly automatic update) that turns it on also leaves a
  one-time banner on Home with the workspace folder and the internet switch — **Keep** or **Turn off**. Servers and
  scripted `--yes` installs that should not run it put `CODE_ENABLED=false` (or `TERMINAL_EGRESS=off`, which also
  closes the sandbox's way to this computer's services on Docker Desktop) into `.env` before the first setup.
  `./stack code disable` and `./stack terminal disable` now record the choice even while it was off, so updates no
  longer turn it on. What stays opt-in is unchanged: Bypass permissions,
  Auto mode, remote access to the sandbox (`REMOTE_TERMINAL`), remote previews; the sandbox's internet access keeps
  its default. About 1.6 GB more images are built on a new install (the terminal ~1.2 GB, the Code page ~0.4 GB);
  idle they use about 110 MB of memory ([README](README.md#the-code-page),
  [docs/security.md](docs/security.md#the-browser-terminal)).
- **The Code tab is always in the sidebar**; while the Code page is off it explains what it is and how to turn it
  on. Muted, with an *off* pill (on a phone **More → Code (off)**), it shows a page of the portal's own — no frame,
  nothing loaded from the Code page's host: what the Code page does, what turning it on does (the folder Claude would
  see, its own key and budget, Manual mode asking first, Bypass and Auto staying off) and **Turn on in Settings**,
  which opens Settings at the Code page's switch, with `./stack code enable` beside it. Over remote access without
  `REMOTE_TERMINAL=true` it says how to allow it there. Home's Claude Code card and the walkthrough point at the tab
  too. The Terminal tab is unchanged: it shows only while the terminal is on.
- **The end-to-end suite** (`tests/e2e/run.sh`) runs with the Code page on by default, as a new install does;
  `--no-code` (or `E2E_NO_CODE=1`) runs it turned off, for the tab's off page.
- **Settings, reorganized by task.** Eleven sections instead of one long page of eleven cards (14,000 px on a
  desktop, 20,000 on a phone): Account & security · AWS & models · Spending & budgets · Chat & voice · Claude Code ·
  Files & sharing · Remote access · Updates & backups · Diagnostics · Advanced · About this install. A list on the
  left (on a phone, a section picker that stays at the top) shows one section at a time. Moves: Chat's models, voice
  and OpenRouter into Chat & voice; the Code page, the browser terminal (folder, internet access, its Auto mode) and
  Claude Code's models into Claude Code; price updates into Spending & budgets; the 32 values setup and `./stack`
  derive into About this install, so Advanced holds only addresses, ports and internal keys. Each setting has a
  one-line description, its value in plain words ("$50 a month", "30 days (default)"), badges (*This computer
  only*, *Secret*, *Read-only*, what a change restarts) and the full explanation under *Details*; booleans are
  switches. Settings that belong to a switch sit under it and show only while it is on (Bypass and Auto under the
  Code page, a nightly backup's window and count, everything of remote access, OpenRouter's options); rare ones are
  folded under *More settings*. Search and *Changed from default* look through every section and show the matches
  under their section. Links open a section or a setting — `#settings/spending`, `#settings/CODE_ENABLED` — and the
  walkthrough and Home use them. Nothing about how a change is applied, checked or allowed changed.
  `./stack config list` uses the same sections, with a switch's settings indented under it. Where each key is shown
  comes from a new file, `catalog/settings-layout.tsv` ([README](README.md#settings)). A less protective value typed
  in a form on a remote device (a higher budget, a longer session) is refused at once, before the password (the
  portal and the helper refused it already). Without the layout file the page still shows every setting with its
  control, in one list.
- **Tests:** `portal/test.sh` runs the portal's tests in its image with the repository files some of them check (the
  Settings layout against `catalog/settings.tsv`, its links into README and docs); `sh portal/e2e/settings/run.sh`
  checks every key's controls on the Settings page against its policy, locally and remotely, in the e2e suite's
  Playwright image (no stack).

- **Update now and Roll back say what they end besides the downtime**: the browser terminal's container is recreated
  (its tmux windows close; Claude Code running there ends, its conversations stay), Code page sessions resume from
  their transcripts (a running turn stops), and — when the Code page reports one — that a Code page turn is running
  right now. The README's *Updating* says the same.

### Fixed

- **Updates and rollbacks run by the update helper (Home → Update now, Roll back, automatic updates) left the
  checkout unreadable to the Code page's container.** The helper runs with umask 077, so every file such an update
  wrote was 600: the code container then failed with `EACCES` on its own `main.mjs` (Settings → Code page On failed;
  with the Code page already on, the update ended in "setup failed" and only a rollback recovered). git now runs
  with umask 022 during updates and rollbacks, setup repairs the modes of tracked files (installs already hit
  included), and the code image makes its own sources readable. Found by an upgrade rehearsal v0.4.1 → v0.9.0.

- **The sign-in page, the Portal password setting and the walkthrough** now say the password also unlocks the
  Terminal and the Code page (they ask for it once more, because they run commands); they listed only Home, Chat,
  Admin and Files.
- **Settings: the terminal's budget** (`BUDGET_TERMINAL`, the key of the Terminal and the Code page) can be changed
  on the page, with the other budgets and this period's spend; it was listed read-only under Advanced.
- **Settings: long explanations were cut** at 600 characters — mid-word for *Auto mode*, *Auto mode in the
  terminal*, *Allow Bypass permissions* and *Previews over remote access*, in the page and in the confirmation of a
  change. They are whole now.
- **Settings: speech-to-text's cost** said "about $0.002 a minute" for Bedrock; Voxtral Small is an estimated
  ~$0.00014 a minute (Mini ~$0.00004), as `./stack stt` and docs/voice.md say.

- **Home's "What's new" across a jump over several releases.** The update card showed only the newest release's
  notes, so an update from v0.4.1 to v0.9.0 never mentioned the Code page, previews or Auto mode. It now lists every
  release between the installed version and the newest (one line each: tag and headline, newest first; a click opens
  its notes) and their notes, the newest open and the others folded. The portal's release check reads GitHub's list of
  releases (one request, as before) instead of only the latest, and takes the highest `vX.Y.Z` tag, which is what
  `./stack update` installs. `./stack update`'s closing "What's new" lists each release it brought, with its tag's
  headline, too.

- **Home's newest release could be a day old.** The daily check said v0.6.0 while v0.9.0 was out (an update always
  installs the newest). Opening Home now asks for a new check when the last one is more than 3 hours old (in the
  background, at most every 15 minutes, not within an hour of a failed one, and never with `UPDATE_CHECK=false`);
  the update card and the version label say when it last checked, and Update now's confirmation names the release
  "at the last check".

- **Home's last job went stale.** Only the update helper wrote it, so after a failed Settings change and a rollback
  from Home, commands run in a terminal (`./stack code enable`, `./stack update`, `./stack config set`, …) never
  showed: Home kept saying "Rolled back to v0.4.1". A `./stack` command that changes the stack, run in a terminal,
  now leaves its own record (`.state/status/terminal-job.json`: running, then done or failed with its error), and
  Home shows the newest job of either origin, with where it ran and when ("./stack code enable finished · Run in a
  terminal · 10:32"). A record whose command was killed is ended by the update helper.

- **The silent minute while an update or a rollback restarts the portal.** Home could not reach the portal for about
  75 s during Update now (45 s during a rollback) and showed an error banner. The progress card now says the portal
  is restarting and reconnecting, with the time so far, and "Reconnected: the portal was away for 1:15" when it
  answers again.

- **`./stack status`**: the `terminal-gateway` row pushed its state, health and URL out of their columns; the
  service column is now as wide as the longest name.

- **Setup moved the portal off port 80 without asking.** With port 80 taken, setup now says why and which port it
  suggests (8800 or the next one free at that moment), asks (Enter takes it; a port in use is asked again, never
  taken; `--yes` takes the suggestion), and names the new address. Other ports typed at the same question are
  asked again too instead of ending setup.

- **Setup's admin-email line contradicted the question just asked**: after "Open WebUI admin email [you@…]:" it said
  "to use another address, set OPENWEBUI_ADMIN_EMAIL in .env before the first setup". That hint now only appears
  when setup did not ask (`--yes`, no terminal). The address is still stored in lowercase — Open WebUI keeps every
  email in lowercase and ignores the case at sign-in, and the Admin sign-in uses the same address — and setup says so
  when that changed what you typed (or git's address).

- **Ctrl-C during the first setup** ended it without a word and left Postgres, RustFS and LiteLLM running. Setup now
  says what it had done, which services still run, and how to go on (`./stack setup`) or clean up (`./stack down`,
  `./stack uninstall`); the temp-file traps of its phases hand the signal on instead of swallowing it. A Code page it
  was turning on by default (stopped before it came up) is off again, blank as before, so the next setup turns it on.

### Docs

- **README checked against the code of v0.9.0, and easier to find your way in.** New: *What you get* near the top
  (each part, whether it is on by default, and the command that turns it on and off); the Quickstart now names every
  question setup asks (remote access, admin email, OpenRouter key, speech-to-text), the one-click-updates offer,
  Docker's disk and memory with the terminal and the Code page, and what `./stack uninstall` keeps; *Updating from
  v0.4.x* (what changes, what stays off, the terminal's tmux session ending) and, from v0.6–v0.8, launch.json's
  *Start* asking again and running in an environment of its own; the Code page section in subsections, with a list
  of them at its start; troubleshooting for a refused *Start*/*Run* and an unanswered remote Service. Corrected:
  `BUDGET_TERMINAL` is listed under Settings › Advanced, not Budgets & alerts (`./stack config set BUDGET_TERMINAL`);
  Settings has a *Code page* group, and the list of changes that work only from the computer running bedrock-now was
  incomplete; launch.json's *Start* and Run & test show a task in full the first time in each browser and again after
  a change, not every time; the cold-cache example is $0.13 for 48k tokens on Sonnet 5.5 (not $0.18); only Settings
  rolls a failed Code page *On* back; the terminal's and the Code page's `enable`/`disable` restart the portal and
  Caddy; Chat's budget banner is set by setup, `./stack up` and budget changes, not live; `claude-bedrock` prints a
  config line besides the cost line; `./stack serve` on Linux; the e2e suite's `--code` costs about $0.17; the update
  helper's commands in the security model; the remote Service count; what leaves your machine while images are built
  and with remote access. Every link and anchor in the README and `docs/` resolves.

## [0.9.0] - 2026-10-17

### Added

- **Code page: a Git panel** (the explorer's **Git** tab, `Ctrl/⌘+Shift+G`; on a phone ⋯ → *Git*): the branch and
  its ahead/behind, the changed files grouped Staged / Changes / Untracked (and conflicts) with their `+/−`, a file's
  staged or unstaged diff in the editor area, Stage / Unstage per file or group, Discard (asks; the file as it is goes
  to the workspace trash, only while it is as the panel saw it), a commit box (`Ctrl/⌘+Enter`) with **Write
  message** — Claude proposes a message from the staged diff in a helper process that can use no tool (never your
  session or its mode: the diff is untrusted), as a draft in the box, never a commit — who the commit is by, and the
  last 20 commits. A git stopped at its deadline has its `index.lock` cleaned up when it is safe (else the error names
  it); a file inside a nested repository is refused instead of being silently skipped. It refreshes after every turn and action. git runs in the sandbox with
  the Review's hardening plus: **no hook ever runs** (`core.hooksPath=/dev/null`, `--no-verify`, and every
  config-based hook of git 2.54+ — which `core.hooksPath` does not turn off — switched off by name), no signing
  program, no editor, no automatic gc; fixed argument lists, paths after `--` as literal pathspecs, the message on
  stdin. **No push or pull**, by decision (they would send the workspace with the sandbox's credentials to a remote
  Claude can change): use the terminal. New bn-coded ops `git.status`, `git.log`, `git.file`, `git.stage`,
  `git.unstage`, `git.commit`, `git.discard`; routes `/api/git/status|log|file|stage|unstage|commit|discard|draft`;
  bn-coded also allows `--tools=` (empty: no tool) and `--no-session-persistence` for the helper. The Git tests run a
  second time with git 2.54 (code/Dockerfile's `gitnew` stage), where config-based hooks exist
  ([docs/security.md](docs/security.md#the-git-panel)).
- **Code page: Run & test.** *Run* in the status bar (⋯ → *Run & test* on a phone, or the command palette) lists the
  workspace's tasks from the files in its top folder — `package.json`'s scripts, a Makefile's targets (read from its
  `name:` lines; `make` is never asked, and they are offered only where the sandbox has `make`), `pyproject.toml`'s
  entry points (`[project.scripts]`, `[tool.poetry.scripts]`) — next to `.claude/launch.json`'s dev servers. **Run**
  shows the task in full first, like *Start*: each argument of its fixed wrapper (`npm run -- <name>`,
  `make -- <target>`, or `python3` with bedrock-now's loader), the script with npm's pre/post scripts, the recipe or
  entry point, a workspace `.npmrc` (its secrets' values hidden); then bn-coded runs it in a new window of the terminal's tmux, only
  while it is still what you saw (a SHA-256 of the wrapper, the texts and the `.npmrc` / whole Makefile; asked again
  whenever it changes). The new **Problems** list has each run's exit status, duration and the end of its output (the
  last 64 KiB kept); a row opens its window in the terminal panel, and *Run* counts the tasks whose last run failed.
  **Ask Claude** drafts "Run `npm test` and fix failures." in the prompt box instead (never sent by itself). A task
  runs with the image's own programs by their path (npm through the image's node), in an environment of its own: the
  window's bash without `BASH_ENV`/`ENV`/`SHELLOPTS`/`BASHOPTS`/`PS4`, then `env -i` with a few of the container's
  variables, a `PATH` with the image's root-owned folders first, and npm reading neither `~/.npmrc` nor the global
  npmrc — so tmux's global environment, those npmrc files and a program of the same name in `~/.local/bin` cannot
  change what an approved task runs. bn-coded's new ops `run.list`, `run.start`, `run.results`, `run.show`;
  `GET /api/run`, `POST /api/run/start`, `GET /api/run/results`, `POST /api/run/show`.

### Fixed

- **Code page: launch.json's *Start* ran in tmux's global environment.** Anything in the sandbox could set
  `BASH_ENV`, `NODE_OPTIONS` or `npm_config_script_shell` there (`tmux set-environment -g`), point npm at a
  `script-shell` in `~/.npmrc` or the global npmrc, or put an `npm` / `node` of its own first in `PATH`
  (`~/.local/bin`): an entry you approved then ran something else. *Start* now runs like Run & test's tasks (above:
  bash without those variables, `env -i` with an environment made by bn-coded, the image's folders first in `PATH`,
  no user or global npmrc), and the confirmation shows the program file the entry's first argument names — the
  image's own or not, with its SHA-256 when it is not (up to 1 MiB) — which its digest binds. Before each window (Start
  and Run alike) bn-coded checks the terminal's tmux for hooks and loader variables (`LD_*`, `GCONV_PATH`,
  `BASH_FUNC_*`) set by something in the sandbox and refuses to make the window then; it calls the image's own tmux.
- **Code page, previews: the address field keeps what you typed.** After a path's Enter the field took the frame's
  path back a frame or two later, from an effect that ran after the next paint; a busy page ran it after your next
  Enter, so a refused address (`http://…`) lost its red mark and the older path came back over it. Its own Enter now
  shows the cleaned path at once, and only navigations from elsewhere (Reload, a chip, Ports) put the frame's path back.
- **Code page: the toast for a new dev server.** The first list of listening ports (what runs already is no news) is
  taken as soon as the page connects, not at the port watch's next tick up to 3 s later: a server started within those
  seconds now gets its *Preview* toast too.

## [0.8.0] - 2026-10-17

### Added

- **Auto mode, opt-in.** Claude Code's *auto* mode — a reviewer model that approves routine actions and blocks risky
  ones (downloading and running code, sending data out, force pushes …) instead of asking you — is a mode of the Code
  page's picker once **Settings › Code page › Auto mode** is on (`CODE_AUTO_MODE`; on only from the computer running
  bedrock-now, off from anywhere), with the desktop app's name and place: after *Plan* in the `Shift+Tab` cycle,
  remembered for new sessions like *Accept edits*, no confirmation (it still asks or blocks). *Plan* keeps asking you.
  A blocked action shows a card with the rule it matched and **Allow once** (exactly that call runs again, once,
  without the reviewer — as Claude Code's own retry of a recent denial); a shell command's card in *Manual* or *Accept
  edits* offers **Allow, and switch to Auto**, and a plan can be approved with *Auto*. **Auto mode in the terminal**
  (`TERMINAL_AUTO_MODE`) is the same switch for the browser terminal's `claude` (off, `claude` and `claude-bedrock`
  typed there keep auto mode off even while the Code page's is on). "Allow once" approves exactly the call on the
  card — only a shell command's own description may differ. Both off by default; a change restarts
  the terminal (and, for the Code page's, the code container).
- **The reviewer runs on Sonnet 5.5.** Claude Code's classifier asks for the fixed id `claude-sonnet-5`; the catalog
  now maps it to `claude-sonnet-5-5` (an alias, harmless while auto mode is off), so it no longer falls back to the
  session's own model. Verified on Bedrock first (LiteLLM passes its requests, `context-1m` beta included; spend lands
  on the session and key): about **$0.13 for the first check in each 5 minutes** (it sends ~47k tokens of instructions,
  cached) and about half a cent for each further check — on a Haiku session more than the session itself.
  `claude-bedrock` on your computer keeps auto mode off in its lean folder; with `CLAUDE_BEDROCK_AUTO_MODE=1` its
  classifier now runs on Sonnet 5.5 too.
- **Code page: a budget per session** (⋯ → *Budget for this session*; off by default). Warnings in the conversation at
  50 %, 80 % and 100 % of it, from bedrock-now's spend logs, and the share on the cost meter. **Stop at the budget**
  (optional) is Claude Code's own: each of the session's Claude Code processes starts with what is left as its
  `maxBudgetUsd` — verified with a fake API to stop a streaming session after the request that reaches it, mid-turn,
  and to refuse later prompts without a request; per process, so the code container passes what is left (the larger
  of the spend logs' figure and Claude Code's estimate) at every start. The page also interrupts a turn the spend logs
  show past the budget, and prompts are refused while nothing is left. A change while Claude Code runs restarts it at
  the next prompt. **New sessions start with this budget too** remembers one for this browser. `set_budget` over the
  WebSocket; `budget` in `POST /api/sessions`, `session_state` and `/api/state`.
- **Code page: the cold prompt cache, before you send.** After 5 idle minutes, a line above the prompt box says your
  next prompt writes the session's context to the prompt cache again (`~48k tokens ≈ $0.18 on Sonnet 5.5`, at the
  model's cache-write price, and what it would have cost warm). A new session on Opus says how much more it costs than
  Sonnet per token, with a switch. `session_state` carries the backend's `lastActive`.
- **Code page: ⋯ → Permissions.** The allow / ask / deny rules Claude Code applies: the sandbox's
  `~/.claude/settings.json` (where *Always* writes; **Remove** per rule, only while the file is as shown — checked
  again just before the rename — every other key kept, atomic; removing an *ask* or *deny* rule first says what it
  lets Claude do), the workspace's `.claude/settings.json` and `settings.local.json` (shown only: Claude Code on your
  computer honours them too), and the page's own rules (what still asks in Bypass permissions, what Read only denies).
  New bn-coded ops `perm.read` and `perm.remove`; `GET /api/permissions`, `POST /api/permissions/remove`.
- **Code page: sessions grouped** as Needs you (a permission card, a question or a plan waiting) · Working · Done, a dot
  on a session whose turn ended while you were elsewhere, and the tab title `(2) waiting`. On a phone the session list
  opens first while a session waits for you.
- **Code page: Open in the terminal** (a session's ⋯, or ⋯ → *Continue this session in the terminal*): the page's
  process for it ends, and a new window of the terminal panel gets `claude-bedrock --resume <id>` typed into its shell
  (bn-coded `terminal.resume`: a UUID of a transcript that is there, nothing else typed); until Claude Code exits there,
  resuming it in the page is refused (`sessions.running`: two processes would both write the conversation).
  `POST /api/sessions/ID/terminal`.
- **Links into the Code page**: `/?session=<id>` shows or resumes a session; `/?prompt=<text>` puts a draft in the
  prompt box, marked as coming from a link (its lines and characters, the site it was opened from) — never sent by
  itself, never focused, not sent by Enter until "I have read it" (a held Enter's repeats never send, anywhere), and
  always sent into a **new session in Manual mode** (never the session shown, never the remembered mode); at most
  4,000 characters, invisible characters shown; both leave the address bar at once and survive the Code page's unlock (the portal rebuilds the link from what
  checks out).
- **Home: a Code card** (the Code page on): how many sessions need you, the open ones with Resume / Answer, a prompt
  box that opens Code with it as a draft (nothing is sent from Home), and the terminal key's spend against its budget.
- **Walkthrough: the browser terminal and the Code page** get steps of their own where the site offers them (open
  Code → ask → approve a card → preview a server → review changes).
- **Settings: Search settings and Changed from default** (plain settings against `.env.example`'s values, which the
  settings snapshot now carries; secrets are never compared).

### Changed

- The sandbox's Claude Code managed settings are one of three files of the repository (`terminal/managed/*.json`),
  chosen on your computer from the two auto mode switches and mounted read-only at
  `/etc/claude-code/managed-settings.json` (the image keeps `off.json` there as root's file): nothing in the sandbox
  can change them, and `./stack test` checks that as the sandbox's user. With both switches off they say what they
  said before (auto mode off for every `claude` there).
- A call Claude Code denies without asking you (Auto's reviewer, a deny rule, *Read only*) is a card of its own in the
  Code page (`blocked` events), not a plain line.

- Session titles: the session list prefers a title Claude Code wrote (a rename, its `ai-title` or summary) over the
  first prompt for the open sessions too. Probed: Claude Code 2.1.296 writes `ai-title` lines in SDK sessions only
  with its non-essential traffic on (a Haiku request per session), which the sandbox turns off — so in the sandbox the
  first prompt (or your rename) is the title.

## [0.7.0] - 2026-10-16

### Added

- **Previews of dev servers over remote access, opt-in.** `./stack config set REMOTE_PREVIEW true` (or Settings ›
  Remote access, on the computer running bedrock-now; off again from anywhere) makes the Code page's **Preview** and
  **Open in a new tab** work from your phone and laptop too, wherever the Code page is remote: one address for the
  previews, `https://<name>-preview.<tailnet>.ts.net` (one more Tailscale Service — define and approve it first) or
  `preview.<your domain>`. Off by default because that address is the same site as every other app of your tailnet or
  domain: a page your sandbox serves could send those apps requests with their cookies (bedrock-now's own hosts refuse
  them; docs/remote.md says it plainly). Existing installs see no change. A cookie on the preview host says which port
  your browser previews (`__Host-bn_preview`: host-only, `Secure`, `HttpOnly`, `SameSite=Strict`, bound to the Code
  page's unlock and your Tailscale login), set by a single-use, 60-second hand-off from the Code page — so a browser
  previews one port at a time there; Sign out, a new password or the unlock's 12 hours end it; no service worker can be
  installed there. Own-domain mode: `REMOTE_PREVIEW_DOMAIN` puts them on a domain of their own (another site; its own
  certificate and DNS record), and then they are on by default.
- **The same-site guard** on every app host — the portal, Chat, Admin, Files, the terminal and the Code page, on this
  computer and over remote access: a request whose `Origin` is a preview's, one from an opaque origin (`Origin: null`,
  not same-origin: a sandboxed frame or a `data:` page), and any script request from another host of the same site
  (`Sec-Fetch-Site: same-site`: `fetch`, XHR, WebSockets, every `POST`), is refused by Caddy (403, `X-Bn-Refused`)
  before the app; page loads and plain images and style sheets still pass. Every Service of a tailnet
  is one site for browsers (`ts.net` is on the public suffix list), the preview host included, so `SameSite` cookies
  alone would not keep a preview's script from acting as you. docs/security.md "The same-site guard".
- `./stack test` checks the guard (a preview's Origin, another host's `POST` and fetch refused, a page load passes),
  `./stack remote test` the remote preview host (refused without its cookie) and the guard there.
- `tests/e2e/remote/run.sh`: remote access without a tailnet — the real portal and Caddyfile in Tailscale mode behind
  a stand-in sidecar with its own CA, driven by Chromium: the hand-offs, the Code page's unlock, a preview in its pane
  and in a new tab, the cookie's attributes and single use, one port at a time, Sign out; and, run again with the guard
  taken out, what it stops (a preview reading a permissive Chat's API and posting to it as you).
  `tests/caddy-validate.sh`: `caddy validate` of every mode combination (own-domain mode with the DNS-plugin build).
- **Code page: Review changes.** Every file changed — git's view since the last commit when the workspace is a git
  repository (changes made by commands included, Claude's marked; this session's files first), else the session's own
  Edit/Write diffs — with Keep / Undo per change and per file and Undo all; Undo is a reverse patch written only while
  the file is still as the review saw it (a new file to the workspace trash, a deleted one written back; binary files,
  links and partly shown changes are never undone). With git, changes that are not Claude's file edits (a command's,
  yours, older uncommitted work) are marked: a file's Undo reverses only Claude's own edits, anything else asks first,
  and files of the watchlist are marked and checked right after an Undo. A comment on any line waits as a chip in
  the prompt box and goes with the next prompt as `path:line — comment` (an unusual file name quoted and escaped). `Ctrl/⌘+Shift+D`, or **Review** (`+N −M`) in the top bar. The
  sandbox's new `git.diff` op runs `git` read-only with fixed arguments and an environment of its own, so no program a
  repository names runs (fsmonitor, filters, external diffs, textconv, pagers, hooks, lazy fetches), proven by a
  test against a hostile repository with a control run of plain git.
- **Code page: Search in files** (the explorer's Search tab, `Ctrl/⌘+Shift+F`): the sandbox's new `fs.grep` op —
  ripgrep with fixed arguments (literal or ripgrep's linear-time regex, case, include/exclude globs, 100 hits per file,
  files ≤ 1 MiB, 10 s, 2,000 results, `.gitignore` honoured, links not followed), or a bounded literal walk without
  ripgrep; results by file and line open the editor at the line.
- **Code page: command palette** (`Ctrl/⌘+K`, `Ctrl+Shift+P`; `Ctrl/⌘+P` for files): actions, modes, models, effort,
  panels, sessions, files and recent picks, fuzzy-matched in linear time, entirely by keyboard; a sheet on a phone. The
  keyboard shortcut sheet (`Ctrl/⌘+/` or `?`) now lists every shortcut.

- **More previews on the Code page.** Word documents (`.docx`: headings, lists, tables, pictures from inside the file,
  links), Excel and OpenDocument workbooks (`.xlsx`, `.xlsm`, `.ods`: sheet tabs over the table, values as saved —
  formulas are never read or computed, hidden sheets marked), PowerPoint decks (`.pptx`: an outline of each slide's
  title, text, tables, pictures and speaker notes — no layout), Jupyter notebooks (`.ipynb`: Markdown cells, code
  highlighted for the kernel's language, outputs with their terminal colours, images, formulas), formulas in Markdown
  previews and notebooks (`$…$`, `$$…$$`: KaTeX, drawn in a worker), and — in a **sandboxed viewer** of their own —
  HTML files (first without their scripts; **Run this page's scripts** runs them, with no network), Mermaid diagrams (`.mmd`, ```` ```mermaid ```` blocks in Markdown and notebooks;
  shown as images) and notebooks' HTML and JavaScript outputs (on request). The viewer is on the previews' site
  (`a<capability>.artifact.<PREVIEW_DOMAIN>`), sandboxed, framed only by the Code page; local only for now (over
  remote access these say so, with Source and Download). Old `.doc`, `.ppt`, `.xls`, binary `.xlsb`, `.odt`, `.odp`,
  RTF and EPUB files: Download. New pinned dependencies of `code/web`: `mammoth` 1.13.0, `htmlparser2` 12.0.0, `fflate` 0.8.3, `katex`
  0.19.0, `mermaid` 12.0.0 (its `katex` and `lodash-es` raised to fixed versions by overrides), and SheetJS Community
  Edition 0.20.3 vendored as the tarball from its CDN (`code/web/vendor/xlsx-0.20.3.tgz`, its SHA-512 in
  `package-lock.json`; never npm's `xlsx` 0.18.5, which has known vulnerabilities). mammoth's JSZip and command-line
  `argparse` are replaced by empty local packages (the page reads zip files with its own bounded reader).

### Changed

- The Code page's previews are no longer "local only": over remote access the Code page says why they are off (the
  default, or no address yet) and what turning them on means.
- `./stack up` warns when `TS_SERVICE` is longer than 54 characters (`<name>-terminal` / `-preview` would exceed a DNS
  label); `./stack remote enable` refuses such a name.
- **Code page:** the API's `PUT /api/fs/file` takes `create` (only when there is no such file) and `DELETE /api/fs`
  takes `ifMtimeMs` (only while unchanged); an edit event says when a Write created its file (`created`); the
  WebSocket takes `watch_check` (the watched files checked now).
- **Code page:** paths are taken exactly as the backend names them: a backslash is part of a file name, never turned
  into a folder separator (it could make the page show or change another file).

### Fixed

- **"The update helper is not running" while it was running (macOS).** The helper replaces `helper.json` every 2-3 s
  with a rename, and Docker Desktop's file sharing tells the container for 10-30 ms after each rename that the file
  does not exist. About one read in 200 (more while a job runs) then found no helper: **Save** in Settings answered
  *The update helper is not running*, Settings opened read-only with *One-click updates are off*, Home lost a running
  update's progress for a poll. The portal now reads a file that is listed in its folder again (the listing
  refreshes it; measured: one retry is always enough), for every file `./stack` and the helper write. Linux was not
  affected. Also: a heartbeat up to 10 s ahead of the portal's clock still counts (Docker Desktop's clock can trail
  the Mac's, e.g. after sleep), and the refusal says when the helper was last seen, or that Docker's clock is behind.

### Security

- **Zip bombs and hostile Office files.** Word, Excel and PowerPoint files are zip files: the page's own reader checks
  the whole directory before inflating anything (at most 5,000–10,000 parts; each part's declared size within 64 MB,
  all within 128–160 MB and 200 × the file's size; no zip64, encryption, overlapping or duplicate parts) and inflates
  a part only up to the size it declared — one byte more stops it. SheetJS never unpacks a file's zip itself (its
  inflater trusts declared sizes): it gets the value parts only, re-packed uncompressed. XML is parsed without DTD
  entities (no billion laughs, no XXE); a document's HTML is sanitised to an allowlisted tree; linked (external)
  pictures are never fetched. SheetJS sees an `.xlsx`'s values only (each sheet rebuilt as its `<sheetData>`: no
  hyperlink or merge ranges, column definitions or dimension, which it expanded cell by cell); `.ods` files use the
  page's own reader (repeated rows and cells bounded). Caps are set by measured memory: a worker that runs out of heap
  takes the page down with it (a unit test runs each reader at its caps within a 1 GB heap). Formulas are drawn in a
  worker with a 3 s budget each; one that defines macros is shown as source. See docs/security.md, "File previews"
  and "The artifact viewer".
- **Previews on phones stay within a phone's memory.** A small device (the browser reports 4 GB or less; Safari and
  Firefox: a touch screen under 768 pixels on its short side) previews with smaller caps — a Word part 1.5 MB, a
  workbook's sheets 8 MB, a slide 4 MB, notebooks 5 MB, PDFs 10 MB, pictures 25 million pixels — measured to keep a
  reader near 200 MB (a unit test runs each one under a 256 MB heap); above them the preview says it is limited on
  this device and offers Download. A formula's `position` is only `relative` or `absolute`, and each of its boxes
  clips what it paints: a negative `\kern` or `\raisebox` cannot move its text over the words around it.
- **The Code page frames bedrock-now's hosts on the portal's port only.** Its `frame-src` allowed the terminal host
  and the previews' site on any port (`http://<TERMINAL_HOST>:*`, `http://*.<PREVIEW_DOMAIN>:*`); those names resolve
  to this computer's loopback, so a framed page of sandbox content could navigate its frame to any service listening
  there (a blind GET). Now `:<PORTAL_PORT>` (the remote sites' `https://` sources are unchanged).

## [0.6.0] - 2026-10-16

### Added

- **Previews of files on the Code page.** Markdown (with **Preview / Source / Split**; Split follows unsaved edits,
  and a Markdown file shows the workspace images next to it, never web images), images (PNG, JPEG, GIF, WebP, AVIF,
  BMP, ICO), SVG (as an image only), audio and video, PDF (pdf.js 6.4.299, legacy build: pages, selectable text,
  find, zoom, page jumps; web links open in a new tab; a PDF's JavaScript, forms and launch actions never run), CSV
  and TSV (a table: header detection, sort, filter, resizable columns), JSON, JSON Lines and YAML (a collapsible tree; notebooks as JSON
  for now) open in Preview; what a file is comes from its first bytes, not its name (the file read now returns a
  binary file's first 64 bytes). Parsing runs in workers the page stops on a time budget; pdf.js and the viewers load
  on first use. Limits are stated in the page and the README (25 MB at most; images ≤ 100 million pixels; tables ≤
  1,000,000 rows, 200 columns, 5,000,000 cells; trees ≤ 300,000 values); above them, Download. Claude's Write/Edit
  cards offer **Preview**. Word, Excel, PowerPoint, HTML and Mermaid previews come later (Download meanwhile).
  New pinned dependencies of `code/web`: `pdfjs-dist` 6.4.299, `papaparse` 5.7.0, `yaml` 2.9.1 (its optional native
  `@napi-rs/canvas` is replaced by an empty local package: no native binary is downloaded).
- **Previews of dev servers in the Code page** (local only for now): a web server running in the sandbox shows in a
  tab beside the chat (*chat | preview*) with reload, an address field, desktop / tablet / phone sizes and **Open in
  a new tab** (a new tab on a phone). **Preview :5173** chips on commands whose output names a `localhost` address,
  `localhost` links in Claude's answers opening the preview, a toast when a new server listens, and **Ports** in the
  status bar (⋯ → *Ports & previews* on a phone): the sandbox's listening servers with their process, Preview, Stop,
  any other port, and the entries of the workspace's `.claude/launch.json` (the Claude Code desktop app's format) with
  **Start** (shown in full first — every argument, the folder, every variable with its value, a warning on those that
  run code before the command — then in a new window of the terminal, `PORT` set; refused when the file changed after
  you looked; its preview opens once it listens). Hot reload works (Vite,
  Next, webpack: their host and origin checks see `localhost:<port>`). Each preview is on a site of its own,
  `p<port>-<capability>.<PREVIEW_DOMAIN>` (`bedrock-now-preview.localhost`, derived from `PORTAL_HOST`): no
  bedrock-now cookie reaches it, its requests to the other hosts are cross-site (`./stack` now refuses a `PORTAL_HOST`
  or app host on a `*-preview.localhost` site, and a project named `<x>-preview` gets `<x>-preview-portal.localhost`),
  and the capability — minted by the
  portal for the Code page's unlock — names one port and ends with that unlock, Sign out or a new password. The path:
  the main Caddy (`caddy/preview-on.caddy`, the portal's check on every request) → the terminal's gateway (`:7682`,
  a secret header of its own, `PREVIEW_PROXY_SECRET`) → `bn-preview` in the sandbox (`terminal/bin/bn-preview.mjs`,
  an HTTP/WebSocket proxy on a UNIX socket, the `preview-socket` volume) → `127.0.0.1:<port>`. New bn-coded ops
  `ports.list`, `ports.stop`, `launch.list`, `launch.start`; `./stack test` checks the chain; the e2e suite checks a
  real preview (an HTTP + WebSocket echo server, isolation from inside the preview, refused capabilities, a Vite hot
  update). docs/security.md: "Previews of dev servers in the sandbox". The terminal container gets one more volume
  (bn-preview's socket; always there, like bn-coded's), so the next `./stack update` recreates it as it does for a new
  image anyway.
- **Permission modes like Claude Code's desktop app** in the Code page: a mode picker next to **Send** (`Shift+Tab`
  cycles *Manual → Accept edits → Plan* as the CLI does, `Alt+M` opens it) with the desktop app's names and Claude
  Code's own modes underneath — *Plan*, *Manual* (formerly *Ask*), *Accept edits* — and one of bedrock-now's own,
  **Read only** (Claude Code's `dontAsk` with Edit, Write and NotebookEdit denied: reads and read-only commands run,
  anything else is denied without a card; it replaces *Don't ask*). *Read only*, *Manual* and *Accept edits* are
  remembered for new sessions; *Plan* (and *Bypass*) apply to one session only. A mode's rules go to Claude Code's
  flag-settings layer as one composed `permissions` object, never fewer rules than either mode needs mid-switch.
- **Bypass permissions** (opt-in): **Settings → Code page → Allow Bypass permissions** (`CODE_ALLOW_BYPASS`, on only
  from the computer running bedrock-now; the code container restarts) adds it to the picker. Every switch to it asks
  in a dialog naming the risks here (your real workspace folder — its git hooks, package scripts and editor settings
  run on your computer later —, the sandbox's internet access, the budget); while it is on a red strip sits above the
  prompt box, the tab title starts with ⏵⏵ and the portal's Code badge turns red; it ends with the session's process
  (a resumed or restarted session goes on in *Manual*; new ones start in your usual mode, never in Bypass); over remote
  access it works too once allowed, and the dialog says so. Claude's file tools still ask before changing `.git`,
  `.claude`, `.vscode`, `.husky`, `.devcontainer`, `.envrc` and `.mcp.json` (shell commands do not: the watchlist flags
  those), deny rules still deny; Claude Code switching to Bypass or Auto by itself is undone and said. Sessions start with `--allow-dangerously-skip-permissions` only while
  it is allowed (never in bypass); the code container refuses the switch without the setting and the page's
  confirmation.
- **A watchlist of files that run on your computer**, in every mode: git's own files (hooks, `core.hooksPath` folders
  such as husky's `.husky/_`, `.git/config` and its includes, a `core.fsmonitor` program, a `.git` file and its
  gitdir, submodules), husky hooks and pre-commit/lefthook/lint-staged configuration, `.envrc`, VS Code tasks,
  settings and `*.code-workspace` files, `.claude/settings*.json`, `.mcp.json`, `package.json` (install scripts and
  hook tools' keys; every script once a git hook here runs package scripts), `.npmrc`, `.yarnrc.yml`, `.pnpmfile.cjs`
  and dev container files are hashed (with a copy up to 1 MiB, 2 MiB in all) when a turn starts and ends; a change — by
  an edit, by Bash, or between turns — shows a card with why it matters, the diff and **Revert** (only while the file
  is still as the turn left it; a new file goes to the workspace trash). Every `core.hooksPath` and `core.fsmonitor`
  value counts (up to 4 each: which one git applies can depend on an `includeIf`); includes are followed 16 deep in
  all; more than it lists (256 entries) is said on the cards, never cut silently.

### Changed

- **The Code page's CSP** (`caddy/Caddyfile`, `code_page`) allows one Trusted Types policy, `trusted-types
  bn-worker` (was `'none'`): it turns exactly the build's own worker scripts into script URLs and nothing else, and a
  second policy is refused. It also allows audio and video from `blob:` (`media-src blob:`), and frames from the
  dev-server previews' hosts (`frame-src` gains `http://*.<PREVIEW_DOMAIN>:*`). See
  [docs/security.md](docs/security.md#the-code-page).
- **`claude-bedrock` turns Claude Code's auto mode off** in its lean folder's sessions
  (`--settings={"disableAutoMode":"disable"}`, Claude Code's flag tier; nothing of yours is written), as the browser
  terminal and the Code page do: its classifier would run on your session's model behind this stack and block what it
  cannot judge. `CLAUDE_BEDROCK_AUTO_MODE=1` leaves it to Claude Code; with `CLAUDE_BEDROCK_USE_MY_CONFIG=1` your own
  settings decide. `CLAUDE_BEDROCK_MODEL=haiku` (`sonnet`, `opus`) is passed as that slot's full id — with the alias,
  Claude Code 2.1.296 plans on Sonnet in *Plan* mode (probed: with the full id, Plan stays on Haiku) — in the browser
  terminal's `claude-bedrock` too.
- The Code page's plan approval says *Approve, Manual* / *Approve, Accept edits*. Read only also denies EnterPlanMode
  (Claude cannot leave it for Plan). Over remote access the Bypass dialog says so (Caddy's remote sites tell the code
  container, `X-Bn-Remote`). Mode switches run one at a time in the backend (and the page sends the last one
  pressed next); a refused one is taken back in the page, and what Claude Code reports meanwhile is reconciled after
  the last one.

### Fixed

- The Code page showed the mode of a session's last turn start after a reload instead of the mode it is in now.
- A model switch in the Code page could fail silently: Claude Code 2.1.296 checks an id it is not offering with a
  one-token request that must answer within 5 s ("Couldn't confirm model …"), which a cold LiteLLM → Bedrock path can
  miss, while the page already showed the new model. The model now goes into the session's own `/model` picker first
  (no check request), a failed check is tried once more, and a refused switch is taken back in the page ("Still on …").
- LiteLLM's own Logout in the Admin tab sometimes signed you straight back in instead of showing its form.
  LiteLLM's UI learns where its Logout goes (`PROXY_LOGOUT_URL`, `?sso=off`) from a settings request it makes after the
  page loads; a Logout before that answer (right after opening Admin, or with LiteLLM busy) reloads the page it is on,
  and that load, now without LiteLLM's session, got a new automatic sign-in. The portal now sends a load by LiteLLM's
  own page that has no LiteLLM session but the portal's sign-in marker (right after its Logout) to LiteLLM's form;
  opening Admin again (a reload of the portal page, the pop-out, a link) signs you in as before. The e2e suite's
  `browser/admin-litellm-ui` failed now and then on this; `browser/admin-litellm-logout-early` covers that path on
  every run.

## [0.5.0] - 2026-10-16

### Added

- **The Code page** (optional, off by default): `./stack code enable` adds a **Code** tab directly under Chat (on a
  phone under More, full screen) with Claude Code as a chat — streamed answers, tool calls, permission prompts (*Allow
  once*, *Always* with the rule shown — saved in the sandbox's own settings, a rule in the workspace's `.claude` files
  only through a button of its own that says Claude Code on your computer honours it too — *Deny*; approving a plan in
  *Plan* mode with *Accept edits* or *Ask*; a card shown only in part can only be denied, which the backend enforces,
  and *Always* applies at most the 50 rules a card lists; a new card never takes the focus from the prompt box, the
  editor or the terminal panel, and its 1/2/3 keys answer only once you click or tab into it; a badge on the tab while
  one waits — in a browser that has used the Code page also before the tab is opened (only then does the portal load
  it, hidden); denied after 30 minutes without an answer, and at once beyond 8 waiting per session or 32 in all),
  model, permission mode and effort switches, Stop, slash commands (`/clear` starts a new session with the same
  settings), sessions that keep working with the tab closed (a reload re-attaches; idle ones stop after 30 minutes and
  resume on the next prompt; at most 4 at once), resume and fork from the list or fork from any of your messages, and
  the workspace's files (tree, read, edit with a "changed on disk" check, upload, download). It runs Claude Code in
  the browser terminal's sandbox — same container, workspace, key (`claude-code-terminal`) and budget — so `enable`
  turns the terminal on when it is off (`--workspace DIR` as there) and `./stack terminal disable` turns it off too;
  `./stack code disable` keeps the terminal. Neither restarts a running terminal (its tmux session goes on): the spawn
  server always runs there, idle until the Code page connects. The page comes from a new `code` container (Node; the
  TypeScript Agent SDK 0.3.296, pinned in lock-step with the terminal's Claude Code 2.1.296) that holds no LiteLLM
  key, mounts no folder of yours and shares one internal network with Caddy only: Claude Code is started in the
  sandbox by a small spawn server (`terminal/bin/bn-coded.mjs`, Node built-ins only, an argument allowlist) on a
  socket only the two containers share, and files, sessions and plugins go through it too; everything coming back is
  treated as untrusted (capped, every id checked, rendered as text), and a sandbox that stops reading its input is cut
  off once 32 MiB wait for it. Its host needs the portal session and a password unlock of its own, which also opens
  its terminal panel (the terminal's own unlock never opens the Code page): a one-time, one-minute hand-off to the
  terminal's host (`/.bn/terminal` → `/.bn/unlock-callback`) that ends with the Code page's unlock (Sign out, a new
  password, 12 hours); its connections are re-checked at least every 2 hours. The main Caddy sets its page policy (a
  strict CSP with a per-request style nonce and Trusted Types) whoever answers. Models with this stack's prices and
  each session's cost (LiteLLM's spend logs, the terminal key's rows) come from the portal (`/.bn/models`,
  `/.bn/spend`). A new session or a model switch makes the next turn write that model's prompt cache again (~30k
  tokens: about $0.004 on Haiku 5.5, $0.08 on Sonnet 5.5, $0.16 on Opus 5.5); the model list says so. Remote access
  follows the terminal's `REMOTE_TERMINAL` (a sixth Tailscale Service, or `code.<your domain>`). Home's Claude Code
  card and the walkthrough mention the Code tab. `./stack test` checks it (health, the unlock, other Origins, the
  secret header, a round trip to the spawn server, isolation of both sides); the e2e suite gains `--code`; the unit
  tests (frontend and backend) run in its image's test stage (`code/test.sh`). How it is built and what it trusts:
  README › The Code page, docs/security.md › The Code page.
- **The Code page's frontend** (`code/web`: TypeScript, Preact, CodeMirror 6, marked's lexer; bundled by esbuild into
  the image, every dependency pinned; nothing from a CDN; runs under the CSP with Trusted Types): an IDE-like layout —
  explorer, editor tabs, chat, the sandbox's terminal in a bottom panel — that becomes chat + one pane on a tablet and
  chat-first with sheets on a phone, sizes remembered per browser. Markdown rendered as DOM (raw HTML stays text,
  only http(s) links), tool cards (Bash output, Edit/Write diffs, nested subagents, MCP tools, to-dos), background
  tasks with a Stop each, permission cards that say what would run or change, a `/` palette (commands, skills,
  plugin commands) and `@` file picker, image paste/drop, uploads into the workspace, the editor with a "changed on
  disk" check and Claude's edits as side-by-side diffs, session search/resume/fork/rename, each turn's cost and the
  context meter, and re-attach after a reload or a dropped connection without duplicates. A mock backend
  (`npm run dev`) and browser checks against it (`code/web/e2e/run.sh`: desktop light/dark, tablet, phone, a hostile
  sandbox) come with it.
- **AskUserQuestion in the Code page**: Claude's questions show as a small form (one choice, several, or *Other* with
  your own words) and the answers go back to Claude as answers (the SDK's own channel), not as a refusal.
- **Plugins & marketplaces in the Code page** (⋯ menu): installed plugins (on/off, update, uninstall; built-in ones
  read-only), the added marketplaces' catalog (search, install) and the marketplaces (add `owner/repo`, an https URL
  or a folder of the workspace; update; remove). A plugin whose marketplace installs it by running a command is
  shown with that exact command and its SHA-256 first and runs only after **Run this command and install**
  (`claude plugin install --accept-command <sha256>`; never `-y`). Open sessions reload their plugins after a
  change, so new commands and skills appear in the palette at once.
- **MCP servers in the Code page** (⋯ menu): each server's status, tools and errors, reconnect, off/on for the
  session; servers of your own (stdio, HTTP, SSE) added to or removed from the sandbox's user configuration — a stdio
  server's command runs inside the sandbox only — and a *Restart this session* to load them.
- **More of the terminal in the Code page**: plan approval (approve and accept edits, approve and keep asking, or keep
  planning with a note), fork before any of your prompts (as the terminal's rewind: the prompt comes back to the box
  to change), file checkpoints (*Restore files to here*, with a dry run first; also after the session's process ended,
  never while Claude works, checked again if Claude worked since), the memory editor for `CLAUDE.md` (workspace and
  your own in the sandbox) and a shortcut of the page's own (a one-line `# …` prompt is added to the workspace's
  `CLAUDE.md` instead of being sent), an `@` picker that searches the whole workspace (build and dependency folders
  skipped), a pinned to-do list, export as Markdown (the whole transcript), opt-in notifications, prompts queued while
  Claude works, `/clear`/`/new`/`/reset` (a new session with the same settings) and `/resume`.
- **Settings → Code page**: turn the Code page on (only from the computer running bedrock-now; with the browser
  terminal off it turns the terminal on too, with the folder it names before you confirm, checked first by the
  terminal's rules, and off again if the change fails) or off (from anywhere); the update helper runs `./stack code
  enable` / `disable`. The workspace is shown read-only with the command that changes it. The walkthrough's Claude
  Code steps point at the Code tab when it is on, and at Settings when it is not.

### Changed

- **Claude Code's auto mode is off in the sandbox**: Claude Code 2.1.283+ counts auto mode (a classifier model
  approving actions) as available behind bedrock-now's own API address, so the browser terminal's `claude` could
  start in it and the Code page's *Plan* mode handed writing commands to the classifier instead of asking (and blocked
  them when it failed). The terminal image's managed settings (`/etc/claude-code/managed-settings.json`) and the Code
  page (at every session's start) turn it off: both start in the ordinary asking mode again.
- **The Code page runs exactly the model you pick**: it names models in full (`claude-haiku-5-5`, not `haiku`) for new
  sessions, switches, resume, fork and a typed `/model haiku` (switched by the page), and the code backend refuses
  Claude Code's aliases — with the alias `haiku`, Claude Code 2.1.296 planned on Sonnet in *Plan* mode (~$0.08 an
  uncached turn). A turn Claude Code ran on another model than the one picked says so on its line.

## [0.4.1] - 2026-10-15

### Added

- **One sign-in for every app.** Admin (LiteLLM's UI) and Files (RustFS's console) now open already signed in — in
  their tabs, pop-out windows, on the remote site and in a phone's new tab — so the portal password is the only one
  you type. The portal signs in to each app for you with the sign-in it already holds and hands the app's own session
  to your browser on that app's address, never in a URL: LiteLLM's session cookie (from its own sign-in call; Caddy
  keeps it from LiteLLM itself, which would also take it as a credential on its MCP OAuth/BYOK routes), or 12-hour
  RustFS console credentials (from STS, stored where the console keeps them, made only when the browser has none from
  this portal session and key pair). Caddy's check decides when (page loads only; Admin when it has no LiteLLM session
  from this portal session and these credentials, Files on each console page load) and routes `/.bn/sso` on the Admin
  and Files hosts to the portal, which answers only page loads from this site in browsers that say so (`Sec-Fetch-*`),
  at most 20 sign-ins a minute per portal session. It keeps working after a new LiteLLM password or a regenerated
  RustFS pair in Settings. **Sign out** (also *Sign out other devices*, a new `PORTAL_PASSWORD`, and Sign out from a
  session that ended meanwhile) deletes every LiteLLM UI session of the Admin user made before it, retried until
  LiteLLM has done it, across restarts too; LiteLLM now also deletes expired UI session keys daily
  (`LITELLM_EXPIRED_UI_SESSION_KEY_CLEANUP_ENABLED`). Admin and Files page loads are never taken from the browser's
  cache without the portal's check (LiteLLM sends no `Cache-Control`), and every stored file on the Files host is
  inert (`Content-Security-Policy: sandbox`, `nosniff`): it shares an origin with the console's credentials. The
  shared MCP server stores HTML, SVG and XML files as plain text. The apps' own forms stay as a fallback: Home's card
  is now "Admin and Files sign you in automatically", with the credentials folded under *Credentials (for the API or
  if automatic sign-in fails)* plus a link to each app's own form (`?sso=off`); an app's own Logout shows its form
  (LiteLLM: `PROXY_LOGOUT_URL`). When automatic sign-in cannot work (an app down, a password changed inside LiteLLM, a
  redirect loop), the page says why and links the form. The walkthrough's second section is now *Your apps (one
  sign-in)*: the portal step says its password is the only one, and Chat, Admin and Files say "Automatic", tick off
  when the app opens and keep their own sign-ins in the same Credentials fold as Home; its Claude Code steps now
  describe the lean `~/.claude-bedrock` folder (plugins and MCP servers added one by one,
  `CLAUDE_BEDROCK_USE_MY_CONFIG=1`) and the `resume: claude-bedrock --resume <id>` exit line. How it works and what it
  trusts: docs/security.md › Automatic sign-in to Admin and Files. OIDC was considered and not used: LiteLLM's needs
  an Enterprise license beyond five users, and RustFS's puts its credentials in the URL.

### Changed

- **`claude-bedrock` no longer loads your `~/.claude` plugins, hooks and MCP servers by default.** It runs Claude
  Code with its own config folder, `CLAUDE_CONFIG_DIR=~/.claude-bedrock` (created on first use, mode 700): Claude
  Code's own tools, the stack's `bedrock-shared` MCP server, and the working folder's own `.mcp.json`,
  `.claude/settings.json` and `CLAUDE.md`. Bedrock takes no Anthropic beta headers and Claude Code's tool search
  needs one, so every tool definition goes into every request, billed per token. Measured on Haiku with a one-line
  `-p "Reply with just: ok"`: a well-stocked `~/.claude` made 5 requests of 258K–340K input tokens each ($0.094);
  `--strict-mcp-config` alone made 13 requests of 5K–63K each plus two of 353K from hooks ($0.112, no cheaper: hooks,
  skills and agents still load); an empty config folder made 1 request of 25K tokens ($0.001) — about 100× cheaper.
  With the full setup one real Opus request cost $1.44, and every interactive launch made 4 requests ($0.13) before
  anything was typed (plugins' Agent SDK calls). In lean mode a launch makes no model request until you type.
  - The launch line says which config is used: `config: lean (~/.claude-bedrock) — your ~/.claude plugins, hooks
    and MCP servers are not loaded; CLAUDE_BEDROCK_USE_MY_CONFIG=1 loads them (that can cost about 100× more per
    prompt)`, and `--help` has a `Config` line. At a terminal, a new folder adds that Claude Code asks its first-run
    questions once more.
  - **`CLAUDE_BEDROCK_USE_MY_CONFIG=1`** uses your `~/.claude` (or the `CLAUDE_CONFIG_DIR` you exported) as before,
    with a ⚠ on the launch line ("… which can cost about 100× more per prompt"). **`CLAUDE_BEDROCK_CONFIG_DIR`**
    picks another lean folder: an absolute path, not `/` or your home folder in any spelling; one that is, or links
    to, one of your own folders gets the opt-in's warning. An existing lean folder must be owned by you, writable and
    not writable by group or others, or the wrapper stops with the fix (e.g. a `~/.claude-bedrock` made by
    `sudo claude-bedrock`). A `CLAUDE_CONFIG_DIR` exported for plain `claude` is not used in lean mode. Without
    `HOME`, the account's home folder is used and `--help` still works.
  - Subcommands manage the same folder: `claude-bedrock mcp add …`, `claude-bedrock plugin install …`. Once, at a
    terminal, if you have a `~/.claude/CLAUDE.md` and the lean folder has none, the wrapper says how to link or copy
    it; it never copies it (it may hold things you don't want sent to Bedrock). Settings, keybindings, status line,
    output style and your own commands/agents/skills are separate now; README › Claude Code says what to copy and
    what not.
  - **Resume:** sessions are kept in `~/.claude-bedrock`, so Claude Code's own exit hint (`claude --resume <id>`)
    doesn't find them. A new interactive session gets its id from the wrapper (`--session-id`), and when it ends the
    wrapper prints `resume: claude-bedrock --resume <id>`, before the session cost; after `/clear` (`/new`,
    `/reset`) or an in-session `/resume` it adds "(after /clear or /resume: claude-bedrock --resume to pick)". After
    `--continue` or the picker it names the one session written in that folder (or its `claude -w` worktrees) during
    the run, or suggests the picker when there were several. No line for `-p`, `--bg`, `--cloud`/`--remote`, with
    `CLAUDE_BEDROCK_QUIET=1` or without a terminal.
  - `ENABLE_TOOL_SEARCH=true` is no longer set (here and in the browser terminal): with the beta headers off it
    changed nothing — checked with Claude Code 2.1.301, an MCP server's 40 tools were all in the request either way.
  - The browser terminal is otherwise unchanged: its Claude Code already has its own config (`~/.claude` in the
    `terminal-home` volume); its `--help` now says so. `./stack uninstall` mentions that `~/.claude-bedrock` (and a
    `CLAUDE_BEDROCK_CONFIG_DIR` folder) is kept.
  - `./stack uninstall` names a claude-bedrock folder only as the wrapper resolves it in lean mode, never `~/.claude`
    or your home folder.
  - Tests: `tests/run.sh` fails if the suite creates `~/.claude-bedrock` in your real home folder. e2e:
    `claude/claude-bedrock` runs with a fresh `CLAUDE_BEDROCK_CONFIG_DIR` (was `CLAUDE_CONFIG_DIR`, which the
    wrapper now ignores) and checks the `config: lean` line and the folder's mode.

### Fixed

- `claude-bedrock -- "a prompt"` (and the browser terminal's `claude-bedrock`) lost the shared MCP server: its
  `--mcp-config` was appended after your arguments, so after a `--` it became part of the prompt. It now comes first,
  as one `--mcp-config=<file>` argument (two arguments there would let the option take your prompt for a config file).

## [0.4.0] - 2026-10-14

### Added

- **OpenRouter by pasting a key into `.env`.** Setup now adds an empty, commented `OPENROUTER_API_KEY=` line to
  `.env` when it has none ("paste a key from https://openrouter.ai/settings/keys after the =, then run
  ./stack openrouter apply"; new installs get it from `.env.example`). It is added once and never changes the
  value of an existing line, also a hand-made one: it only rewrites a quoted, spaced or commented key line
  cleanly (the same key, as Compose reads it), and on an older install it inserts the hint comment above the empty
  `OPENROUTER_API_KEY=` line that `.env.example` gave it. An empty key keeps OpenRouter off everywhere. **`./stack openrouter
  apply`** uses that key: it refuses an empty one ("paste your key after OPENROUTER_API_KEY= in .env first, or
  run ./stack openrouter set"), checks it with OpenRouter (a rejected key changes nothing), drops quotes or
  spaces pasted around it, then fetches the model list and applies it like `set`, also when the list did not
  change. `./stack openrouter remove` now empties the line instead of deleting it.
- **Free models for accounts without credits.** When `set`, `apply` or setup checks a key whose account cannot
  pay (OpenRouter's `is_free_tier`, the key's own credit limit used up, or a zero balance where the credits
  endpoint is readable) and `OPENROUTER_MODELS` is not set, it becomes `free`, in one line: "this OpenRouter
  account has no credits, so only free models are offered (OPENROUTER_MODELS=free); after buying credits:
  ./stack openrouter models all". It remembers that it chose this: once a later check finds the account can
  pay, paid models are offered again ("this OpenRouter account has credits now — …"), and `remove` clears it. A
  set you chose is kept, with one warning when it includes paid models (they fail with HTTP 402), plus where to
  fix free models' "No endpoints found matching your data policy". A used-up key limit that resets is only
  named. **`./stack update` runs setup**, so an existing install with a free-tier key and a blank
  `OPENROUTER_MODELS` switches to free models; `./stack openrouter models all` undoes it.
- README › Optional: OpenRouter: how to set up the OpenRouter account (key, privacy settings, *Filter the model
  catalog for API keys*, no OpenRouter logging needed) and what the common errors mean (404 data policy, 429
  free-model limits, 402 credits, 401).
- **Walkthrough in the portal.** A **Walkthrough** button at the bottom of the sidebar takes someone who has
  never used the apps through all of bedrock-now, in three sections: *Set up* (the Bedrock models your AWS key
  can use and how to get more, optional OpenRouter — key, free models, privacy settings, where to watch it —,
  voice, Claude Code, budgets, extras), *Sign in to each app* (portal and Chat automatic; Admin's and Files' own
  sign-ins shown with Copy buttons, passwords never displayed) and *Use it together* (Home, a chat and its cost
  line, voice, documents and knowledge, Claude Code writing to the shared store and Chat answering from it,
  Admin's keys, usage and logs). Steps show live status from `/api/summary` (polled at most every 30 s, only
  while a step needs it) and tick off by themselves where the portal can tell; the rest have Mark as done or
  Skip. It opens by itself on a first visit: on desktops as a section of the sidebar, which widens to 340 px so
  the app frames get narrower instead of covered; on tablets as a card next to the icon rail; on phones it stays
  closed (it would cover Chat) and opens from **More** as a sheet above the tab bar, where Admin and Files open
  in a new tab. On tablets and phones the card or sheet steps aside when a step opens an app or a card on Home.
  Progress is a per-browser convenience in `localStorage` (`bn.tour`); when the browser blocks storage it does
  not open by itself (it would on every load), and the button still opens it. New files
  `portal/portal/static/tour.js` and `tour.css`; everything is built with DOM nodes (no HTML parsing).
- **Actual and Equivalent cost views on Home** (only while OpenRouter is on; Bedrock-only installs see no
  change). Free OpenRouter models cost $0, so using them never looks like money being spent: **Actual** (the
  default) is what you are charged — Bedrock at its on-demand list prices, paid OpenRouter models at their prices,
  free models $0 — and budgets always count it. **Equivalent** prices each free model (`…:free`) at its paid
  version (the same id without `:free`, from the cached OpenRouter list, enabled or not; cache reads at its
  cache-read price), so you can see what the same usage would have cost; a free model without a paid version stays
  $0 and is named. A two-button switch on the Spend card (remembered per browser as `bn.costView`) changes the
  30-day total and each key's amount, with a line like "of which $0.84 is free-model usage you paid $0 for"; the
  budget bars keep showing actual spend (a key reads "≈ $12.00 equivalent · $6.00 of $10.00 actual"). The portal
  reads per-model tokens from LiteLLM 1.105.0's `GET /user/daily/activity/aggregated` (master key; one request
  for the widest window needed, cached for a minute; per key through its hashed-key breakdown, from the first
  UTC day of its budget period); when LiteLLM cannot answer, Equivalent says so and Actual is unchanged.
  `/api/summary` gains `spend.equivalent` (`total_30d`, `extra_30d`, free requests and tokens, per-key
  `spend`/`extra`/free counts, `no_paid_variant`, `error`; `null` while OpenRouter is off) and each key row a
  `period_start`.
- **OpenRouter usage and failures on Home**, under the OpenRouter account line: the key's free-model requests
  today against OpenRouter's daily limit as a gauge (OpenRouter counts per UTC day; amber from 80%), requests and
  tokens to `or/…` models today and in the last 30 days split free / paid with their cost (in Equivalent also what
  the free ones would have cost), the five most used models, and the last 24 hours' failed `or/…` requests from
  LiteLLM's logs (`GET /spend/logs/v2?status_filter=failure`, cached for a minute), grouped by cause with a
  one-line fix: daily free limit reached, the model busy upstream (HTTP 429 "…temporarily rate-limited upstream":
  its provider throttles everyone — retry, another free model, or the free router `or/openrouter/free`), this
  key's own rate limit, no credits (HTTP 402), privacy settings that exclude free endpoints (HTTP 404 "No
  endpoints found matching your data policy"), a rejected key (HTTP 401), a used-up key budget, or the status and
  the provider's message (keys, AWS access keys, ARNs, account ids, key hashes and emails masked). In
  `/api/summary` as `spend.openrouter_usage` (`null` while OpenRouter is off). Failed requests' prompt-token
  estimates are counted only in proportion to answered requests, so bursts of refusals do not inflate tokens or
  Equivalent. If anything in these views fails, they say "usage view failed (…)" and Actual is unchanged. Phone
  layout included.
- `./stack costs` and `./stack openrouter status` print OpenRouter usage through LiteLLM: free and paid requests
  and tokens in the last 30 days (free as "$0 actual (≈ $… at paid rates)") and today's requests.
- **Settings tab** (the gear after Files; on phones under More): every value of `.env`, grouped as Account &
  security · AWS & models · Budgets & alerts · Voice · OpenRouter · Files · Updates & backups · Remote access ·
  Diagnostics · Advanced, with secrets masked (*set*, at most a short hint). It changes the portal password (this
  browser stays signed in through a carry-over cookie, every other device is signed out), the owner email (moved
  in Open WebUI and LiteLLM first, so the same Chat account keeps its chats; a stray empty `pending` account is
  removed), the Admin (LiteLLM) password (changed in LiteLLM itself: a bare `.env` edit never did anything), the
  AWS access key (STS and a free Bedrock check first; a failed smoke test puts the old key back), the three
  budgets (at once, no restart), the budget alert webhook, storing prompts, speech-to-text, OpenRouter, the daily
  release and price checks, automatic updates and their hour, signed releases (on only), `REMOTE_ADMIN_ACTIONS`
  and the allowed Tailscale login. Each field says what a change restarts and for how long; each change asks for
  the portal password and is carried out by the update helper, with live progress that survives the portal's
  own restart. Also: **Sign out other devices** / **Sign out everywhere**, **Check AWS key** (free), **Re-check
  models** (< $0.01, at most hourly), **Back up now**, Reveal/Copy for the Admin and Files sign-ins, the three
  LiteLLM keys and the MCP token (password again), a link to Chat's model visibility settings, and **Diagnostics**:
  the smoke test (~$0.0001), a restart of one service, a status report to copy (home folder as `~`, secrets
  scrubbed). Every other key is listed read-only under Advanced with its reason and the command that changes it.
  Without the helper the page is read-only and shows the terminal command per field; Home says "Settings changed:
  … at …" for a day.
- **`./stack config`**: `list` (grouped like the page, secrets masked), `get KEY` (plain keys only), `set KEY…`
  (asks; hidden and twice for secrets; never a value on the command line), `apply --stdin` (what the helper runs),
  `check-aws` (free), `report`. One pipeline for both: lock, validation (`catalog/settings.tsv` names each key's
  group, policy and validator), the `.env` hash the page loaded, live checks, the old values kept, LiteLLM/Open WebUI
  first, one atomic `.env` write (`set_env_batch`), only the restarts the change needs, free checks of the result,
  and on failure the previous values back. Each change is logged by key name only in
  `.state/helper/settings-audit.log`. **`./stack restart SERVICE`** recreates one service.
- **More in Settings**: **Regenerate** the Files (RustFS) key pair (stored files, IAM users and service accounts
  stay; Files, Chat, shared-mcp and the portal restart together) or the shared MCP token (`.state/mcp.json` is
  rewritten); **model pins** for Chat's default and title/tag models and Claude Code's three slots
  (`CHAT_DEFAULT_MODEL`, `CHAT_TASK_MODEL`, `CLAUDE_MODEL_OPUS|SONNET|HAIKU`; blank = automatic, setup keeps a pin
  while the model is enabled and warns when it is not); **hidden models** in Chat's picker (`MODELS_HIDDEN`; the API
  and Claude Code can still use them; models you hid in Chat yourself stay hidden); the **alert threshold**
  (`BUDGET_ALERT_PCT`, 50-99%, replacing the fixed 80% of soft budgets, `./stack costs`, Chat's banner and Home's
  meters); the **session length** (`PORTAL_SESSION_DAYS`, 1-90 days); **nightly backups** (`BACKUP_NIGHTLY`,
  `BACKUP_HOUR`, `BACKUP_KEEP`: run by the update helper in its window like automatic updates, `./stack backup
  --nightly`, pruning only `-nightly` backups) and the **backup list** (`.state/status/backups.json`: names, kinds,
  sizes, dates, and which one a rollback needs). `./stack config regenerate rustfs|mcp-token`.
- `./stack up`, setup and `./stack restore` reconcile Chat's owner account and the Admin (LiteLLM) sign-in with
  `.env` (a change cut short, an older backup restored), and `./stack up` applies `BUDGET_*` edited by hand.

- **Automatic updates, off by default.** Home → Maintenance has *Automatic updates: Off | Nightly (03:00–06:00)*
  (segmented like the model filter, asks for the portal password; a new request action `auto-on` / `auto-off`
  that the helper validates like the others and carries out as `./stack helper auto on|off`; its result is
  reported with the switch, never in place of the last job), and the CLI has `./stack helper auto on [--hour N] |
  off | status` (`AUTO_UPDATE` / `AUTO_UPDATE_HOUR` in `.env`). When on, the update helper runs the same
  `./stack update --yes` as Update now (backup first) for a new **release** in the window `[N:00, N+3:00)` of this
  computer's clock, within its own limits: only when the checkout is detached at a release (never a branch), the
  last update finished, the stack runs, the portal's daily check names a release newer than the installed one, and
  that release is the newest tag of origin after fetching it. The helper reads the portal's `latest.txt` only inside
  the window, once per window, through a read that cannot block (`O_NONBLOCK | O_NOFOLLOW`, regular files only).
  Each release is tried once: a failed or interrupted release, and one you rolled back (also with `./stack
  rollback` in a terminal, which now records the version it left), is not installed again automatically; Update
  now still works and a newer release is tried as usual. An update that did not finish holds automatic updates back
  until Update now finishes it or Roll back goes back. A busy stack (a job, a terminal `./stack` command), local
  changes or no network skip that night, and Home says why. While an update or rollback runs the helper keeps the
  computer from sleeping (`caffeinate` / `systemd-inhibit`); a computer already asleep when the window starts tries
  the next night instead of updating when it wakes. A job the helper finds unfinished when it starts (the computer
  or the helper stopped) is marked as interrupted, and the helper restarts with the new code after a `./stack
  update` in a terminal. Home shows the result as "Updated automatically to vX.Y.Z at 03:04", the failure with
  **Roll back** right in the progress card, or "Automatic update skipped" when it could not start; the update card
  says "Will install automatically tonight between 03:00 and 06:00 (this computer's time) — or Update now". The
  heartbeat (`.state/status/helper.json`) gains `auto` (switch, hour, state, reason, next window, last attempt, the
  release rolled back, the last skipped window, the last switch change) and `rollback.unfinished`; the job status
  gains `trigger` and the final phase `skipped`. It costs less than before: the checkout's facts are cached and
  the heartbeat runs in bash. `./stack status` and `./stack helper status` show how updates happen on this install.
- **Home without the helper:** instead of only the terminal command, "One-click updates are off" with
  `./stack helper install`, a Copy button and why it needs a terminal once (in the update card while an update is
  available, else in Maintenance; "the update helper is not running" when it was installed but stopped). Remote
  viewers keep the remote-access wording.
- **The installed version, always visible:** a small label under **bedrock-now** in the sidebar (a tiny label on
  the tablet icon rail, with the full version in the logo's tooltip; in Home's header on phones). A build after a
  release reads `v0.3.0 +7 (1a2b3c4)`, with the full `git describe`, branch and commit date in the tooltip. It
  links to that version's GitHub release (a build after a release: the changelog); while an update is available
  it shows an accent dot ("update available" in its tooltip and label) and opens the update card's release notes.
  `/api/summary`'s `update` gains `commit`, `commit_date` and `release_url` (always there, also with the update
  check off or no network), and `.state/status/version.json` gains `commit_date` (written by `./stack setup` and
  `./stack up`).
- **Open in the app.** A browser tab of the portal now knows when the app is installed and offers **Open in
  the app** (sidebar, and a slimmer note on Home with *Not now*) instead of **Install app**; inside the app there
  is neither, and nothing shows until the page knows which (no flash). It knows from the browser
  (`navigator.getInstalledRelatedApps()`, trusted from Google Chrome and Microsoft Edge 140+ on desktop and
  Android, via a new `related_applications` entry naming the app itself), from a `bn.app` mark the app sets in
  the site's storage whenever it runs, and from `beforeinstallprompt`, which means "not installed" and clears the
  mark (so an uninstall brings **Install app** back). A tab left open catches up: it asks again when it comes back
  into view, follows the mark when the app is installed from another tab, and an app window turned into a tab
  ("Open in Chrome") offers the app again. The link opens the app through its own scheme (new manifest
  `protocol_handlers`: `web+bedrocknow` for the default copy, `web+bedrocknow` + 8 letters for every other copy
  and for the remote site, so copies never open each other's app; Home gets it as `<meta name="bn-app-scheme">`):
  the browser asks twice the first time, then the open window comes forward on the tab you were on (or the app
  starts there), answers the tab over a `BroadcastChannel`, and the tab says it can be closed. Without an answer
  the note lists the other ways in. Android has no such link, so there the note says where the app is. The
  walkthrough's Extras step follows suit. `portal/e2e/install/run.sh` checks it in a real Chromium: detection, a
  second tab switching to Open while the first installs, both permission prompts, the window switching tab, a cold
  start, and the install offer after an uninstall.
- **Claude Code in the browser (optional): `./stack terminal enable [--workspace DIR] | disable | status`.** A
  Terminal tab in the portal (on a phone: More → Terminal, full screen) runs `claude-bedrock` in a tmux session —
  same models, shared MCP server, launch line and session cost as on your computer — that survives reloads, closed
  tabs and dropped connections; `Ctrl-b c` opens a shell window. It has its own LiteLLM key, `claude-code-terminal`,
  with its own monthly budget (`BUDGET_TERMINAL`, $50; a meter on Home, a line in `./stack costs`), allowed only
  Claude Code's routes (`allowed_routes`: also where Docker Desktop lets the sandbox reach LiteLLM on your Mac's
  loopback, its Bedrock pass-through and OpenAI-style API answer 403). It is a sandbox,
  not a shell on your computer: a locally built container (`terminal/`: Debian trixie-slim with Node 24 pinned by
  digest, Claude Code 2.1.296 by version and SHA-512 through `npm ci`, ttyd 1.7.7 by SHA-256 for amd64/arm64, tmux,
  git, python/pip, ripgrep) running as your uid with no capabilities, a read-only image, no Docker socket and no
  published port, that sees only the workspace folder (default `~/bedrock-now-workspace`, created mode 700; your
  home folder, hidden folders such as `~/.ssh`, `~/Library`, system folders and the bedrock-now folder are refused
  in any spelling, and `/Volumes`, `/mnt`, `/media` themselves, at enable and at every later `./stack up`). Its
  only neighbour is its own gateway, a second minimal Caddy that passes LiteLLM's Anthropic API, model list and key
  info and the shared MCP server's `/mcp`, and answers 404 to the rest (LiteLLM's admin API, its Bedrock
  pass-through, any path with `.`/`..` segments or `//`); the gateway's other network holds only LiteLLM,
  shared-mcp and the main Caddy, and the main Caddy, the portal and Open WebUI share no network with the terminal.
  Out, the internet unless `TERMINAL_EGRESS=off`. Opening it takes the portal password
  again (a host-only, `HttpOnly`, `SameSite=Strict` unlock cookie for 12 hours, ended by Sign out, throttled with
  the login); its WebSocket accepts only its own `Origin` (checked by the portal, whatever the path's spelling, and
  by ttyd). ttyd listens on a UNIX socket only, shared with the gateway, which passes requests to it only with a
  secret header that only the main Caddy adds (new at every `./stack terminal enable`; never on a command line, in
  the sandbox or in the gateway's log). The main Caddy sets the terminal host's policy whoever answers on that
  socket: a CSP that runs only ttyd's script (its hash, checked at image build), forms only to the unlock, and no
  upstream `Set-Cookie`, `Clear-Site-Data`, `Refresh` or `Link`. Off by default, and
  off over remote access unless `REMOTE_TERMINAL=true`. Home's Claude Code card says where to find it. `./stack
  test` and the e2e suite (`tests/e2e/run.sh --terminal`) check its lock, Origin rules, secret header, gateway list
  and isolation; `./stack uninstall` removes its volume and image also while it is off, and update/rollback keep
  its previous build.
### Changed

- **Open WebUI answers cross-origin requests only from Chat's own origin** (`CORS_ALLOW_ORIGIN`: the new
  `CHAT_ORIGIN` in `.env`, written by `./stack` like `PORTAL_ORIGIN`, plus the remote chat host while remote
  access is on) instead of its default `*`, which it answered with credentials allowed for any `Origin`: a page on
  another of the portal's hosts could have read your chats.
- **The OpenRouter model list is asked for with your key** (on curl's stdin, never on a command line), so
  OpenRouter's *Filter the model catalog for API keys* setting (Settings › Privacy › Model catalog) can leave
  out models the key cannot use; an empty list for the key is taken as it is. On a 4xx there (401/403: the key
  was rejected), the public list is used, with a warning. Messages that only named `./stack openrouter set` now
  also name the paste-in path, and the model count says "no model list yet" instead of nothing.
- **OpenRouter sees requests from bedrock-now as "bedrock-now".** LiteLLM gets `OR_APP_NAME=bedrock-now` and
  `OR_SITE_URL=https://github.com/JongoDB-Labs/bedrock-now`, which LiteLLM 1.105.0 sends to OpenRouter as
  `X-Title` and `HTTP-Referer` (instead of "liteLLM" and litellm.ai), so OpenRouter's Activity and Logs name the app.
- The portal serves `/static/*` with the same security headers as its pages (`X-Content-Type-Options: nosniff`,
  CSP, `X-Frame-Options`).
- **Chat's cost line for free models** (cost filter version 4): an answer from a free OpenRouter model reads
  `free · 1,240 in / 380 out · Gemma 4 31B (free) · ≈ $0.0002 at paid rates · chat ≈ $0.04` instead of
  `≈ $0.00 · …`; the paid-rates figure appears only when the model has a paid version (its prices now reach the
  filter as `equivalent_*_cost_per_token`; a change in a paid version's price now also counts as a change for
  `openrouter_refresh`, so the filter re-syncs), and the chat total stays actual. Older footers (every earlier
  shape) are still stripped before a chat goes back to the model and still count in the chat total.
- Docs name the free router `or/openrouter/free` as the go-to free model (it keeps answering when one free model
  is busy upstream).
- e2e: the RustFS console checks wait for each bucket row instead of counting right after the list appears, and
  the oversize-login check sends 9 KB (over the portal's limit, under Caddy's) and tolerates an early close.
- **The portal holds a hash of the portal password, not the password**: `PORTAL_PASSWORD_HASH` (PBKDF2-HMAC-SHA256,
  600,000 rounds), written by `./stack` whenever `PORTAL_PASSWORD` changes (a hand edit: `./stack up`).
  `PORTAL_PASSWORD` stays in `.env` for you and `./stack password --show`. The update helper checks the password of a
  settings request against its own hash in `.state/helper/`, which the portal cannot read or change, and stops
  taking settings requests after five wrong passwords in 15 minutes. **Once, after this upgrade, every browser and
  device signs in again** (sessions are now bound to the hash), also when the update ran from Home.
- Settings and diagnostics are new request kinds for the helper (`cfg-<nonce>.req`, at most 8 KB with base64
  values; `act-<nonce>.json`, with the password again), each with its own rate limits; the update/rollback/clean
  requests are unchanged. Keys that could send data elsewhere (AWS key, OpenRouter, speech-to-text, alert webhook)
  are taken only from a local session, and so are changes that protect less (storing prompts, nightly backups off,
  fewer kept, longer sign-ins); hosts, ports, the helper's own switches and the internal secrets stay
  terminal-only. No value may contain a control character.
- `./stack up`, `./stack backup`, `rotate-aws`, `openrouter set|apply|models|remove|refresh` and `models --recheck`
  take the stack lock (as setup, update and Settings do), so none of them rewrites `.env` under another; `./stack
  serve` releases it once the stack is up, and a busy message names a settings change or the update helper's job
  (`./stack helper status`). Higher budgets, a later alert threshold and automatic updates or release checks off
  change only from the computer running bedrock-now. Every backup is refused
  when the disk could not hold it twice. `OPENWEBUI_ADMIN_EMAIL` is kept in lowercase, as Open WebUI keeps emails
  (an address setup took from `git config` as typed is lowercased once).
- **`./stack rotate-aws` proves Bedrock access with the new key before switching** (free) and puts the old key back
  when LiteLLM does not come up or the smoke test fails.
- Budgets, the alert webhook, the portal and LiteLLM passwords, the update and price checks: the docs and
  messages point at Settings or `./stack config set` instead of "edit `.env`, then `./stack setup`" (also the
  walkthrough, docs/openrouter.md and docs/voice.md). An OpenRouter key set or removed in Settings plans the model
  set exactly like `./stack openrouter set` and `remove` (the automatic free set for an account without credits).
- **One-click updates are offered by default.** Setup asks *Turn on one-click updates from Home? (Y/n)* (was an
  opt-in "Install the update helper? (y/N)"), with two lines on what it is, and so does the end of an interactive
  `./stack update` on an install without the helper. A "no" (or `./stack helper uninstall`) is remembered in
  `.state/helper-declined` and respected from then on, so installs that declined the old question are asked once
  more. `--yes` still installs it only with `BEDROCK_NOW_HELPER=1`, and a failing install (e.g. no systemd user
  session) no longer ends setup.
- A failed update on Home suggests `./stack rollback` only when the update had moved the code; before that, a
  rollback would undo the previous update instead.
- The "never a web terminal" stance is replaced by the opt-in sandbox above: README, `docs/phone-claude-code.md`
  (SSH or the browser terminal), `./stack ssh-info` and `docs/security.md` (*The browser terminal*: what it can and
  cannot reach, and what reaches further — a workspace you open on your computer later, your Mac's loopback services
  through Docker Desktop, the knowledge bases).
- `./stack status` says when the last update did not finish (its image pull or setup failed, or it was stopped):
  "The last update did not finish — ./stack update finishes it, ./stack rollback goes back" (instead of the
  "Update available" line).
- **`./stack uninstall` also removes this install's built images** (`<project>/portal`, `shared-mcp`, `stt`,
  `terminal` and `caddy-dns`, `:local` and the `:previous` build kept for rollback), each by its exact name and only
  when it exists; never forced and never a prune: an image something still uses stays, and is named. It still keeps
  `.env` and `backups/`; the README and `./stack help` say so.

### Fixed

- **Restore and rollback now bring back files changed after the backup even when their size didn't change.**
  `./stack restore` copied the buckets back with `aws s3 sync --delete`, which uploads a file only when its size
  differs or it is newer than the object, and a backup's files keep the objects' dates from backup time: a file
  overwritten later with content of the same size kept the newer content (also after `./stack rollback` and Home's
  Rollback, in both buckets). The restore now uploads every file of the backup (`aws s3 cp --recursive`), then
  `sync --delete` removes what the backup does not have; the bucket is never empty in between. A rollback to v0.3.0
  or earlier, whose own restore still compares sizes and dates, first gives the backup's bucket files the current
  time, so every file is uploaded (when it cannot, e.g. files owned by another user, it says so and how to make
  sure afterwards). The e2e suite checks it (`cli/restore-same-size-change`).
- `./stack up` no longer says "restarting LiteLLM so it uses the new prices" when it re-renders LiteLLM's
  configuration for another reason (a changed `.env` setting such as `LITELLM_STORE_PROMPTS`).
- After a one-click request Home kept the old state for up to 30 s when its first check came before the helper's
  (it polls every 3 s); it now keeps "Waiting for the update helper…" and asks again every few seconds until the
  helper has answered (at most a minute).
- The portal's scripts and style sheets are revalidated on every load (`Cache-Control: no-cache`, a 304 while
  unchanged), so the reload after an update never pairs the new Home page with an older cached script.

## [0.3.0] - 2026-10-13

### Added

- **Bedrock speech-to-text, on by default** (Mistral Voxtral; `./stack stt set bedrock [small|mini]`). The
  microphone and Open WebUI's voice Call now work with no third-party key, and your recorded speech stays in your
  AWS account. A new small `stt` container (Python + ffmpeg on Alpine, pinned by digest, hash-locked dependencies;
  compose profile `stt`, only while `STT_PROVIDER=bedrock`) takes the browser's recording (WebM/Opus, MP4/AAC, Ogg,
  WAV, MP3, FLAC — recognized by its first bytes; 25 MB / 10 min at most, counted on the bytes received, also for
  chunked uploads; other form fields 64 KB), converts it to 16 kHz MP3 (Bedrock refuses request bodies above ~4 MB,
  which WAV reaches after ~85 s; 10 minutes of this MP3 are 3.2 MB) and asks Voxtral Small for a verbatim
  transcript through LiteLLM's Bedrock pass-through with Open WebUI's own key, so the spend lands on the
  `open-webui` key and its budget applies. The instruction comes before the audio and asks for JSON: with a plain
  "transcribe this", Voxtral answered spoken questions instead. The container's only network is an internal one
  with LiteLLM and Caddy (no internet access); Open WebUI and the portal reach it through Caddy's unpublished
  `:8090` site, so it cannot reach them (Open WebUI trusts `X-Portal-User` from its peers). It holds no AWS
  credentials or key of its own, publishes no port, runs read-only and unprivileged with memory/process limits and
  three requests at a time, gives ffmpeg only the demuxer it sniffed, local files and the audio decoders recordings
  need (and kills it on timeout or a cancelled request), keeps nothing and logs no audio or transcripts; LiteLLM
  and Bedrock errors (budget, model access, throttling, a full `/tmp`) reach Chat as clear "Error transcribing
  chunk: …" messages. Its build reinstalls ffmpeg at most weekly (an ISO-week build argument), picking up Alpine's
  fixes at setup / `./stack update`. Voxtral Small and Mini join the catalog as `stt` models (checked by setup with
  a real 1-token request, hidden from the model picker, priced per token: $0.10/$0.30 and $0.04/$0.04 per 1M); the
  price per minute of audio is an **estimate** (~$0.00014/min of continuous speech for Small, from 375 audio tokens
  per started 30 s measured on Bedrock; a call's short utterances cost about $0.00005 each), labelled as such in
  `./stack stt status`, `./stack costs`, the setup summary and on Home (new *Voice* line; the `stt` container also
  appears in Home's service list and `./stack status`). `./stack test` checks it with a 1-second tone sent from
  Open WebUI through Caddy (~$0.00005). Setup turns it on when Voxtral's check really succeeded and you never chose
  otherwise, in one line ("Voice: Bedrock speech-to-text on (…) — ./stack stt remove to use browser speech"); if
  its container does not start, setup goes on with browser speech and tries again next time. The interactive
  question now offers 1) Bedrock (default) 2) OpenAI 3) Groq 4) browser only, and the choice is remembered
  (`.state/stt-choice`; `./stack stt remove` counts as one). `./stack rollback` to an older version removes the
  container and goes back to browser speech. **Upgrading:** an install that never answered the voice question (for
  example set up with `--yes`) gets Bedrock speech-to-text at its next `./stack update`/`setup` — **including one
  that ran `./stack stt remove` before this version**, which left no record: run `./stack stt remove` again
  afterwards to keep browser speech. One that answered the question (OpenAI, Groq or none) keeps its answer; an
  interactive `./stack setup` offers it Bedrock once, and `./stack stt set bedrock` switches any time. If Voxtral
  stops being usable, setup turns it off with the reason and turns it back on once your AWS admin enables it. See
  docs/voice.md.
- **End-to-end test suite** (`tests/e2e/run.sh`, opt-in, run by hand). It stages a throwaway copy of the checkout
  under its own Compose project (`bne2e[-…]` only), host name and free ports (never ports 80/4000/8765), touches
  Docker only once the project is known to be its own (`tests/test_e2e_harness.sh` proves it),
  runs setup non-interactively with an AWS key taken only from `--aws-env FILE` (AWS_* lines) or the environment,
  and checks every page, portal route, Caddy rule, shared-mcp tool, the LiteLLM endpoints the stack uses, Bedrock
  speech-to-text (Call, a real transcription, the stt container's isolation, off/on again) and the safe `./stack`
  commands, in a Playwright 1.55 Chromium container pinned by digest (hash-pinned Python deps).
  Credentials are read from the throwaway `.env` mounted read-only, never printed; logs are redacted and
  screenshots mask sign-ins. A full run costs about half a cent of Bedrock (small per-key budgets cap it; the
  run fails at $0.10), leaves `~/.local/bin/claude-bedrock` untouched (link and file checked), writes a summary table and JUnit XML, and removes only what
  it created (no prune). `tests/e2e/INVENTORY.md` lists everything there is to test and how.
- **Optional speech-to-text for voice calls** (`./stack stt set openai|groq [model]`, `status`, `remove`; setup
  asks once). Open WebUI's Call button needs server speech-to-text, which Bedrock does not have; this is an
  opt-in, documented exception to Bedrock-only: your recorded speech goes to OpenAI (`gpt-4o-mini-transcribe`,
  $0.003/min, default) or Groq (`whisper-large-v3-turbo`, $0.0007/min). It runs through a hidden LiteLLM model
  `stt` with Open WebUI's own key, so it counts on the `open-webui` budget and in Home's and `./stack costs`'
  spend. The key is checked with the provider first, stored in `.env` (600) and passed to LiteLLM only; shell
  `STT_*` variables are ignored unless you opt in. With it on, the microphone uses it too (dictation then works
  in Firefox and installed/home-screen apps); calls read answers with the browser's voices. Without a key,
  nothing changes. `STT_*` edited by hand in `.env` take effect at `./stack up`; restricted OpenAI keys that
  cannot list models are accepted with a note. Groq bills at least 10 s per request, so for Groq the recorded
  spend is approximate (its bill can be 2–5× higher, still about $0.0001 per utterance). See docs/voice.md
  (Bedrock speech-to-text, above, is now the default).
- **Remote access over HTTPS through Tailscale** (`./stack remote status | enable tailscale | enable domain HOST
  | disable | test`; setup asks once, default: this computer only). A `tailscale/tailscale` sidecar (v1.102.5,
  pinned by digest, userspace networking, no capabilities, its login in the `tailscale-state` volume) hosts four
  Tailscale Services — `svc:bedrock-now`, `-chat`, `-admin`, `-files` — with Tailscale certificates, forwarding
  to a new Caddy listener that exists only inside the Docker network; nothing is published on the host. Remote
  requests need your Tailscale login (`TAILSCALE_ALLOWED_LOGIN`, required in `Tailscale-User-Login`; sessions
  are bound to it) **and** the portal password. The command prints the one-time admin-console steps and a
  policy snippet (tag owner, auto-approvers, a grant to port 443) with your names; the auth key leaves `.env` once
  the sidecar is logged in (and the container is recreated without it). The sidecar shares a dedicated /29
  Docker network (`REMOTE_SUBNET`, checked for overlaps; if unusable, that run starts without remote access) with
  Caddy alone, at a fixed address; Caddy's remote listeners refuse every other caller (gateway included), and a
  random `PORTAL_PROXY_SECRET` proves to the portal that a request came through Caddy. `./stack up`/`restore`
  never wait for the sidecar. `./stack remote test` checks what it can from the computer (including that other
  containers and foreign logins are refused) and prints a checklist for your phone. Details: [docs/remote.md](docs/remote.md).
- **Own-domain mode** (`./stack remote enable domain bedrock.example.com`): Caddy gets a Let's Encrypt
  certificate for the name and a wildcard for its subdomains by DNS-01 (a Caddy build with the Cloudflare DNS
  plugin, `caddy/Dockerfile`, built only in this mode; certificates kept in a volume); DNS points at the sidecar's
  Tailscale address, so only your tailnet can connect. Cloudflare Tunnel + Access is documented, not automated.
- The portal serves the local and the remote site side by side: per-site session cookies (remote: host-only
  `__Host-bn_session` per host name, never a tailnet-wide cookie; each app host gets its own through a 60-second,
  single-use, host-bound hand-off token), origins, login redirects and app addresses (Home reads them from
  `<meta name="bn-apps">`); `./stack status`, the setup summary and `/api/summary` show the remote address.
  The apps' host names are configurable (`CHAT_HOST`, `ADMIN_HOST`, `FILES_HOST`; default unchanged).
  The remote address is its own installable app ("bedrock-now (remote)"; manifest, icons and service worker are
  public there too, through the same `(public_paths)` list as the local site).
- **Precise image cleanup.** `./stack update` records the images this install uses before it changes anything,
  keeps **one** previous version of each image it replaces (so going back needs no download; local builds keep
  theirs as `<project>/portal:previous` and `<project>/shared-mcp:previous`) and, once the new version runs,
  removes the version before that plus this project's own untagged builds, e.g. `freed 3.1 GB (old litellm
  1.104.0, open-webui v0.11.2-slim)`. Never an image that any container (any project) uses or that another
  bedrock-now folder's `compose.yaml` names; never forced; no global `docker … prune`.
- `./stack clean [--yes]`: the same cleanup on demand. Lists what it would remove (with sizes), then asks.
- `./stack status` shows the disk this install uses: images in use (plus the previous version kept for
  rollback), data volumes and backups. The figures are reused for 5 minutes; `./stack status --disk` measures
  them again. An image that cannot be removed is named with the reason (another name for it, or in use).
- **"Update available" card on Home.** The portal checks GitHub's public releases API once a day
  (unauthenticated, https only, ETag, 10 s timeout, 1 MB cap; nothing about your install is sent) and, when a
  newer release than the installed one (`.state/status/version.json`, written by `./stack setup` / `up`) is
  out, shows its release notes (a small Markdown subset rendered as plain DOM text), what the update will do
  (backup, the images it downloads, estimated from the new release's `compose.yaml`, ~3 minutes of downtime)
  and a copyable `./stack update`. `./stack status` and the `claude-bedrock` launch line mention it too, from
  the cached answer (no network). `UPDATE_CHECK=false` in `.env` turns it off. The portal's only new writable
  folder is `.state/update-check/`.
- **`./stack rollback`**: back to the version before the last `./stack update`. It restores the code (branch
  users stay on their branch), the update's own pre-update backup (a backup of the current state is taken
  first) and the previous images, which the cleanup kept, so nothing is downloaded. It works after an update
  that failed half-way, because `./stack update` records what it needs before 3/4 images. It asks first
  (`--yes` skips) and refuses when the checkout has local changes.
- **Optional update helper with one-click Update / Rollback / Clean on Home**: `./stack helper
  install|uninstall|status` (setup offers it; `--yes` installs it only with `BEDROCK_NOW_HELPER=1`). A user-level
  launchd agent (macOS) or systemd user unit (Linux), one per project, outside Docker. The portal (still
  read-only, no Docker socket) only writes `.state/requests/req-<nonce>.json` after a valid session,
  `X-Requested-With`, a same-origin check and the portal password typed again (shared lock-out with the
  login), rate-limited to one request per 30 s and 6 an hour. The helper moves each request into its private
  folder and checks it strictly: allowlisted action, fresh, single-use nonce, owner, no symlink, size cap. It
  refuses when the checkout has local changes, then runs only `./stack update|rollback|clean --yes`. Progress
  goes to `.state/status/helper-status.json`. Home shows it, reconnects across the portal's restart during an
  update, and ends with e.g. "Updated to v0.3.0 · freed 3.1 GB". Requests from remote access (`X-Portal-Remote`,
  set only by Caddy) are refused unless `REMOTE_ADMIN_ACTIONS=true`. Security checklist and threat model in
  `docs/security.md`. The helper also has its own limits (60 s between jobs, 12 a day, one rollback per update),
  so they hold even against a compromised portal container. It is restarted only after a clean exit, answers
  "Busy" while a terminal command holds the new `.state/lock/`, and refuses to update a branch checkout unless
  `BEDROCK_NOW_HELPER_ALLOW_BRANCH=1`. Request files are 640 so that, on Linux, you can read them through the
  setgid folder's group. Under rootless Docker the portal's uid is read from `/etc/subuid` (or set
  `HELPER_PORTAL_UID`).
- **One `./stack update | rollback | clean | restore | setup` at a time** per checkout (`.state/lock/`, with the
  owner's pid; a lock whose process is gone or is no longer ./stack is moved aside and taken over).
- `UPDATE_REQUIRE_SIGNED_TAGS=true` in `.env`: `./stack update` only checks out release tags that
  `git verify-tag` accepts (docs/security.md › Code provenance).
- **Cloud VM with an EC2 IAM role, no stored AWS keys.** Only on an EC2 host — Linux whose firmware says EC2
  (DMI asset tag / vendor / UUID; never macOS, so a network answering `169.254.169.254` can't plant credentials)
  — and only when no access key is configured, setup asks IMDSv2 (1 s timeouts) for the instance role and offers
  to use it (default yes). Before writing anything it checks from an `aws-cli` container that the credentials
  are this role's (`sts get-caller-identity`) and that the role may use Bedrock (a free, deliberately invalid
  invoke on the catalog's Haiku model, then the embedding models), shows the account and role ARN and asks
  (`--yes` accepts). Then it writes `AWS_AUTH=instance-role` and removes the key lines from `.env`; LiteLLM gets
  the role's credentials through boto3's default chain. `./stack rotate-aws` understands the mode:
  `--use-keys` (the key is verified before role mode ends) and `--use-instance-role` (role and Bedrock access
  checked first, the old key ID printed, the previous settings restored and LiteLLM restarted with them if it doesn't come up or the smoke test fails). `./stack up`
  refuses role mode off EC2 and key mode without a key. The one-line installer runs `setup --yes` without a
  terminal on an EC2 host with a role. [docs/cloud-vm.md](docs/cloud-vm.md): a `t4g.medium` arm64 / Amazon
  Linux 2023 recipe with no inbound ports, a least-privilege role policy (US foundation models and `us.`
  inference profiles, `bedrock:Rerank`), the IMDSv2 hop limit 2 that containers need, pinned and
  checksum-verified Compose and buildx plugins, an optional firewall recipe (rebuilt on every container start, IPv4 and IPv6) that keeps the role's credentials
  to LiteLLM (with hop limit 2 every container could fetch them), data residency, costs (~$31/month before
  Bedrock) and a request template for your AWS admin. All pinned images are published for arm64.
- **`./stack serve`** starts the stack and keeps the Mac awake (`caffeinate -i -s`) until Ctrl-C, printing the
  portal URL (and the remote URL when remote access is configured: REMOTE_MODE + REMOTE_HOST in .env); it warns on battery power. `--background`
  holds the wake lock without a terminal and `--stop` ends it (the pid file keeps the process's start time, so a
  reused pid is never killed). While an update/rollback/clean holds `.state/lock` (from a terminal or the update
  helper) it only keeps the machine awake and leaves starting the stack to that. On a Linux laptop it holds a
  `systemd-inhibit` lock (and says so when it can't); on a server it only notes that servers don't sleep. On
  macOS, setup and `serve` say how to turn on Docker Desktop's "Start when you sign in" when it is explicitly
  off (they only read Docker Desktop's settings).
- **`./stack ssh-info`** and [docs/phone-claude-code.md](docs/phone-claude-code.md): Claude Code from your
  phone over SSH + tmux (the machine's Tailscale name, the SSH command, iOS/Android apps, mosh, Tailscale SSH;
  on EC2 without Tailscale it points to Tailscale or Session Manager). No web terminal; Claude Code's Remote
  Control doesn't work with Bedrock.
- **Desktop app.** Chrome and Edge can install the portal as a real app: its own window, Dock or taskbar icon,
  Cmd-Tab entry, and it stays put when minimized (Chat's microphone keeps working). An **Install app** button
  (sidebar, and a note on Home with **Not now**) appears when the browser offers it and disappears once
  installed or inside the app. The manifest has an `id`, `launch_handler: focus-existing` (the Dock icon brings
  the open window forward), **Chat** and **Home** shortcuts, and a name per portal address: `bedrock-now`, or
  `bedrock-now (bn-dev)` / `(port 8800)` for other copies. README › Desktop app covers install and uninstall.
- **`./stack open` opens the installed app** (macOS `~/Applications/<Browser> Apps.localized/`, Linux the
  browser's `.desktop` entry, Flatpak browsers included, started with `gio launch` / `gtk-launch` or its
  `Exec=` words without any shell); otherwise the portal as a tab in your everyday browser profile, with a
  one-time tip naming that browser's Install menu. The separate `--app` window with its own profile (no Dock
  icon of its own) is gone unless `BEDROCK_NOW_OPEN_MODE=window`. `portal/e2e/install/run.sh` (opt-in) checks
  install and `./stack open` end to end in a throwaway container.
- **New app icon:** three slabs of bedrock, the top one lifted, light pouring out of the seam. macOS-style
  squircle with the 824 px safe area, maskable, Apple touch and monochrome variants, and a simplified mark for
  16-48 px, which is also the sidebar logo and favicon. `python -m portal.appicons` writes the SVGs;
  `portal/render-icons.sh` renders the PNGs (rsvg-convert + optipng in a pinned Alpine container) and the tests
  fail if a PNG no longer matches its SVG or the recorded render (`static/icons/SOURCES`). Manifest icon URLs
  carry `?v=<hash>`; Caddy makes exactly these PNGs public, by name.
- **The portal works on phones and installs as an app.** A web app manifest, home-screen icons and Apple touch
  icon; "Add to Home Screen" on iOS and "Install app" in Android Chrome (HTTPS). The manifest, `/icons/app-*`
  and `/sw.js` are public (one `(public_paths)` snippet in the Caddyfile, and the portal), like the login
  page, with the portal's security headers. The service worker caches nothing: it only shows a "Can't reach
  bedrock-now" page when the network is down; `/api/*` and everything else pass straight through.
- **Phone layout (under 768 px):** bottom tab bar with Home and Chat (phones open on Chat, then the last tab);
  Admin, Files and Sign out under **More**, opening in a new tab. Compact Home: spend and budget bars, a
  one-line health summary that expands, the update card without the desktop-only parts (one-click buttons only
  when allowed for this device; the wording follows rotation), models as cards with an **Enabled only**
  filter (it says so when the filters leave no model), sign-ins. From an iPhone/iPad Home Screen app the More
  sheet says Admin and Files open in Safari, which asks for the portal password once. Chat fills the screen and follows the on-screen keyboard (visualViewport), with
  safe-area insets for notched phones (not while pinch-zoomed; a shorter desktop window is not mistaken for an
  open keyboard). On iPhone and iPad, Chat shows a dismissible tip to use the keyboard's
  dictation.
- **Tablets (768-1099 px):** the sidebar becomes an icon rail (tab names as tooltips there only); models show
  as cards.
- Touch targets of at least 44 px on touch screens; reduced motion and light/dark respected throughout.

- `./stack password [--show]`: where the portal password is (this folder's `.env` and project); `--show` prints
  it, only to a terminal.
- `-h` / `--help` for every command, anywhere on the line (`./stack stt set openai --help`): that command's
  part of `./stack help`, exit 0, nothing checked or changed.
- `./stack clean --dry-run`: lists what `clean` would remove and removes nothing.

### Changed

- **`./stack update` with nothing new stops right away.** When the target (the newest release, your branch's
  origin, or `--to`) is the commit already checked out and the last setup succeeded on that very commit
  (`.state/update/setup-commit`: removed when a `./stack setup` starts, written when it succeeds, including the
  setup an update runs), it prints `already on v0.3.0 — nothing to update (./stack update --force re-runs setup)` and exits
  0: no backup, no setup, no model probe, no LiteLLM restart (that took ~150 s and ~$0.0004). Without that record —
  the first update from an older version, a `git pull` or checkout by hand, a rollback (the older version's
  `./stack up` runs no setup) — it runs every step. So does a `BEDROCK_NOW_CODE_UPDATED=1` it cannot trust (an
  older version's own hand-over, or one set in the shell), with a warning. `--force` runs every step as before. The one-click helper ends such an update as
  "Already up to date (v0.3.0): nothing to update" instead of "Updated to"; Home then shows no step list and no
  reload hint. `--to` refuses an empty or option-like value (`--to --force`).
- **Re-running `./stack update` after one that failed half-way finishes it.** When the last update moved the code
  but did not finish (its image pull or setup failed, or it was stopped at any point after the checkout: the update
  is recorded right after it), the next `./stack update` says so and runs 3/4 images and 4/4 setup for the code
  already checked out (taking the image snapshot first if it had not got that far), then records the update as
  done and cleans up as usual. It takes no
  new backup and keeps the update record, so `./stack rollback` still goes back to the version and backup from
  before that update; `--to <ref>` moves the code on first (e.g. to a fix) with the same rollback point. Before, it
  ran setup but left the update unfinished (and, with the check for nothing new, would have stopped there).
- **After an update to a new version**, `./stack update` ends with a short "What's new" pointer (at most 5 lines):
  voice (on, or how to turn on Bedrock speech-to-text), remote access and the one-click helper while they are off
  (with the command that turns each on), and the release notes link when the new version is a release tag.
- **`./stack restore` and `./stack rollback` are quiet.** They no longer print Compose's ~85 per-container
  "Container … Waiting / Healthy" lines (`COMPOSE_PROGRESS=quiet`; Compose's errors still show); restore says
  instead when it stops and starts the services. Rollback passes the setting on to the restored version's own
  restore and up, so going back to v0.2.1 is quiet too. `BEDROCK_NOW_VERBOSE=1` (or your own
  `COMPOSE_PROGRESS`) shows them.
- The image cleanup after an update says `old images: nothing to free` (or `old images: freed …`) instead of a
  bare `nothing to free`. A local build that lost its name (a leftover of an earlier update or a rollback) is
  called an "unused build" (`freed 526 MB (old portal (unused build), …)`); "(previous build)" now means only a
  build that still carries its `:previous` name, so the cleanup no longer reads as if the rollback images went.
- When `./stack update` stops after the code moved, its message starts with the way on: `image pull failed or
  was stopped (network/registry?) — ./stack update finishes it, or ./stack rollback goes back (by hand: …)`
  (`update stopped during 3/4 images — …` after Ctrl-C), and the same after a failed setup.
- The Docker Desktop "Start when you sign in" reminder after setup (and so after every update) appears at most
  once a week (`.state/docker-autostart-hint`, a time stamp; anything else in it counts as never shown).
  `./stack serve` still reminds every time.
- `./stack status` mentions `./stack clean` only when it would free something, with the size (`· old images
  600 MB (./stack clean removes them)`), instead of always appending "(./stack clean frees old images)".
- The portal's wrong-password message and "Forgot it?" hint name this install's `.env` (`~` for your home) and
  Compose project, e.g. `It is PORTAL_PASSWORD in ~/bn-dev/.env (project bn-dev).`, so a second copy's password
  is looked up in the right folder. Remote visitors get the generic wording.
- Setup prints the new portal password only when stdout is a terminal; piped or logged (CI, scripts), it prints
  where the password is instead and shows it at the next run in a terminal.
- `compose.yaml`: LiteLLM's AWS key variables are optional (passed only when `.env` sets them), and
  `./stack` keeps the AWS credentials and `AWS_REGION_NAME` exported in your shell out of Docker Compose, so
  `.env` alone decides (one warning per command when your shell's key differs).

### Fixed

- **Old local builds were never cleaned up on Docker 29.** Its `docker image ls` leaves untagged images out
  unless `-a` is given, so the cleanup after `./stack update` and `./stack clean` took this project's untagged
  leftovers (the builds `./stack rollback` re-tags away from, and every previous build once it lost its
  `:previous` name) for already gone: `./stack clean --dry-run` said "nothing to clean" next to four of them
  (214–312 MB each). The size lookup now lists every image; what may be removed is still only the recorded
  previous-version images, this project's own named images and the untagged builds Compose labelled with this
  project, never one any container uses or another project's.
- **`./stack clean` (and the size `./stack status` offers) no longer includes current builds.** After `./stack down`
  no container protects `<project>/caddy-dns:local` (own-domain mode's Caddy, rebuilt with a download) or
  `<project>/stt:local`, so clean offered them as "(previous build)". A `:local` name is never a candidate now, and
  the images the compose overlays (`compose.*.yaml`) name are kept like those of `compose.yaml`.
- **The image cleanup removes nothing when Docker cannot say what is in use.** A failing `docker ps` or
  `docker volume ls` used to count as "nothing in use". Now `./stack clean` stops with a message, `./stack status`
  offers nothing, and the cleanup after an update keeps both older versions recorded, so the next update removes
  them.
- **Repeated updates could delete the backup `./stack rollback` needs.** Each `./stack update` keeps the newest
  5 automatic backups; the pre-update backup the update record names was not protected, so after a real update
  five more runs (e.g. ones that found nothing new) removed it and rollback stopped with "the pre-update backup …
  is missing". That backup is now kept however old.
- **A voice Call in the portal's Chat tab keeps the screen awake.** The portal framed the apps without
  `screen-wake-lock`, so the browser refused Open WebUI's wake-lock request and a phone or laptop could lock its
  screen mid-call (the pop-out window was not affected). Found by the new end-to-end suite.
- **`./stack restore backups/<ts>` and `./stack rollback` work from any folder.** The backup path was resolved
  against the current folder instead of the checkout, so `~/bedrock-now/stack restore backups/<ts>` run from
  elsewhere stopped with the usage message, and a rollback run from elsewhere put the code back but not the data
  ("the code is back at …, but restoring backups/…-auto failed"). A relative path that is not found in the
  current folder is now looked up in the checkout (a path that names a backup in both places is refused as
  ambiguous), and restore names the absolute path it restores. Rollback hands restore an absolute path (which
  also works when the version it goes back to still has the old restore) and refuses `..` in its record. The
  one-click helper was not affected. Found by the new end-to-end suite.
- **`./stack restore` checks the backup before it stops or drops anything:** both bucket folders must be there and
  each database dump must be readable by `pg_restore --list` with at least one entry. A damaged or empty backup
  used to get as far as `DROP DATABASE`.
- Every setup and update left one more unnamed key under LiteLLM's Virtual Keys: the admin sign-in check
  (`/v2/login`) creates a session key each time. Setup now deletes the session keys of its own logins.
- `/favicon.ico` answered 401 before login (browsers ask for it by themselves); it is public now and redirects
  to the 32 px icon.
- `./stack helper status` exited 1 when the helper was not installed; it is informational and exits 0.
- `./stack serve --help` (and other commands' `--help`) exited 1.
- Tests: the suite can no longer reach a real Docker or a live install. `tests/run.sh` puts shims first on
  `PATH` (docker, aws and tailscale refuse; curl refuses this computer except the closed port 9) and fails when
  any test called one. Several tests did: a `./stack up` test ran the portal image in project `bedrock-now`, an
  Open WebUI test posted to `chat.bedrock-now.localhost`, and the costs tests read `127.0.0.1:4000`.

## [0.2.1] - 2026-10-12

### Changed

- **Real provider logos in Chat and on Home** instead of the generic two-letter badges: Claude, OpenAI, Grok,
  Meta, Mistral, Cohere, Stability and AWS for the Bedrock models, and the vendor's logo for OpenRouter models
  (Claude, OpenAI, Gemini/Gemma, Grok, Llama, Mistral, Qwen, DeepSeek, Kimi, Z.ai, MiniMax, NVIDIA, Nova and
  about 25 more, by the id's vendor prefix in `catalog/openrouter-icons.tsv`; the OpenRouter logo otherwise).
  From [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT, see `catalog/icons/LICENSE-lobe-icons`),
  rendered by `catalog/icons/build.sh` as small PNGs on a white disc (128 px Bedrock, 64 px OpenRouter;
  ~52 KB in all). `./stack setup` / `./stack models --recheck` replace the old badges; icons you picked
  yourself stay. Home's model table shows the same logos, served by the portal (offline).

## [0.2.0] - 2026-10-12

One portal with one login for everything, and cost you can see everywhere. Highlights:

- **Portal + single login:** Home (health, spend and budgets, model access, prices) with Chat (Open WebUI),
  Admin (LiteLLM) and Files (RustFS) tabs behind one password, served by Caddy at
  `http://bedrock-now.localhost`. Open WebUI and the RustFS console no longer publish their own ports.
- **Costs:** a cost line under every chat answer, the session's cost when `claude-bedrock` exits, soft budgets
  at 80% with optional webhook alerts, a budget banner in Chat, and prices updated daily from LiteLLM's public
  list, cross-checked with the AWS Price List.
- **Chat experience:** friendly model names with price tiers and vendor icons, hidden helper models, sensible
  defaults (Sonnet for chat, Haiku for titles), browser speech for voice.
- **Optional OpenRouter** models next to Bedrock (off without a key).
- `./stack open`, safer second copies (project ownership guard), and a rewritten README with reference pages
  in `docs/`.

Upgrading from v0.1.x: run `./stack update`, then open the portal URL it prints (README › Updating).

### Added

- Optional OpenRouter provider (off without a key; README › Optional: OpenRouter). An interactive setup asks
  once for an `OPENROUTER_API_KEY` (hidden; Enter skips), checks it with OpenRouter and stores it in `.env`;
  `./stack openrouter set|remove|status|refresh|list` and `./stack openrouter models all|free|paid|<ids>`
  (`OPENROUTER_MODELS`) manage it later. Only `.env` counts: a key in your shell is ignored by Docker Compose
  calls and `./stack update`, and setup adopts it only after asking (or with
  `BEDROCK_NOW_OPENROUTER_FROM_ENV=1` under `--yes`). OpenRouter's text models (no `:batch` variants, no
  variable-priced routers; `~…-latest` aliases only with `OPENROUTER_INCLUDE_ALIASES=true`) are rendered into
  LiteLLM as `or/<id>` with their per-token prices (so spend, budgets and `./stack costs` include them),
  labelled in Open WebUI in a few batched requests (`… · OpenRouter`, tags `OpenRouter` + `Free`/`Paid` +
  vendor; entries no longer offered are removed) and listed on Home with a provider column and Bedrock / free
  / paid filters. Open WebUI's per-answer cost line prices `or/…` models too (the cost filter's prices
  now reach the container on stdin, so hundreds of models fit). `./stack costs`, `./stack models`, `./stack openrouter status` and Home show the key's
  usage, limit and free-model requests (credits with a management key). The model list is cached in
  `litellm/openrouter-models.{tsv,json}`, fetched at setup and `./stack openrouter refresh`, and by
  `./stack up` when older than 12 hours. The key is never on a command line or sent to the browser; curl
  calls to openrouter.ai are https-only, and a malformed key (CLI or portal) is treated as no key.
  `./stack openrouter set|models|refresh|remove` and a `./stack up` that saw price changes also refresh
  Open WebUI's labels and cost-line prices.

- Daily price updates: the portal fetches LiteLLM's public price list at start and every 24 h (ETag, 10 MB
  cap after bounded gzip decompression, an overall deadline), maps the catalog's Bedrock ids (per-model region)
  to per-token prices, cross-checks them with the public AWS Price List (`catalog/aws-price-map.tsv`) and writes
  `litellm/prices/prices.auto.tsv` + `prices.meta.json` (its only writable bind mount besides `/state`).
  Guards: vanished prices (absent, null, 0; a chat/embedding model without an input price) keep their last
  value; where AWS has a price, only a new value within 2% of it is applied; without AWS data, jumps above 5x
  are held back; more than 30% of known prices changing at once without AWS confirming the new values refuses
  the whole update (checked after the AWS step, skipped on the first update; `./stack prices --accept` applies
  it anyway, `./stack prices` checks now). Failures keep the
  last known prices and record the error. `./stack` uses the update file, marked stale after 7 days and replaced
  only by a newer `catalog/prices.tsv`. Setup runs the full update before rendering LiteLLM's config;
  `./stack up` a quick one (`--no-crosscheck --timeout 20`; the last AWS prices still guard). Home,
  `./stack costs` and `./stack models` (PRICE column) show the prices in use, their source, age, warnings and
  "new prices apply at the next ./stack up"; the `claude-bedrock` launch line adds `new prices pending — run
  ./stack up`. `PRICE_UPDATES=false` turns it off.
- `./stack up` re-renders LiteLLM's config and, only when it changed, recreates a running LiteLLM once (before
  the rest comes up; OpenRouter's refresh runs first and renders with the same prices, so LiteLLM restarts at
  most once), then calls the `on_prices_changed` hook: the chat cost filter's prices (Bedrock and OpenRouter)
  and Open WebUI's model descriptions/tiers, once per `./stack up` together with OpenRouter's label sync.
- Linux: `./stack` keeps `PORTAL_GID` in `.env` (your group; 0 on rootless Docker, re-checked on every run) and
  makes `litellm/prices/` setgid + group-writable; the portal still runs as its own user 10102 (owner of `/state`).
- Caddy (2.11.7, pinned by version and digest) is the single way in for browsers: `http://bedrock-now.localhost`
  (the portal) with `chat.`, `admin.` and `files.` subdomains for Open WebUI, LiteLLM and RustFS. It listens on
  `127.0.0.1:80` when that port is free and Docker may bind it (not rootless Docker), else on 8800; URLs leave
  out `:80`. `caddy/Caddyfile` takes everything from the environment and holds no secrets.
- `PORTAL_HOST` / `PORTAL_PORT` in `.env`. A second copy (`COMPOSE_PROJECT_NAME=bn-dev`) gets
  `bn-dev.localhost`, so two stacks never share host names or cookies.
- `./stack status` lists the portal URLs (and the new `caddy` service).
- The portal service (`portal/`, Python/Starlette, hash-locked dependencies, tests in its Docker `test`
  stage): one password (`PORTAL_PASSWORD`, generated by setup and printed once) signs you in to every browser
  UI for 30 days. Open WebUI signs you in as its admin from the portal (trusted `X-Portal-User` header), so
  there is no second Open WebUI login. The LiteLLM and RustFS sign-ins are on Home with copy buttons.
- Portal shell and Home page (vanilla HTML/CSS/JS, no build step, nothing loaded from the internet, light
  and dark): a sidebar with Home, Chat, Admin and Files (each app in a frame that stays open, plus an "open in
  its own window" link; the last tab is remembered). Home shows service health, spend per key as budget
  meters (amber from 80%, red at 100%) with reset dates and the 30-day total, the model access table with
  prices and reasons, the LiteLLM/RustFS sign-ins (copy buttons) and the `claude-bedrock` command. It refreshes
  every 30 seconds; its data comes from the portal's API, which alone holds the LiteLLM master key.
- `./stack test` reaches the apps the way a browser does: through Caddy with a portal session (cookie in a
  mode-600 file, deleted afterwards). It also checks that a forged `X-Portal-User` without a session, a
  foreign `next=` and unknown host names are refused, and that Chat, Admin and Files may be framed only by the
  portal. A cookie file it creates is removed even when a check fails.
- Soft budgets: every LiteLLM key gets `soft_budget` = 80% of its monthly budget (existing keys are updated by
  `./stack setup`). From 80% on, `./stack costs` and the `claude-bedrock` launch line show
  `⚠ N% of monthly budget used`.
- Optional budget alerts: with `ALERT_WEBHOOK_URL` in `.env`, LiteLLM posts a JSON alert to that URL when a
  key crosses its soft budget and its full budget.
- `claude-bedrock` prints the session's cost when Claude Code exits
  (`session: 14 requests · 420K tokens (38% cached) · $0.0384`). Each request carries a per-launch
  `x-litellm-session-id` and the tag `claude-bedrock`. The summary appears only when stderr is a terminal
  (`CLAUDE_BEDROCK_SUMMARY=1` forces it; `CLAUDE_BEDROCK_QUIET=1` hides it). For it, Claude Code runs as a
  foreground child of the wrapper: same terminal and process group, exit code kept, Ctrl-C/TERM re-raised.
- `./stack open` opens the portal in its own app window (Chrome, Edge, Brave or Chromium with `--app` and a
  per-copy profile; otherwise the default browser; over SSH or without a display it prints the URL).
  `./stack setup` and `./stack up` open it at the end when run in a terminal (`BEDROCK_NOW_NO_OPEN=1` turns
  that off).
- Open WebUI shows the cost of every answer and the chat's running total under each reply
  (`≈ $0.0069 · 1,240 in / 380 out · Claude Sonnet 5.5 · chat ≈ $0.0412`), via a "Bedrock cost" filter
  function that setup installs, enables globally and keeps priced from `catalog/prices.tsv`. Cached tokens are
  priced at cache rates; the lines are stripped before the chat goes back to the model (also after
  "continue response"). Setup enables the filter once and afterwards only updates its code and prices, so an
  admin's switches stick; custom models are priced like their base model.
- Friendly model names with price tiers in Open WebUI's picker (`Claude Sonnet 5.5 · $$`) from the new
  `catalog/display.tsv`, plus tier/vendor tags and small offline vendor icons (`catalog/icons/`: SVG sources sent as 128×128 PNG
  data URIs, since Open WebUI drops SVG icons; setup also replaces icons from earlier versions). Embedding, rerank and image models are hidden from the picker
  (still usable). Names, icons and visibility you set yourself are kept. The portal's Home model table shows
  the same names and tiers.
- Open WebUI defaults: Sonnet 5.5 (or 4.5, or Haiku 5.5) as the default chat model; Haiku 5.5 for chat titles,
  tags and follow-up suggestions; token usage on every answer; four prompt cards; no changelog popup or
  update toast; the microphone uses the browser's speech recognition and read-aloud the system voices.
- A budget banner in Open WebUI while the `open-webui` or `claude-code` key is at 80%+ of its monthly budget
  (red at 100%), refreshed by setup and `./stack up`.
- LiteLLM admin login is now a real database account (`OPENWEBUI_ADMIN_EMAIL` / `LITELLM_UI_PASSWORD`, shown on the
  portal's Home page), and the
  shared env-credential login is turned off, so the red "Environment-credential login is enabled" banner is
  gone.

### Changed

- README restructured for newcomers (Quickstart, Using it, Costs & budgets, Models & access, what leaves
  your machine, a commands table); long reference material moved to `docs/prices.md`, `docs/openrouter.md`,
  `docs/advanced.md` and `docs/security.md`.
- **Open WebUI and the RustFS console no longer publish ports.** After `./stack update` from v0.1.x, the old
  Open WebUI address (`http://127.0.0.1:8080`, or the port setup chose) stops working: use the portal URL
  that setup prints (Chat tab). Setup removes `OPENWEBUI_PORT` and `RUSTFS_CONSOLE_PORT` from `.env`. The
  LiteLLM API (`127.0.0.1:4000`) and shared-mcp (`127.0.0.1:8765`) stay where they were for command-line tools.
- Setup talks to Open WebUI through Caddy with a portal session; the setup summary shows the portal instead
  of three separate logins.
- LiteLLM writes spend logs every 1–6 s instead of every 10–15 s (`proxy_batch_write_at: 1`), so spend shows
  up almost immediately.
- The catalog ships without legacy model aliases (`claude-opus`, `claude-3-opus-20240229`, `grok-4.7`, …).
  The `aliases` column still works; the README shows how to add one.
- `LITELLM_UI_PASSWORD` must meet LiteLLM's password policy (upper- and lowercase, digit, symbol). New installs
  generate `Bn9-…`; an existing hex password gets the `Bn9-` prefix on the next `./stack setup` (before
  LiteLLM starts), and any other password that fails the policy is replaced with a generated one.
- LiteLLM never contacts haveibeenpwned.com for password checks (`password_policy_check_breached_passwords:
  false`; it is on by default in LiteLLM 1.105).

### Security

- Session cookie `bn_session`: signed with `PORTAL_SECRET`, `HttpOnly`, `SameSite=Strict`, `Domain=<portal
  host>`, 30 days; changing `PORTAL_PASSWORD` or signing out ends every session; it is stripped before
  requests reach the apps. Login: POST only, same-origin `Origin`/`Referer` required, constant-time password
  check, backoff after five failures; `next=` only to the portal's own hosts and port.
- Framing: Chat, Admin and Files send `Content-Security-Policy: frame-ancestors <portal origin>` (LiteLLM's
  `X-Frame-Options: DENY` / `frame-ancestors 'none'` are replaced, not just removed, so no other site can
  frame the admin UI); the portal itself refuses framing.
- Signing out survives a portal restart: the sign-out time is written atomically to the new `portal-state`
  volume (`/state`, the portal's only writable mount besides `/tmp`) and read back at start. A missing file
  revokes nothing; an unreadable or corrupt one counts as "signed out just now" (sign in again) rather than
  reviving old sessions.
- `/login` refuses a body without `Content-Length` (411) or over 8 KB (413) before reading it, and Caddy caps
  `/login` bodies at 16 KB.
- A `PORTAL_HOST` that does not end in `.localhost` is refused (setup and `./stack up`) unless
  `BEDROCK_NOW_ALLOW_PUBLIC_HOST=1` is set: the session cookie is not `Secure` (plain HTTP) and is scoped to
  that name and all its subdomains.
- The portal session file that `./stack setup`, `up`, `test` and `models --recheck` use is deleted however
  the command ends (error, Ctrl-C, kill); files left by a hard-killed run are removed after an hour.

### Fixed

- `./stack up` re-syncs Bedrock model descriptions and tiers in Open WebUI when OpenRouter re-rendered
  LiteLLM's config with prices the portal's daily job had already updated (before, only OpenRouter's labels
  were refreshed in that case).
- Caddy's `/data` and `/config` tmpfs are owned by its unprivileged user, so it no longer logs
  `mkdir /data/caddy: permission denied` at start. Caddy waits for a healthy portal before it starts.
- `./stack up` rewrites `PORTAL_ORIGIN` from `PORTAL_HOST` / `PORTAL_PORT`, so editing either in `.env` keeps
  the apps framable by the portal.
- The portal no longer logs every internal HTTP request it makes (httpx at WARNING).
- The Home tab check ignores names inherited from `Object.prototype` (`#constructor`).
- Home notes that the LiteLLM sign-in shown is the one setup created; a password changed in LiteLLM's UI is
  not reflected.
- The cost line after **Continue response** prices only the continued part (documented; `./stack costs` is
  exact).
- The cost line under chat answers showed its HTML tags (`<sub>≈ $0.0011 · … </sub>`): Open WebUI v0.12 does
  not render `<sub>`. It is now one line of Markdown in italics. Answers with the old line still have it
  stripped before the chat goes back to the model and still count towards the chat total; `./stack setup`
  installs the new filter (version 3).
- A one-sentence question in Chat cost ~9,800 input tokens: Open WebUI v0.12 sends the definitions of ~40
  built-in tools (knowledge bases, chat history, notes, calendar, automations, skills, tasks, time, …) with
  every request from the browser, plus 8 memory tools (~2,000 tokens) because the browser turns Memory on in
  every chat. Those categories are now off by default (`DEFAULT_MODEL_METADATA` → `builtinTools`), so the same
  question costs ~25 input tokens, as through the API. Saved memories still reach the model as context, but
  it can no longer edit them itself. Image generation, code interpreter and web search tools are still
  offered while you switch them on in a chat; attached files
  and `#` knowledge still use retrieval. A custom model with attached knowledge needs **Builtin Tools →
  Knowledge** ticked in its settings (README › Costs & budgets).
- A stopped install keeps its Compose project name. Before, once one checkout ran `./stack down`, another
  set-up checkout with the same name could start on its data volumes (wrong database password) or delete them
  with `./stack uninstall`. The first checkout that starts or changes a project (`setup`, `up`, `update`,
  `restore`, `test`, `backup`, `rotate-aws`; not `down`, `logs`, `status`, `costs`, `models`) now records
  itself in an empty Docker volume `<project>_bedrock-now-owner`; other folders are refused while that install
  still has data. Existing volumes are claimed by the first checkout that starts or changes the stack after the
  upgrade. Of two simultaneous claims exactly one wins; the other stops with "was just claimed by …". A checkout
  whose own containers run the project always wins. A record is replaced only when its folder no longer exists
  (moved or deleted checkout), and only if it is still the record the guard checked, never one another
  checkout just wrote; a folder without `.env` keeps its claim, and the message explains it. The data
  volumes are not labelled: Compose would offer to recreate them, deleting the data, whenever a volume label
  changes.
- If the clashing install's containers come from a folder that no longer exists, the message suggests
  `docker compose -p <project> down` instead of `cd` into it. A set-up checkout that replaces another folder
  (moved or copied with its `.env`) is told to stop the old folder's stack and move that folder aside or delete
  it (it holds its own `backups/` and `.env`); the data volumes are kept.
- `./stack uninstall` lists the data volumes it will delete, refuses when they belong to another folder (also
  without a `.env`), and removes the ownership record afterwards.
- Clash messages only suggest `COMPOSE_PROJECT_NAME=<name>-2 ./setup.sh` on a first setup, where it works. A
  checkout that is already set up is told to keep only one of the two installs. A clash with a Compose project
  that is not bedrock-now is named as such ("another Compose project in <dir>").
- `./stack status` shows the clash as a warning and still prints its table.
- `./stack update` checks for local changes to tracked files before it takes (or prunes) a backup.
- After a failed `./stack update` on a branch, the way back is `git -C <dir> switch -C <branch> <commit>`, so you
  stay on your branch; release-tag installs keep `git -C <dir> checkout <commit>`.

## [0.1.2] - 2026-10-12

### Fixed

- Two checkouts can no longer share one Docker Compose project. Every `./stack` command refuses when another
  folder already runs the same project name, and a first setup refuses to start on existing data volumes of
  that name (their database password would not match). Before, a second install with the default name reused
  the first one's volumes (LiteLLM failed with `P1000 Authentication failed`) and recreated its containers.
- `./stack update` takes the backup **before** changing the code (steps 1/4 backup, 2/4 code, 3/4 images,
  4/4 setup). If a later step fails it prints the exact way back (`git -C <dir> checkout <commit> &&
  ./stack restore <backup>`), and it keeps `--yes` when it continues with the new code.
- The newest release tag ignores pre-releases (`v0.2.0-rc1`) in both `./stack update` and the installer, and
  `./stack update` without `--to` never moves to an older version than you have.
- A failed checkout shows git's own error message.
- Installer: a bad `BEDROCK_NOW_REF` explains how to recover (`git -C <dir> checkout <ref>` or `rm -rf <dir>`),
  paths in its hints are shell-quoted, and `BEDROCK_NOW_REPO` is documented.

## [0.1.1] - 2026-10-12

### Added

- One-line installer: `curl -fsSL https://raw.githubusercontent.com/JongoDB-Labs/bedrock-now/main/install.sh | bash`
  checks prerequisites (with per-OS install hints), clones the latest release into `~/bedrock-now`
  (`BEDROCK_NOW_DIR`, `BEDROCK_NOW_REF`), never overwrites an existing folder, and starts setup.
- `./stack models` prints the model table from the last check without calling Bedrock; `--recheck` re-probes.
  Results are saved to `litellm/probe-results.tsv`.
- A third LiteLLM virtual key, `setup` (`BUDGET_SETUP`, default $5), pays for the model probe and the paid
  `./stack test` calls. `./stack test` checks the other keys with free `/key/info` calls.
- `./stack costs` lists the `setup` key and a total across all keys (last 30 days, from `/global/spend`).
- `./stack update` also updates the code: a release-tag install moves to the newest tag
  (`updating v0.1.0 → v0.1.1`), a branch checkout gets `git pull --ff-only`, and `--to <tag|branch>` picks a
  version. Local changes to tracked files stop the update; they are never discarded.
- `NO_COLOR` turns all colours off.

### Changed

- Setup and `./stack up` print one line per phase with elapsed time (`==> LiteLLM ready (16s)`) instead of raw
  compose output; on failure they show the last output and service log lines plus a `./stack logs` hint.
  `BEDROCK_NOW_VERBOSE=1` restores the full compose output. Missing images are announced (with size) and
  downloaded up front with progress.
- Setup announces its decisions: each moved port in one line (`port 8080 is in use → using 8083 for Open WebUI`),
  the Open WebUI admin email and where it came from. The "use the AWS key from your environment?" prompt
  defaults to Yes for a long-lived (AKIA…) key.
- The model table fits 100 columns (MODEL, KIND, coloured STATUS, PRICE, short WHY) with one footnote per
  reason and its action. Marketplace denials show as "no Marketplace access", other "no access to the model"
  denials as "no model access"; when LiteLLM reports a bare AccessDenied (e.g. for rerank), a free direct
  Bedrock check finds the precise cause.
- `./stack status` is a compact SERVICE / STATE / HEALTH / URL table instead of raw `docker compose ps`.
- `./stack help` marks the commands that call Bedrock and what they cost; `claude-bedrock --help` starts with a
  six-line header about the wrapper, and `--help`/`--version` no longer print the launch cost line or need
  LiteLLM running.
- Budgets are described the same way everywhere: monthly budget (resets on the date shown by `./stack costs`).
- The setup summary shows a `claude-bedrock` command that works as typed (absolute path when the
  `~/.local/bin` link is missing or not on PATH) and a "Try it" line with Haiku (~$0.02).
- `./stack status` says "the Docker daemon is not running" instead of showing every service as not created.

### Fixed

- Tables and the setup summary no longer write colour codes when stdout is piped (colours are chosen per stream).
- `./stack costs` shows $0.00 when nothing has been spent yet and the HTTP status when LiteLLM refuses the
  total.
- `claude-bedrock --help` before setup says "not set up yet" instead of printing an empty port and price.
- Temporary files from bring-up and the model probe are removed on Ctrl-C.
- `./stack models` skips incomplete lines in `litellm/probe-results.tsv` with one warning.

## [0.1.0] - 2026-10-12

Initial public release.

- `./stack` CLI (bash 3.2-compatible): `setup`, `up`/`down`, `status`, `logs`, `test`, `costs`,
  `backup`/`restore`, `update`, `rotate-aws`, `uninstall`.
- Docker Compose stack bound to 127.0.0.1: LiteLLM (Bedrock proxy, virtual keys with monthly budgets),
  Open WebUI, Postgres (pgvector), RustFS object store, and a shared MCP server.
- Setup probes which catalog models your AWS key can use (1-token requests, free checks for images)
  and renders the LiteLLM config from `catalog/models.tsv` and `catalog/prices.tsv`.
- `bin/claude-bedrock`: runs Claude Code against Bedrock through LiteLLM without touching plain `claude`.
- Cost transparency: Bedrock prices in `./stack costs` and the Open WebUI model picker, spend per key.

[Unreleased]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.5...HEAD
[0.32.3]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.32.2...v0.32.3
[0.32.2]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.32.1...v0.32.2
[0.32.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.32.0...v0.32.1
[0.32.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.5...v0.32.0
[0.31.5]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.4...v0.31.5
[0.31.4]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.3...v0.31.4
[0.31.3]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.2...v0.31.3
[0.31.2]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.1...v0.31.2
[0.31.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.31.0...v0.31.1
[0.31.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.30.2...v0.31.0
[0.30.2]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.30.1...v0.30.2
[0.30.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.30.0...v0.30.1
[0.30.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.29.0...v0.30.0
[0.29.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.28.2...v0.29.0
[0.28.2]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.28.1...v0.28.2
[0.28.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.28.0...v0.28.1
[0.28.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.27.1...v0.28.0
[0.27.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.27.0...v0.27.1
[0.27.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.26.0...v0.27.0
[0.26.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.25.2...v0.26.0
[0.25.2]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.25.1...v0.25.2
[0.25.1]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.25.0...v0.25.1
[0.25.0]: https://github.com/JongoDB-Labs/devos-ade/compare/v0.24.0...v0.25.0
[0.24.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.23.0...v0.24.0
[0.23.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.22.1...v0.23.0
[0.22.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.22.0...v0.22.1
[0.22.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.21.1...v0.22.0
[0.21.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.21.0...v0.21.1
[0.21.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.20.2...v0.21.0
[0.20.2]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.20.1...v0.20.2
[0.20.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.20.0...v0.20.1
[0.20.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/JongoDB-Labs/bedrock-now/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/JongoDB-Labs/bedrock-now/releases/tag/v0.1.0
