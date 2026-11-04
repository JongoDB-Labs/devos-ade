"""journey-terminal-git (JON-1059): a project made in the Terminal reaches the git server and the Code page, by the UI alone.

The owner's journey: in the Terminal tab, mkdir under /workspace, git init, a commit, then the terminal's git to the built-in git
server (`project remote`, `git push -u local main`: the sandbox's git trusts the server's certificate for gateway:8093 and gets
its login from the Code page, which the owner gives with Git hosts › Let Claude use this host — turned on here through its warning
and put back after) and `project add` (a Code project) or `project new NAME --keep` (a project kept on the server). Then the portal's
Git tab shows the repository with that commit, and the Code page lists the project; a repository nobody registered is offered under
Projects (Add as project) and another is declined (Not now: not offered again after a reload). The git server's API
(checks_git.forgejo) only verifies and tidies. No model calls. Runs when the terminal, the Code page and the git server are on."""

from __future__ import annotations

import re
import time

from playwright.sync_api import expect as see

import checks_git
from checks_browser import frame_of, login, shot
from checks_code import Code, _drop_projects, csp_clean, need_on as need_code, palette, ui_page
from checks_terminal import ON as TERMINAL_ON, new_shell_window, terminal_frame, type_line, unlock_in, wait_text, wait_xterm
from common import ENV, Skip, check, expect, origin

STAMP = str(int(time.time()))
A, B, C, D = (f"jt-{x}-{STAMP}" for x in "abcd")     # pushed + registered by `project add`; offered, added; offered, declined; `project new --keep`
NAME_A = f"Terminal journey {STAMP}"
COMMIT = f"journey commit {STAMP}"
OWNER = checks_git.OWNER


def local_host_row(page):
    """The built-in git server's row in the Git hosts dialog (./stack made it; its host name to the sandbox is gateway)."""
    dlg = page.get_by_test_id("git-hosts-dialog")
    see(dlg).to_be_visible(timeout=30000)
    row = dlg.locator("[data-testid=git-host][data-host=gateway]")
    see(row).to_have_count(1, timeout=30000)
    return dlg, row


def let_claude_use_local_git(page, on: bool) -> bool:
    """Git hosts › Local git server › Let Claude use this host, to `on` (through its warning when turning on). -> whether it changed."""
    palette(page, "git: git hosts")
    dlg, row = local_host_row(page)
    sw = row.get_by_test_id("git-host-claude")
    now = sw.get_attribute("aria-checked") == "true"
    if now == on:
        dlg.get_by_role("button", name="Close").click()
        return False
    sw.click()
    if on:
        page.get_by_test_id("git-claude-confirm").click()
    see(sw).to_have_attribute("aria-checked", "true" if on else "false", timeout=30000)
    dlg.get_by_role("button", name="Close").click()
    return True


