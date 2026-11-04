"""User journeys across Chat-less surfaces of the stack (JON-1058): one project followed through the Code page, the Terminal tab and the
portal's Git tab the way a person does it — clicks and typing only. The other checks test one feature each and often set things up
through the API; these do not. The API (and Forgejo's) is used here to verify what the UI showed and to clean up after, never to do a
step. Each journey takes every step it can and lists what did not work at the end (a step that fails does not hide the ones after it,
unless they cannot happen without it); Haiku only, short prompts.

  journey-code-to-git                 Code › New project (empty folder, kept on the local git server) › a Haiku session makes README.md and
                                      commits it › the project is pushed by itself › the portal's Git tab shows devos/<name> with README.md ›
                                      the Git panel's Push now (automatic pushes off, a commit made in the panel) says so and the file is there
  journey-terminal-folder-to-git      Terminal tab: mkdir, git init, a file, git commit › the Code page lists the folder as a project with no
                                      click and says it is kept on the local git server › the Git tab shows the repository with the
                                      terminal's commit › Remove from Code, and it does not come back; a folder with a package.json (no git)
                                      is a project too, with Start git here, and Start git here keeps it
  journey-code-terminal-commit        a kept project's ⋯ › Open a terminal here (the shell is in the project's folder) › a commit made
                                      there › the Git panel shows it › Push now › the Git tab shows it

Screenshots j1-*, j2-*, j3-* in out/browser/shots/."""

from __future__ import annotations

import json
import re
import time

from playwright.sync_api import expect as see

import checks_git
import checks_terminal as T
from checks_browser import Recorder, frame_of, login, shot
from checks_code import (ANSWERED, Code, _asked, _drop_projects, _last_session, _proj, _terminal_frame, _term_wait, _unfold, ask, csp_clean,
                         need_haiku, saved, ui_page)
from checks_journey_terminal import let_claude_use_local_git
from common import ENV, Skip, check, expect, origin

J1 = "e2e-j1-code"
J2 = "e2e-j2-term"
J3 = "e2e-j3-kept"
J4 = "e2e-j4-node"


class Journey:
    """The problems a journey met, as a person would put them: said at the end, all together."""

    def __init__(self, name):
        self.name, self.problems, self.seen = name, [], []

    def step(self, ok, said):
        (self.seen if ok else self.problems).append(said)
        return ok

    def done(self, ok_text):
        expect(not self.problems, f"{self.name}: {len(self.problems)} step(s) did not work as a user expects: " + " | ".join(self.problems))
        return ok_text


def need_git():
    need_haiku()
    if not checks_git.ON:
        raise Skip("the built-in git server is off in this throwaway (LOCALGIT=off)")


def clean(ctx, c, page, rec, names):
    """Nothing of an earlier run: project records, folders and repositories of these names gone, then a reload."""
    _drop_projects(c, names)
    there = {e["name"] for e in (c.api("GET", "/api/fs?path=.")["json"] or {}).get("entries", [])}
    for d in names:
        if d in there:
            c.api("DELETE", f"/api/fs?path={d}")
        checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{checks_git.OWNER}/{d}")
    page.reload()
    see(page.get_by_test_id("conn")).to_have_text("Connected", timeout=30000)
    return Code.on(page, rec, goto=False)


def repo_get(ctx, name, path=""):
    return checks_git.forgejo(ctx, "GET", f"/api/v1/repos/{checks_git.OWNER}/{name}{path}")


def wait_repo(ctx, name, path, timeout=45):
    """Forgejo's answer for the repository's `path` once it is 200 (or the last one after `timeout` s)."""
    t0, st, body = time.time(), 0, None
    while time.time() - t0 < timeout:
        st, body = repo_get(ctx, name, path)
        if st == 200:
            break
        time.sleep(2)
    return st, body


def open_git_panel(page):
    page.evaluate("() => document.activeElement && document.activeElement.blur()")
    page.keyboard.press("Control+Shift+G")
    see(page.get_by_test_id("git-panel")).to_be_visible(timeout=30000)


