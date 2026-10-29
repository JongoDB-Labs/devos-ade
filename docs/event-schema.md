# DevOS ADE event schema (contract v1)

**Contract id:** `devos-ade/events/1` &nbsp;·&nbsp; **Status:** revised after the collector owner's review (R1-R3, C1-C5); for final confirmation before the v1 freeze &nbsp;·&nbsp; **Scope:** specification only.
There is no emitter, no transport and no collector in DevOS ADE for this contract: those are separate, later work
(JON-440 plan B; JON-149 G6 for the opt-in switch; the shared collector and relay belong to the DevOS collector owner).
Nothing in this file turns anything on. Private diagnostics stay **off** unless a person opts in.

This file is the whole contract. A change to a field, a kind or the dedupe rule is a new contract version
(`devos-ade/events/2`), never an edit of version 1 after it has been reviewed.

## What this is for

DevOS ADE runs on a person's own computer from a public repository. If a person ever opts in to share diagnostics,
this is the one shape an install would hand to a collector: small counts and Docker's own words about what failed,
never what the person was doing. The collector registers DevOS ADE as its own source (an "ADE adapter"); it is not
the Apple/TestFlight monitor and shares nothing with it except the redaction rules below.

Local first: everything an event says is already recorded and shown on this computer, in the portal's Activity feed,
with no network (JON-440 G4; `lib/health.sh`, `.state/status/container-health.json`). The schema describes how those
local facts would be wrapped, if and only if sharing is ever opted in.

## Envelope

One JSON object per batch, at most 64 KiB, at most 50 events:

| field | type | rule |
| --- | --- | --- |
| `contract` | string | exactly `devos-ade/events/1` |
| `source` | string | exactly `devos-ade` |
| `ade_version` | string | the installed release, `^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$`, or `unknown` |
| `install` | string | 32 lowercase hex characters: a random id made when the person opts in. Never derived from hardware, a username, a path, an address or a key; deleted when they opt out. Reserved: no install makes one in version 1 of the product |
| `sent_at` | integer | epoch seconds, UTC (when the batch was made) |
| `events` | array | 1 to 50 events |

## Event

| field | type | rule |
| --- | --- | --- |
| `kind` | string | one of the kinds below |
| `at` | integer | epoch seconds, UTC, from this computer's clock as it is: when the event was recorded. Never corrected for clock skew; fixed when the row is first written |
| `subject` | string | the thing it is about: exactly one member of the kind's CLOSED set below, or the literal `other`; never free text, never a pattern |
| `count` | integer | 0 to 999999999; 0 when the kind has no count. Fixed when the row is first written |
| `exit_code` | integer | 0 to 255; 0 when the kind has none. Fixed when the row is first written. For `container.oom` and `container.restart` it is the code exactly as Docker reports it (an out-of-memory kill is usually 137), not a guess about a signal |
| `dedupe` | string | 64 lowercase hex characters, defined below |

An event carries **no other field**. There is no message, no log line, no path, no command, no environment value, no
prompt, no file content, no repository, project or branch name, no address, no model name and no key. A collector
rejects an event with an unknown field, an unknown kind, a `subject` outside the kind's closed set (the literal `other`
included), or a value outside its range, and it rejects the whole batch if any string field matches the redaction rules
below. The collector does not reject clock skew: it orders by the time it received a batch, not by `at`.

### Kinds

| kind | `subject` | `count` | `exit_code` | status in the product |
| --- | --- | --- | --- | --- |
| `container.restart` | a stack service, or `other` | restarts since the last look | the last exit code | recorded locally (G4) |
| `container.unhealthy` | a stack service, or `other` | 0 | 0 | recorded locally (G4) |
| `container.exit` | a stack service, or `other` | 0 | the exit code (not 0, not 143) | recorded locally (G4) |
| `container.oom` | a stack service, or `other` | 0 | the exit code | recorded locally (G4) |
| `update.failed` | `update`, `rollback` or `auto-update` | 0 | 0 | reserved (not recorded as an event yet) |
| `update.refused` | `update`, `rollback` or `auto-update` | 0 | 0 | reserved |
| `setup.step_failed` | a setup or update step, or `other` | 0 | 0 | reserved |
| `sandbox.start_failed` | `terminal`, `code` or `other` | 0 | 0 | reserved |
| `signin.refused` | `portal` | the number refused since the last look | 0 | reserved |

### Subjects are closed sets

A `subject` is never a pattern. Anything that is not in the kind's set below is recorded as the literal `other`
**on the install, before the event is recorded**: a service a person added to the Compose project, or a step this
version does not know, never leaves the computer by name, and a local record never holds it.

**Services** (`container.*`): the 20 services the stack's own Compose files define (`compose.yaml` and its overlays:
terminal, code, Tailscale, the egress proxies, Ollama and its gate on Linux), plus `other`.

- `caddy`
- `chat-egress`
- `code`
- `forgejo`
- `litellm`
- `ollama`
- `ollama-gate`
- `open-webui`
- `portal`
- `postgres`
- `rustfs`
- `rustfs-init`
- `searxng`
- `shared-mcp`
- `stt`
- `subs-chat`
- `tailscale`
- `terminal`
- `terminal-egress`
- `terminal-gateway`
- `other`

(`rustfs-init` is a one-shot that exits when it is done.) `lib/health.sh` holds this list as `HEALTH_SERVICES`, and a
test checks it against the Compose files, so a service added to the stack changes this contract version first.

**Other subjects:** `update.failed` and `update.refused`: `update`, `rollback`, `auto-update`, `other`.
`sandbox.start_failed`: `terminal`, `code`, `other`. `signin.refused`: `portal`, `other`. `setup.step_failed`: the
step names below, copied as literals from `timed_step` in `lib/*.sh`, plus `other` (a test checks this list against
the code):

