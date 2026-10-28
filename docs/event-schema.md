# DevOS ADE event schema (contract v1)

**Contract id:** `devos-ade/events/1` &nbsp;·&nbsp; **Status:** draft for the collector owner's review &nbsp;·&nbsp; **Scope:** specification only.
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
| `at` | integer | epoch seconds, UTC: when this computer recorded the event (immutable once recorded) |
| `subject` | string | the thing it is about, from the kind's allowed set (a service name or a step name; never free text) |
| `count` | integer | 0 to 999999999; 0 when the kind has no count |
| `exit_code` | integer | 0 to 255; 0 when the kind has none |
| `dedupe` | string | 64 lowercase hex characters, defined below |

An event carries **no other field**. There is no message, no log line, no path, no command, no environment value, no
prompt, no file content, no repository, project or branch name, no address, no model name and no key. A collector
rejects an event with an unknown field, an unknown kind, a `subject` outside the kind's set, or a value outside its
range, and it rejects the whole batch if it holds an event with a field that matches the redaction rules below.

### Kinds

| kind | `subject` | `count` | `exit_code` | status in the product |
| --- | --- | --- | --- | --- |
| `container.restart` | a service of the stack | restarts since the last look | the last exit code | recorded locally (G4) |
| `container.unhealthy` | a service | 0 | 0 | recorded locally (G4) |
| `container.exit` | a service | 0 | the exit code (not 0, not 143) | recorded locally (G4) |
| `container.oom` | a service | 0 | the exit code | recorded locally (G4) |
| `update.failed` | `update`, `rollback` or `auto-update` | 0 | 0 | reserved (not recorded as an event yet) |
| `update.refused` | `update`, `rollback` or `auto-update` | 0 | 0 | reserved |
| `setup.step_failed` | a setup step name from `lib/steps.sh` | 0 | 0 | reserved |
| `sandbox.start_failed` | `terminal` or `code` | 0 | 0 | reserved |
| `signin.refused` | `portal` | the number refused since the last look | 0 | reserved |

Service names are the stack's own, matching `^[a-z0-9][a-z0-9_-]{0,39}$` (caddy, portal, open-webui, litellm, rustfs,
postgres, shared-mcp, searxng, stt, terminal, code, tailscale, and the one-shot rustfs-init). A reserved kind is part
of the contract so the collector can plan for it; an install does not produce it until the product records it
locally first.

### Dedupe key

`dedupe` = lowercase hex SHA-256 of the UTF-8 text

    devos-ade/events/1 \n <install> \n <kind> \n <subject> \n <at> \n <count> \n <exit_code>

(seven lines joined by a single line feed, no trailing one; integers in decimal with no padding). It is a function
of the event alone, so an install that restarts, resends a batch or replays its local record makes the same key for the
same event, and a collector that keeps the keys it has seen counts each event once. Two different events never share
a key unless they agree on every field, in which case they are the same event. A collector keeps keys for at least
as long as it keeps events.

Grouping (one issue for a crash loop rather than fifty) is the collector's choice and is by `kind` + `subject` +
`ade_version`; the schema does not carry a group id.

## Redaction (shared, not reimplemented here)

DevOS ADE does **not** have its own redaction for transmitted text, and this contract does not add one. Version 1 has
no free-text field, so there is nothing to redact on the install side: every field above is an enum, a number, a
version or a hash. Redaction is still required of the receiving side as defense in depth, using the **shared rules
owned by JON-169** (the bridge's Go `Redact`, which the Swift `CrashRedact` follows through the same corpus). These are
pinned here byte for byte; ADE neither copies nor edits them:

| pin | value |
| --- | --- |
| ticket | JON-169 (Bring the apps' crash redactor up to the bridge's rules) |
| repository | `xirp-mobile` (the DevOS bridge repository) |
| rules | `internal/diag/redact.go`, function `Redact(text string, max int) string` |
| rules sha256 | `d06a63b13ebfb1046c28b8d34f4193744949bb0a267fb619cd27fcfa66a8cccb` |
| corpus | `internal/diag/testdata/redact_corpus.json` (the shared golden: 597 cases of `in`, `max`, `out`) |
| corpus sha256 | `4d17d793adb6815d9458648a9ce12b1fc3193e491ecba8b1669eeb0067faf780` |
| golden test | `TestRedactGolden` in `internal/diag/redact_golden_test.go` (fails when rules and corpus disagree) |
| pinned at | branch `jon-169-stream`, commit `e154bb660c5cf33280ee2378f61dc6f6bccea549` |

The pin is the file hashes, not the branch: when JON-169 lands on the repository's main branch, the collector owner
confirms the two hashes are unchanged (or publishes the new ones and this table is updated in the same change as the
contract's next review). If a future version adds any free-text field, that field must be passed through `Redact`
before it leaves the computer **by calling the shared implementation or a port that reads the same corpus**, with the
corpus pinned here; a third implementation is not an option.

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

## Not in this contract

Transport and authentication (pairing, relay, rate limits), the collector's storage, the owner view, the opt-in
switch and its consent text, retention, and feedback typed by a person (that goes to a public GitHub issue the person
submits themselves: JON-440 plan A; the product never claims such a report was sent or reached anyone).