def extra_page(ctx, name):
    """Another browser (a context of its own, signed in separately) beside the Code page's: ctx.page closes the others, a person's second
    window does not — the Git tab and the Terminal tab are opened like that, while the Code page stays where it was."""
    from suite import DEVICES   # (the suite's own: imported when the check runs, the module is loaded by then)
    c = ctx.browser.new_context(locale="en-US", timezone_id="UTC", accept_downloads=True, **DEVICES["desktop"])
    ctx._contexts.append(c)
    c.add_init_script("(o => { try { if (location.origin === o && !localStorage.getItem('bn.tour')) "
                      "localStorage.setItem('bn.tour', JSON.stringify({open: false})); } catch (e) {} })"
                      f"({json.dumps(origin())});")
    rec = Recorder(name)
    p = rec.attach(c.new_page())
    p.set_default_timeout(30000)
    return p, rec


def git_tab(ctx, name, repo, want_text=None):
    """The portal's Git tab in a browser of its own (signed in by the portal, as a person opens it): the repository's page by its
    address (#git/<owner>/<repo>), the front page's repository list first. Returns (problems, frame text)."""
    gp, grec = extra_page(ctx, name)
    login(gp)
    gp.click(".tab[data-tab=git]")
    f = frame_of(gp, "git")
    f.wait_for_selector("#navbar", timeout=30000)
    gp.wait_for_timeout(1500)
    front = f.locator("body").inner_text()
    gp.goto("about:blank")
    gp.goto(f"{origin()}/#git/{checks_git.OWNER}/{repo}")
    f = frame_of(gp, "git")
    f.wait_for_url(re.compile(re.escape(f"/{checks_git.OWNER}/{repo}") + r"/?$"), timeout=30000)
    f.wait_for_function("(n) => !!document.body && document.body.innerText.includes(n)", arg=repo, timeout=30000)
    gp.wait_for_timeout(1500)
    text = f.locator("body").inner_text()
    shot(gp, f"{name}-repo")
    grec.save()
    return gp, front, text


def haiku_session_in(page, project_id):
    """New session in the project, on Haiku (the model picker), by the clicks of a person."""
    page.get_by_test_id("side-sessions").click()
    page.get_by_test_id("model-picker").click()
    page.get_by_test_id("model-haiku").click()
    old = _last_session(page)
    _unfold(page, project_id)
    _proj(page, project_id).get_by_test_id("project-new-session").click()
    page.wait_for_function("(old) => { const s = (JSON.parse(localStorage.getItem('bn.code.v1') || '{}').lastSession) || '';"
                           " return s.length === 36 && s !== old; }", arg=old, timeout=60000)
    return _last_session(page)


def drive_turn(page, timeout=180):
    """Answer the permission cards of the turn with Allow once until the prompt `ask` sent last has its turn end."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if page.evaluate(ANSWERED, _asked[id(page)]):
            return True
        btn = page.get_by_test_id("perm-once")
        if btn.count():
            try:
                btn.first.click(timeout=3000)
            except Exception:  # noqa: BLE001 — the card went away as it was clicked
                pass
        page.wait_for_timeout(500)
    return False


def new_project(page, name=None, kind="empty", folder=None, keep=True):
    page.get_by_test_id("side-sessions").click()
    page.get_by_test_id("new-project").click()
    dlg = page.get_by_test_id("new-project-dialog")
    if kind == "empty":
        page.get_by_test_id("new-project-name").fill(name)
    else:
        page.get_by_test_id("new-project-folder").check()
        sel = page.get_by_test_id("new-project-folder-pick")
        t0 = time.time()
        while time.time() - t0 < 30 and folder not in sel.locator("option").evaluate_all("els => els.map(e => e.value)"):
            page.wait_for_timeout(500)
        sel.select_option(folder)
    box = page.get_by_test_id("new-project-keep")
    see(box).to_be_visible(timeout=30000)
    expect(box.is_checked(), "Keep it on your local git server is not ticked by default")
    if not keep:
        box.uncheck()
    return dlg


def terminal_tab(ctx, name):
    """The portal's Terminal tab in a browser of its own, unlocked, with a shell window open in /workspace."""
    p, rec = extra_page(ctx, name)
    login(p)
    p.click(".tab[data-tab=terminal]")
    f = T.terminal_frame(p)
    if f.locator("h1", has_text="Unlock the terminal").count() or f.locator("#password").count():
        T.unlock_in(f, ENV["PORTAL_PASSWORD"])
        f = T.terminal_frame(p)
    T.wait_xterm(f)
    T.new_shell_window(p, f)
    return p, rec, f