- `AWS key check`
- `Backup`
- `Chat's sandbox`
- `Code page default`
- `Finishing`
- `Git server`
- `Image downloads`
- `Image downloads started`
- `Images of the version before kept (for rollback)`
- `LiteLLM config (full catalog, for the model check)`
- `LiteLLM config (model check kept)`
- `LiteLLM config: web search check, default models`
- `LiteLLM keys, Admin sign-in, voice service`
- `LiteLLM setup key`
- `Model check`
- `New code (git)`
- `Old images cleaned up`
- `Open WebUI image`
- `Open WebUI syncs (models, prices, banner)`
- `Open WebUI with your subscriptions`
- `Portal sign-in and Chat's API key`
- `Ports and settings in .env`
- `Prices`
- `Services run the pinned images`
- `Smoke test`
- `Terminal: its key and project folders`
- `Voice`
- `Web search check`
- `What's new`
- `other`

A reserved kind is part of the contract so the collector can plan for it; an install does not produce it until the
product records it locally first.

### Dedupe key

`dedupe` = lowercase hex SHA-256 of the UTF-8 text

    devos-ade/events/1 \n <install> \n <kind> \n <subject> \n <at> \n <count> \n <exit_code>

(seven lines joined by a single line feed, no trailing one; integers in decimal with no padding). It is a function
of the event alone, so an install that restarts, resends a batch or replays its local record makes the same key for the
same event, and a collector that keeps the keys it has seen counts each event once. Two different events never share
a key unless they agree on every field, in which case they are the same event. A collector keeps keys for at least
as long as it keeps events.

**Rows are immutable.** A local event row's `at`, `count`, `exit_code` and `subject` are fixed when it is first written and
are never recomputed on a later look (rows are only appended, and the oldest dropped from the front past a cap of
50). This is what makes a replay produce the same key: a recompute would make a new key and count the event twice.

Grouping (one issue for a crash loop rather than fifty) is the collector's choice and is by `kind` + `subject` +
`ade_version`; the schema does not carry a group id.

## Redaction (shared, not reimplemented here)

DevOS ADE does **not** have its own redaction for transmitted text, and this contract does not add one. Version 1 has
no free-text field, so there is nothing to redact on the install side: every field above is an enum, a number, a
version or a hash. Redaction is still required of the receiving side as defense in depth, using the **shared rules
owned by JON-169** (the bridge's Go `Redact`, which the Swift `CrashRedact` follows through the same corpus), as
**shipped** in the Companion release line. They are pinned here byte for byte; ADE neither copies nor edits them:

| pin | value |
| --- | --- |
| ticket | JON-169 (Bring the apps' crash redactor up to the bridge's rules) |
| repository | `xirp-mobile` (the DevOS bridge repository) |
| release tag | `companion/v0.24.2` (commit `c5fc2a967e3a1d55b64f0f10116fb6ebae69befd`): the shipped release line, not a branch |
| rules | `internal/diag/redact.go`, function `Redact(text string, max int) string` |
| rules sha256 | `fcfe40e7cf9553eef07157683e64ff479cdfeae2c23c0cf6d7036402d640aa20` |
| corpus | `internal/diag/testdata/redact_corpus.json` (the shared golden: 810 cases of `in`, `max`, `out`) |
| corpus sha256 | `5eac13df0b72ecb53b9cf506cccc6735736a195428037c3a33de7edf2d428836` |
| golden test | `TestRedactGolden` in `internal/diag/redact_golden_test.go` (fails when rules and corpus disagree) |

**A field "matches the redaction rules"** when, for a string field `s`, `Redact(s, len(s)) != s` (the shared function
changes it). One such field rejects the whole batch.

The pin is the two file hashes at the shipped `companion/v*` tag, not a branch and not the repository's main branch
(which is not the release line). The collector owner tells ADE when a later `companion/v*` tag changes either hash,
and the next contract review updates this table. If a future version adds any free-text field, that field must be passed
through `Redact` before it leaves the computer **by calling the shared implementation or a port that reads the same
corpus**, with the corpus pinned here; a third implementation is not an option.

What ADE already has is for display on this computer only and is **not** the redaction for transmission: the portal's
`_clean` (control characters and length, for text shown in Activity) and `./stack config report`'s `_report_scrub`
(for a status report a person pastes into an issue by hand).

## Where the facts come from

`.state/status/container-health.json` (written by `lib/health.sh` whenever `./stack` or the update helper refreshes
`services.json`, about once a minute while the helper runs):

    {"version": 1, "written_at": N, "services": [...], "events": [{"at", "service", "kind", "count", "exit_code"}]}

with local kinds `restart`, `unhealthy`, `exit` and `oom`. An emitter, when one exists, would map them to
`container.<kind>` with `subject` = `service`, taking `at`, `count` and `exit_code` unchanged. The local file is
read-only to the portal, never leaves the computer today, and holds Docker's own numbers and words only.

## Notes for later work (not enabled, not built)

- **Routing.** When sharing exists, the collector files ADE events into a PRIVATE Linear path that is **not**
  GitHub-synced, and never comments them on a GitHub-synced issue (a synced issue's comments can be published to a
  public GitHub issue).
- **Deletion.** On opt-out the install asks the collector to delete everything held under its `install` id; the
  transport defines how. The collector's retention is bounded, and the opt-in text states it.

## Not in this contract

Transport and authentication (pairing, relay, rate limits), the collector's storage, the owner view, the opt-in
switch and its consent text, retention, and feedback typed by a person (that goes to a public GitHub issue the person
submits themselves: JON-440 plan A; the product never claims such a report was sent or reached anyone).
