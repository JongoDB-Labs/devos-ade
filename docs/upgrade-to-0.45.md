# Upgrading to 0.45: the move to the name devos-ade

From 0.45 the product is called DevOS ADE everywhere, hostname included. An install made under the old name
(Compose project `bedrock-now`) is moved to the new one by the update itself: **Update now** on Home, or
`./stack update`. Nothing needs to be done by hand.

## What moves

| Before | After |
|---|---|
| folder `~/bedrock-now` | `~/devos-ade` (renamed in place, never copied; `~/bedrock-now` stays as a link to it) |
| Compose project and volumes `bedrock-now_*` | `devos-ade_*` (copied, each copy checked by file count, bytes and checksums) |
| address `http://bedrock-now.localhost` (and `code.`, `chat.`, `admin.`, `terminal.`, `files.`) | `http://devos-ade.localhost` |
| `.env` keys `BEDROCK_NOW_*` | `DEVOS_ADE_*`; the old `.env` is kept as `.env.pre-devos-ade` |
| launchd labels `io.bedrock-now.*` (and the systemd user unit on Linux) | `io.devos-ade.*` |
| `~/.config/bedrock-now` in the terminal's home | `~/.config/devos-ade` |

Ports do not change. An install of another project (a second copy) keeps its project, volumes and address and only gets the new names (keys, launchd label, folder names). The model files under `.state` (Hugging Face cache, LM Studio home, Ollama) move with the
folder in one rename; absolute paths that name the old folder (runtime records, launchd plists, `lms import` links,
session and Code page records) are rewritten, relative links are left as they are. Your account email in Open WebUI
is kept as it was, so chats, spend and git history stay yours. The update needs free disk for the copy of the
volumes plus 10% and says how long it expects to take before it stops anything. If a check fails nothing is changed.

The update can be interrupted and run again: it resumes, and on a resume it compares every volume it had already copied
with its source again and copies afresh any that changed in between. While the move is half done `./stack up` and
`./stack setup` refuse to start anything and name the two ways out: `./stack update` (resumes) and
`./stack migrate --rollback` (goes back). Your data stays in the old volumes, unchanged, until the move is verified.

**Stopped by v0.45.0 with "project devos-ade already has volumes (devos-ade_devos-ade-owner)".** v0.45.0 itself made that
volume, an empty marker, a moment before its move checked for one, on an install whose `.env` names no project (the
default install). Nothing was changed. `./stack update` gets v0.45.1 or later, and that resumes the move. On v0.45.0
alone: `docker volume rm devos-ade_devos-ade-owner && ./stack migrate --now`, then `cd ~/devos-ade && ./stack update --force`.

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

## The old copy

The volumes are copied, not moved, so for a while both exist. The update then checks the new install and, only when
every check passes, removes the old copy by itself and tells you what it removed and how much space that freed:

- each volume copy matched the original on file count, bytes and checksums;
- every service of the new project is up and healthy;
- on the running stack, Postgres holds at least the rows it held (counted before the move, table by table), Open WebUI
  shows the same users and chats, the git server lists every repository, sample files of the sandbox's home match, and
  the runtimes' records point into the moved folder.

If any check fails, nothing is removed and the update says which one. Your data is in the new volumes either way.
`./stack migrate --verify` runs the checks again and removes the old copy once they pass; `./stack migrate --remove-old`
removes it at once (it lists what it removes and asks). `./stack migrate` and `./stack status` show where things stand.

A few small leftovers (`.env.pre-devos-ade`, the `~/bedrock-now` link, the old launchd files) are removed by the next update.

## Going back

`./stack migrate --rollback` returns to the old project, folder, launchd labels and `.env`. It copies the current data of
the new volumes back into the old ones and checks the copy, so anything written since the move comes with you, and it
works whether or not the old copy has been removed. The new volumes are left as they are. `.env` is reversed from the
current file, so settings you changed since the move stay. `./stack rollback` (the older code) does this first by
itself, then goes back to the earlier version; if the move cannot be undone it stops and names the command to run.

## Tailscale

The Tailscale Service base, node name and tag are pinned in `.env` at the old values when remote access is on, so the
remote URL does not change. Renaming them is a tailnet admin change (the Service and tag are defined in your tailnet
policy); do it there and then change the matching `DEVOS_ADE_TAILSCALE_*` keys.

## Details of the checks

- The checks before the old copy is removed are written to disk first; the exact list of volumes and image tags that
  may be deleted is recorded when the copy is made, and nothing else is ever removed. A volume Docker cannot remove
  stays on the list and is reported; `./stack migrate --verify` continues, without running the checks again.
- Checked besides the data: every repository of the git server passes `git fsck --connectivity-only`, each installed
  runtime's program that ran before the move runs from the moved folder (one that did not run before, such as a
  half-finished install, is named in a note and does not keep the old copy), a runtime that was running is running
  after the update, and the
  sandbox's sample files matched while the stack was down.
- Files too big or binary to rewrite that still name the old folder are listed in
  `.state/migrate/paths-left-behind.txt` and in a warning; sqlite files are rewritten.
- The old `X-Requested-With: bedrock-now` header value of scripts is accepted for this one release.

