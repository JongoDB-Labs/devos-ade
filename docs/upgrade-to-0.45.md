# Upgrading to 0.45: the move to the name devos-ade

From 0.45 the product is called DevOS ADE everywhere, hostname included. An install made under the old name
(Compose project `bedrock-now`) is moved to the new one by the update itself: **Update now** on Home, or
`./stack update`. Nothing needs to be done by hand, and nothing is deleted.

## What moves

| Before | After |
|---|---|
| folder `~/bedrock-now` | `~/devos-ade` (renamed in place, never copied; `~/bedrock-now` stays as a link to it) |
| Compose project and volumes `bedrock-now_*` | `devos-ade_*` (copied, each copy checked by file count, bytes and checksums) |
| address `http://bedrock-now.localhost` (and `code.`, `chat.`, `admin.`, `terminal.`, `files.`) | `http://devos-ade.localhost` |
| `.env` keys `BEDROCK_NOW_*` | `DEVOS_ADE_*`; the old `.env` is kept as `.env.pre-devos-ade` |
| launchd labels `io.bedrock-now.*` (and the systemd user unit on Linux) | `io.devos-ade.*` |
| `~/.config/bedrock-now` in the terminal's home | `~/.config/devos-ade` |

Ports do not change. The model files under `.state` (Hugging Face cache, LM Studio home, Ollama) move with the
folder in one rename; absolute paths that name the old folder (runtime records, launchd plists, `lms import` links,
session and Code page records) are rewritten, relative links are left as they are. Your account email in Open WebUI
is kept as it was, so chats, spend and git history stay yours. The update needs free disk for the copy of the
volumes plus 10% and says how long it expects to take before it stops anything. If a check fails nothing is changed.

The update can be interrupted and run again: it resumes. Until the last step succeeds, the old project stays the one
that `./stack up` starts.

## On the new address

The new hostname is a new browser origin, so once:

- sign in again to the portal;
- unlock Code and Terminal again;
- install the browser app (PWA) again from `http://devos-ade.localhost`, and remove the old one.

## The old address

For this release `bedrock-now.localhost` and its subdomains answer with a 308 redirect to the same path and query on
the new name, for GET, HEAD, POST, PUT and DELETE alike (a 308 keeps the method and body). The old address never sets
a cookie, is never accepted as an Origin on the new host, and WebSockets to it are refused (426); the redirected page
opens its sockets on the new address. The redirect is removed in the next minor release.

## The backup, and removing it

The old volumes, `.env.pre-devos-ade`, the `~/bedrock-now` link, the old images and the old launchd plists are kept
as a backup until you remove them. Home, `./stack status` and `./stack migrate` say that it exists and how big it is.

    ./stack migrate               # status of the move and of the backup
    ./stack migrate --remove-old  # lists what would be removed, with sizes, and asks
    ./stack migrate --remove-old --yes

## Going back

Before `--remove-old`, `./stack migrate --rollback` returns to the old project, folder, launchd labels and `.env`
with the data intact. The new volumes it made are kept aside (renamed, not deleted). After `--remove-old` there is
nothing to go back to. Data written after the move lives in the new volumes only.

## Tailscale

The Tailscale Service base, node name and tag are pinned in `.env` at the old values when remote access is on, so the
remote URL does not change. Renaming them is a tailnet admin change (the Service and tag are defined in your tailnet
policy); do it there and then change the matching `DEVOS_ADE_TAILSCALE_*` keys.