def say(p, f, line, wait=None, timeout=30):
    T.type_line(p, f, line)
    return T.wait_text(f, wait, timeout) if wait else None


@check("browser", "journey-code-to-git")
@saved
def code_to_git(ctx):
    need_git()
    owner = checks_git.OWNER
    page, rec = ui_page(ctx, "journey-code-to-git")
    c = Code.on(page, rec, goto=False)
    j = Journey("journey-code-to-git")
    c = clean(ctx, c, page, rec, (J1,))
    sids = []
    try:
        # 1. Code › New project: an empty folder, kept on the local git server (ticked)
        dlg = new_project(page, J1)
        shot(page, "j1-1-new-project")
        page.get_by_test_id("new-project-create").click()
        see(dlg).to_have_count(0, timeout=60000)
        see(page.get_by_test_id("project-chip-name")).to_have_text(J1, timeout=30000)
        j.step(page.get_by_test_id("toast").filter(has_text="kept on your local git server").count() > 0
               or page.get_by_test_id("toast").last.inner_text().count("kept") > 0, "no toast said the project is kept on the local git server")
        pid = next(x["id"] for x in c.api("GET", "/api/projects")["json"]["projects"] if x["root"] == J1)
        # (the project is in the Git tab at once: its repository is made with the keeping, not with a first commit)
        st, _ = repo_get(ctx, J1)
        j.step(st == 200, f"{owner}/{J1} is not on the git server right after New project with Keep ticked (HTTP {st}): a person looking in the Git tab finds nothing")
        open_git_panel(page)
        see(page.get_by_test_id("keep-repo")).to_have_text(f"{owner}/{J1}", timeout=30000)
        j.step(page.get_by_test_id("keep-not-made").count() == 0, "the Git panel says the repository is not made yet")
        shot(page, "j1-2-git-panel-kept")
        # 2. a Haiku session there: create README.md and commit it
        sid = haiku_session_in(page, pid)
        sids.append(sid)
        ask(page, "Create a file README.md in the current folder with exactly one line: Hello from the journey. Then run git add README.md and "
                  "git commit -m 'Add README' and tell me whether the commit worked.")
        ended = drive_turn(page)
        shot(page, "j1-3-session-turn")
        expect(ended, "Claude's turn did not end within 180 s")
        answer = page.get_by_test_id("msg-claude").last.inner_text()
        # 3. after the turn the project is pushed by itself
        st, f = wait_repo(ctx, J1, "/contents/README.md?ref=main", 60)
        pushed = st == 200
        k = c.api("GET", f"/api/projects/{pid}/keep")["json"] or {}
        j.step(pushed, f"README.md was not pushed by itself within 60 s of the turn (HTTP {st}); the keep record: pushedAt {k.get('pushedAt')}, "
                       f"unpushed {k.get('unpushed')}, lastError {k.get('lastError')}; Claude said: {answer[:200]!r}")
        # 4. the portal's Git tab: devos/<name> with README.md
        gp, front, text = git_tab(ctx, "journey-code-to-git-git", J1, "README.md")
        j.step(J1 in front, f"the Git tab's front page does not list {J1}")
        j.step("README.md" in text, f"the Git tab's page of {owner}/{J1} does not show README.md")
        shot(gp, "j1-4-git-tab")
        gp.close()
        # 5. the Git panel: Push now says so (automatic pushes off; a commit made in the panel is not on the server until then)
        open_git_panel(page)
        page.get_by_test_id("keep-auto").uncheck()
        c.api("PUT", f"/api/fs/file?path={J1}/second.txt", {"text": "a second file\n"})
        page.get_by_test_id("git-refresh").click()
        row = page.locator("[data-testid=git-file][data-path='second.txt']")
        see(row).to_have_count(1, timeout=30000)
        row.hover()
        row.get_by_test_id("git-stage").click()
        see(page.locator("[data-testid=git-file][data-path='second.txt'][data-group=staged]")).to_have_count(1, timeout=30000)
        page.get_by_test_id("git-message").fill("Add second.txt")
        page.get_by_test_id("git-commit").click()
        see(page.locator("[data-testid=git-file][data-path='second.txt']")).to_have_count(0, timeout=30000)
        time.sleep(4)
        st, _ = repo_get(ctx, J1, "/contents/second.txt?ref=main")
        j.step(st == 404, f"with automatic pushes off, a commit was on the server before Push now (HTTP {st})")
        page.get_by_test_id("keep-push").click()
        toast = page.get_by_test_id("toast").filter(has_text="Pushed to your local git server")
        try:
            see(toast).to_have_count(1, timeout=60000)
            j.step(True, "")
        except AssertionError:
            j.step(False, "Push now did not say 'Pushed to your local git server.'")
        shot(page, "j1-5-push-now")
        st, _ = wait_repo(ctx, J1, "/contents/second.txt?ref=main", 30)
        j.step(st == 200, f"second.txt is not on the server after Push now (HTTP {st})")
        csp_clean(page, rec)
    finally:
        try:
            for sid in sids:
                c.api("DELETE", f"/api/sessions/{sid}")
            _drop_projects(c, (J1,))
            c.api("DELETE", f"/api/fs?path={J1}")
            checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{owner}/{J1}")
        except Exception:  # noqa: BLE001 — cleanup never hides the failure
            pass
    return j.done(f"New project (kept) › Haiku session made README.md and committed › pushed by itself › the Git tab shows {owner}/{J1} with README.md › "
                  "Push now said so and the commit was there")