@check("browser", "journey-terminal-git")
def journey_terminal_git(ctx):
    if not (TERMINAL_ON and checks_git.ON):
        raise Skip("needs the terminal and the built-in git server (tests/e2e/run.sh --terminal; LOCALGIT on)")
    need_code()
    turned_on = False
    made_repos = [A, D]
    try:
        # 1. the owner lets the terminal's git use the local git server (off by default), on the Code page
        page, rec = ui_page(ctx, "journey-terminal-git-hosts")
        turned_on = let_claude_use_local_git(page, True)

        # 2. in the Terminal tab: folders, git init, a commit each; the terminal's git to the server; the project command
        page, rec = ctx.page("journey-terminal-git-term")
        login(page)
        page.click(".tab[data-tab=terminal]")
        f = terminal_frame(page)
        unlock_in(f, ENV["PORTAL_PASSWORD"])
        f = terminal_frame(page)
        wait_xterm(f)
        new_shell_window(page, f)
        type_line(page, f, "clear; cd /workspace && for n in " + f"{A} {B} {C}" + "; do mkdir $n && git -C $n init -q -b main && echo $n > $n/README && git -C $n add README"
                  " && git -C $n -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m \"" + COMMIT + " $n\"; done; echo MADE-$((1+1))")
        wait_text(f, r"^MADE-2$", 60)
        type_line(page, f, f"cd /workspace/{A} && project remote && git push -u local main 2>&1 | tail -4; echo PUSHED-$((1+1))")
        out = wait_text(f, r"^PUSHED-2$", 90)
        expect(re.search(r"^Added the remote \"local\": https://gateway:8093/" + OWNER + "/" + re.escape(A) + r"\.git", out, re.M), f"project remote: {out[-700:]!r}")
        expect(re.search(r"set up to track", out) and "no login" not in out and "fatal" not in out and "Could not" not in out,
               f"git push from the terminal to the local git server: {out[-700:]!r}")
        type_line(page, f, f'project add --name "{NAME_A}"; echo ADDED-$((1+1))')
        out = wait_text(f, r"^ADDED-2$", 60)
        expect(re.search(r"^Added as a project: " + re.escape(NAME_A) + r"\.", out, re.M), f"project add: {out[-500:]!r}")
        type_line(page, f, f"cd /workspace && project new {D} --keep; echo KEPT-$((1+1))")
        out = wait_text(f, r"^KEPT-2$", 90)
        expect(re.search(r"^Kept on the local git server as " + OWNER + "/" + re.escape(D), out, re.M), f"project new --keep: {out[-600:]!r}")
        shot(page, "journey-terminal-git-1-terminal")

        # 3. the portal's Git tab shows the repository with the commit (the page of its address, in the frame)
        page.goto("about:blank")
        page.goto(origin() + f"/#git/{OWNER}/{A}")
        page.wait_for_selector('iframe[data-app="git"]', state="attached", timeout=30000)
        g = frame_of(page, "git")
        g.wait_for_url(re.compile(re.escape(f"/{OWNER}/{A}") + r"$"), timeout=30000)
        g.get_by_text(f"{COMMIT} {A}").first.wait_for(timeout=30000)
        shot(page, "journey-terminal-git-2-git")
        # (and Forgejo's API agrees: the commit, on main; the kept project's repository is there too)
        st, commits = checks_git.forgejo(ctx, "GET", f"/api/v1/repos/{OWNER}/{A}/commits?sha=main&limit=5")
        expect(st == 200 and any(COMMIT in c["commit"]["message"] for c in commits), f"the server's commits: HTTP {st} {str(commits)[:300]}")
        st, _ = checks_git.forgejo(ctx, "GET", f"/api/v1/repos/{OWNER}/{D}")
        expect(st in (200, 404), f"the kept project's repository: HTTP {st}")   # (404: appears with its first commit)

        # 4. the Code page: the project made by `project add` and the kept one are listed; B and C are offered, B is added, C declined
        page, rec = ui_page(ctx, "journey-terminal-git-code")
        for name in (NAME_A, D):
            see(page.get_by_test_id("project").filter(has_text=name).first).to_be_visible(timeout=30000)
        found = page.get_by_test_id("found-repo")
        see(found.filter(has_text=B)).to_have_count(1, timeout=30000)
        see(found.filter(has_text=C)).to_have_count(1)
        expect(found.filter(has_text=A).count() == 0 and found.filter(has_text=D).count() == 0, "a project is offered as one")
        shot(page, "journey-terminal-git-3-code")
        found.filter(has_text=C).get_by_test_id("found-decline").click()
        see(found.filter(has_text=C)).to_have_count(0, timeout=15000)
        found.filter(has_text=B).get_by_test_id("found-add").click()
        see(page.get_by_test_id("project").filter(has_text=B).first).to_be_visible(timeout=30000)
        see(found.filter(has_text=B)).to_have_count(0, timeout=15000)
        made_repos.append(B)
        # Not now is remembered: after a reload C is not offered again
        page.reload()
        see(page.get_by_test_id("conn")).to_have_text("Connected", timeout=30000)
        see(page.get_by_test_id("project").filter(has_text=B).first).to_be_visible(timeout=30000)
        page.wait_for_timeout(1500)
        expect(page.get_by_test_id("found-repo").filter(has_text=C).count() == 0, "a repository said Not now to is offered again")
        csp_clean(page, rec)
        return (f"in the Terminal: git init + commit in /workspace/{A}, `project remote` and `git push -u local main` to {OWNER}/{A} (shown in the Git tab "
                f"with the commit), `project add` ({NAME_A}), `project new {D} --keep`; the Code page lists them; {B} offered and added, {C} declined and not offered again")
    finally:
        # put it all back: the switch, the projects, the repositories on the server, the folders
        try:
            page, rec = ui_page(ctx, "journey-terminal-git-tidy")
            if turned_on:
                let_claude_use_local_git(page, False)
            c = Code.on(page, rec, goto=False)
            _drop_projects(c, {A, B, C, D})
            for n in (A, B, C, D):
                c.api("DELETE", f"/api/fs?path={n}")
        except Exception as e:  # noqa: BLE001 — a tidy-up that fails must not hide the check's own result
            print(f"  journey-terminal-git: tidy-up: {e}", flush=True)
        for n in made_repos:
            try:
                checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{OWNER}/{n}")
            except Exception:  # noqa: BLE001
                pass