@check("browser", "journey-terminal-folder-to-git")
@saved
def terminal_folder_to_git(ctx):
    need_git()
    owner = checks_git.OWNER
    page, rec = ui_page(ctx, "journey-terminal-folder-to-git")
    c = Code.on(page, rec, goto=False)
    j = Journey("journey-terminal-folder-to-git")
    c = clean(ctx, c, page, rec, (J2, J4))
    msg = "Commit from the terminal"
    turned_on = False
    try:
        # 0. Git hosts › Let Claude use this host is on (the stack's default; turned on here when it is not, and put back after)
        turned_on = let_claude_use_local_git(page, True)
        # 1. the Terminal tab: a folder under /workspace, git init, a file, a commit (typed as a person types); and a folder with a package.json
        tp, trec, f = terminal_tab(ctx, "journey-terminal-folder-to-git-term")
        say(tp, f, f"mkdir /workspace/{J2} && cd /workspace/{J2}", rf"^terminal /workspace/{J2} \$")
        say(tp, f, "git init -q -b main && echo hello > hello.txt && git add hello.txt", r"\$\s*$")
        say(tp, f, f"git commit -q -m '{msg}'; echo commit-exit-$?", r"^commit-exit-\d+$")
        out = T.term_text(f)
        shot(tp, "j2-1-terminal-commit")
        j.step("commit-exit-0" in out, f"git commit in the terminal failed: {out[-300:]!r}")
        say(tp, f, "git log --oneline | head -n 3", re.escape(msg))
        say(tp, f, f"mkdir /workspace/{J4} && echo '{{}}' > /workspace/{J4}/package.json", r"\$\s*$")
        trec.save()
        # 2. the Code page, with no click: the folder is a project by itself, and the Projects tab says it is kept on the local git server
        page.reload()
        see(page.get_by_test_id("conn")).to_have_text("Connected", timeout=30000)
        c = Code.on(page, rec, goto=False)
        page.get_by_test_id("side-sessions").click()
        added = page.get_by_test_id("added-project")
        try:
            see(added.filter(has_text=J2)).to_have_count(1, timeout=60000)
            see(added.filter(has_text=J2).get_by_test_id("added-text")).to_contain_text("kept on your local git server", timeout=90000)
        except AssertionError:
            j.step(False, f"the Projects tab does not say {J2} was added from the workspace and kept on the local git server, with no click")
        pid = next((x["id"] for x in c.api("GET", "/api/projects")["json"]["projects"] if x["root"] == J2), None)
        j.step(pid is not None, f"no project of {J2}/ without a click")
        shot(page, "j2-2-added-from-workspace")
        # (the folder with a package.json: a project, no git yet, Start git here — then the same rule keeps it)
        try:
            see(added.filter(has_text=J4).get_by_test_id("added-text")).to_contain_text("no git yet", timeout=60000)
            added.filter(has_text=J4).get_by_test_id("added-git").click()
            see(added.filter(has_text=J4).get_by_test_id("added-text")).to_contain_text("kept on your local git server", timeout=120000)
        except AssertionError:
            j.step(False, f"{J4} (a package.json, no git) was not added with Start git here, or Start git here did not lead to keeping it")
        shot(page, "j2-2-added-node")
        if pid:
            _proj(page, pid).get_by_test_id("project-show").click()
            see(page.get_by_test_id("project-chip-name")).to_have_text(J2, timeout=30000)
        open_git_panel(page)
        try:
            see(page.get_by_test_id("keep-repo")).to_have_text(f"{owner}/{J2}", timeout=30000)
        except AssertionError:
            j.step(False, "the Git panel does not say the folder is kept on the local git server")
        see(page.get_by_test_id("git-log-entry").first).to_be_visible(timeout=30000) if page.get_by_test_id("git-log-entry").count() else None
        shot(page, "j2-3-git-panel")
        # 3. the Git tab shows the repository with the terminal's commit
        st, _ = wait_repo(ctx, J2, "/commits?limit=1", 60)
        j.step(st == 200, f"{owner}/{J2} has no commit on the server within 60 s of keeping the folder (HTTP {st}); the first push should take it")
        gp, front, text = git_tab(ctx, "journey-terminal-folder-to-git-git", J2, "hello.txt")
        j.step(J2 in front, f"the Git tab's front page does not list {J2}")
        j.step("hello.txt" in text, f"the Git tab's page of {owner}/{J2} does not show hello.txt")
        j.step(msg in text, f"the Git tab's page of {owner}/{J2} does not show the terminal's commit message {msg!r}")
        shot(gp, "j2-4-git-tab")
        gp.close()
        # 4. Remove from Code (the notice's button): the project goes, and it is not added again by the next looks
        page.get_by_test_id("side-sessions").click()
        added.filter(has_text=J2).get_by_test_id("added-remove").click()
        try:
            see(added.filter(has_text=J2)).to_have_count(0, timeout=30000)
        except AssertionError:
            j.step(False, f"Remove from Code did not take the notice of {J2} away")
        for _ in range(2):
            page.wait_for_timeout(4000)    # (the backend looks at the workspace after every list, at most every 3 s)
            page.reload()
            see(page.get_by_test_id("conn")).to_have_text("Connected", timeout=30000)
        gone = not any(x["root"] == J2 for x in c.api("GET", "/api/projects")["json"]["projects"])
        j.step(gone, f"{J2} was added again after Remove from Code")
        csp_clean(page, rec)
    finally:
        try:
            if turned_on:
                let_claude_use_local_git(page, False)
            _drop_projects(c, (J2, J4))
            for d in (J2, J4):
                c.api("DELETE", f"/api/fs?path={d}")
            for d in (J2, J4):
                checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{owner}/{d}")
        except Exception:  # noqa: BLE001 — cleanup never hides the failure
            pass
    return j.done(f"a folder made, git-init'd and committed in the Terminal tab › a project of the Code page with no click, said to be kept on the local git server › the Git tab shows {owner}/{J2} with hello.txt and the commit › Remove from Code, and it stayed removed; a package.json folder › Start git here › kept")


@check("browser", "journey-code-terminal-commit")
@saved
def code_terminal_commit(ctx):
    need_git()
    owner = checks_git.OWNER
    page, rec = ui_page(ctx, "journey-code-terminal-commit")
    c = Code.on(page, rec, goto=False)
    j = Journey("journey-code-terminal-commit")
    c = clean(ctx, c, page, rec, (J3,))
    msg = "Commit from the project terminal"
    try:
        dlg = new_project(page, J3)
        page.get_by_test_id("new-project-create").click()
        see(dlg).to_have_count(0, timeout=60000)
        see(page.get_by_test_id("project-chip-name")).to_have_text(J3, timeout=30000)
        pid = next(x["id"] for x in c.api("GET", "/api/projects")["json"]["projects"] if x["root"] == J3)
        # 1. the project's ⋯ › Open a terminal here: the shell is in the project's folder
        page.get_by_test_id("side-sessions").click()
        _unfold(page, pid)
        _proj(page, pid).get_by_test_id("project-menu").click()
        page.get_by_test_id("project-menu-terminal").click()
        cwd = f"/workspace/{J3}"
        try:
            see(page.get_by_test_id("toast").last).to_contain_text(f"A terminal window in {cwd}", timeout=30000)
        except AssertionError:
            j.step(False, f"no toast said 'A terminal window in {cwd}'")
        see(page.get_by_test_id("terminal")).to_be_visible(timeout=30000)
        tf = _terminal_frame(page)
        if tf.locator("h1", has_text="Unlock the terminal").count():
            T.unlock_in(tf, ENV["PORTAL_PASSWORD"])
            tf = _terminal_frame(page)
        tf.locator(".xterm").wait_for(timeout=30000)
        try:
            _term_wait(tf, re.escape(cwd) + r" \$\s*$", 60)
        except AssertionError as e:
            j.step(False, f"the terminal window is not in the project's folder: {str(e)[-200:]}")
        shot(page, "j3-1-project-terminal")
        # 2. commit a file there (the project is a git repository already: kept)
        T.type_line(page, tf, "pwd && echo from the terminal > term.txt && git add term.txt && "
                              f"git commit -q -m '{msg}'; echo commit-exit-$?")
        out = T.wait_text(tf, r"^commit-exit-\d+$", 30)
        j.step("commit-exit-0" in out, f"git commit in the project's terminal failed: {out[-300:]!r}")
        shot(page, "j3-2-terminal-commit")
        # 3. the Code page's Git panel shows the commit
        open_git_panel(page)
        page.get_by_test_id("git-refresh").click()
        try:
            commits = page.get_by_test_id("git-log").get_by_role("button").first
            if page.get_by_test_id("git-log-entry").count() == 0 and commits.count():
                commits.click()
            see(page.get_by_test_id("git-log-entry").filter(has_text=msg)).to_have_count(1, timeout=30000)
        except AssertionError:
            j.step(False, f"the Git panel's commits do not show {msg!r} (a refresh was clicked)")
        shot(page, "j3-3-git-panel")
        # 4. Push now; the Git tab shows it
        try:
            page.get_by_test_id("keep-push").click()
            see(page.get_by_test_id("toast").filter(has_text="Pushed to your local git server")).to_have_count(1, timeout=60000)
        except AssertionError:
            j.step(False, "Push now did not say 'Pushed to your local git server.'")
        st, _ = wait_repo(ctx, J3, "/contents/term.txt?ref=main", 30)
        j.step(st == 200, f"term.txt is not on the server after Push now (HTTP {st})")
        gp, front, text = git_tab(ctx, "journey-code-terminal-commit-git", J3, "term.txt")
        j.step(J3 in front, f"the Git tab's front page does not list {J3}")
        j.step("term.txt" in text and msg in text, f"the Git tab's page of {owner}/{J3} does not show term.txt with the commit {msg!r}")
        shot(gp, "j3-4-git-tab")
        gp.close()
        csp_clean(page, rec)
    finally:
        try:
            _drop_projects(c, (J3,))
            c.api("DELETE", f"/api/fs?path={J3}")
            checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{owner}/{J3}")
        except Exception:  # noqa: BLE001 — cleanup never hides the failure
            pass
    return j.done(f"a kept project's Open a terminal here (in {J3}/) › a commit typed there › the Git panel showed it › Push now › the Git tab shows {owner}/{J3} with it")

