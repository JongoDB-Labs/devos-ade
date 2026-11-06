"""Chat to Git (JON-1060): a project started from a chat, in Chromium, UI only, Haiku only. Chat's "Make it a project" button
(owui/functions/make_project.py) hands the conversation to the Code page as text; the Code page's dialog shows it read-only and
creates nothing until Create; the project is made and kept on the built-in git server; a new session continues the chat (the
conversation quoted as text from the chat) and is asked to write README.md; the Git tab then shows the repository with README.md.
Chat itself never touches the files: the check asserts that nothing exists until Create and that the Chat page holds no project.
Verified through Forgejo's API (checks_git.forgejo) as well as the Git tab. One chat answer, one session turn to read the
chat and one to write the file — all on the Haiku model, never Opus."""

from __future__ import annotations

import re
import time

from playwright.sync_api import expect as see

import checks_git
import checks_terminal as T
from checks_browser import _last_answer, chat_frame, frame_of, login, owui_api, shot
from checks_code import CODE, HAIKU, LOCKED_OK, Code, _drop_projects, ask, code_frame, need_haiku, unlock_page
from common import ENV, Skip, check, expect, need, origin


@check("browser", "journey-chat-to-git")
def chat_to_git(ctx):
    need("open-webui")
    need_haiku()
    if not checks_git.ON:
        raise Skip("the built-in git server is off in this throwaway (LOCALGIT=off)")
    owner = checks_git.OWNER
    name = f"e2e-journey-{int(time.time())}"
    page, rec = ctx.page("journey-chat-to-git")
    login(page)
    chat_id = c = None
    try:
        # 1. Chat, on Haiku: a short chat about the project
        fl, f = chat_frame(page, f"?models={HAIKU}")
        sel = fl.locator("#model-selector-model-button").get_attribute("aria-label") or ""
        expect("Haiku" in sel, f"Chat's model {sel!r} is not Haiku")
        fl.locator("#chat-input").click()
        fl.locator("#chat-input").press_sequentially(f"I want to start a small project called {name}: a command line tool that prints a greeting. Answer in one short sentence.")
        fl.locator("#chat-input").press("Enter")
        t0, answer = time.time(), ""
        while time.time() - t0 < 120:
            answer = _last_answer(f) or ""
            if "≈" in answer:
                break
            page.wait_for_timeout(250)
        expect("≈" in answer, f"no complete answer within 120 s ({answer[:120]!r})")
        cid = re.search(r"/c/([0-9a-f-]{36})", f.url)
        chat_id = cid.group(1) if cid else None
        # 2. Make it a project: the button under the answer (a global action, installed by ./stack setup)
        button = fl.locator("#action-make_project, button:has(img[alt='Make it a project'])").last
        button.wait_for(state="visible", timeout=30000)
        shot(page, "journey-1-chat-answer")
        button.click()
        # 3. The Code page's dialog: the conversation read-only, a name, kept ticked; nothing exists yet
        cf = code_frame(page, timeout=60)
        unlock_page(cf)   # (locked in this fresh browser: the link is kept through the unlock)
        cf = code_frame(page)
        dlg = cf.get_by_test_id("handoff-dialog")
        see(dlg).to_be_visible(timeout=90000)
        see(cf.get_by_test_id("handoff-text")).to_contain_text(name)
        text = cf.get_by_test_id("handoff-text").inner_text()
        expect("≈" not in text, f"the cost line is in the conversation: {text[-120:]!r}")
        expect(text.lstrip().startswith("You:"), f"the conversation starts {text[:60]!r}")
        see(cf.get_by_test_id("handoff-keep")).to_be_checked(timeout=30000)
        see(cf.get_by_test_id("handoff-continue")).to_be_checked()
        expect(cf.get_by_test_id("handoff-name").input_value().strip() != "", "no name from the chat's title")
        expect(cf.get_by_test_id("handoff-text").evaluate("e => e.tagName") == "PRE" and cf.get_by_test_id("handoff-text").locator("textarea, input").count() == 0,
               "the conversation can be edited")
        c = Code.on(cf, rec, goto=False)
        expect(name not in {x.get("root") for x in c.api("GET", "/api/projects")["json"]["projects"]}, "a project before Create")
        st, _ = checks_git.forgejo(ctx, "GET", f"/api/v1/repos/{owner}/{name}")
        expect(st == 404, f"a repository before Create: HTTP {st}")
        cf.get_by_test_id("handoff-name").fill(name)
        shot(page, "journey-2-handoff-dialog")
        cf.get_by_test_id("handoff-create").click()
        see(dlg).to_have_count(0, timeout=90000)
        # the project is made and kept; a session reads the chat (Haiku: the page's default) and waits
        proj = next((x for x in c.api("GET", "/api/projects")["json"]["projects"] if x.get("root") == name), None)
        expect(proj, f"no project {name} after Create")
        see(cf.get_by_test_id("turn-end")).to_have_count(1, timeout=150000)
        sid = cf.evaluate("JSON.parse(localStorage.getItem('bn.code.v1')).lastSession")
        s = next((x for x in c.api("GET", "/api/state")["json"]["sessions"] if x["id"] == sid), {})
        expect(s.get("model") == HAIKU, f"the session's model {s.get('model')!r} (want {HAIKU})")
        keep = c.api("GET", f"/api/projects/{proj['id']}/keep")["json"]
        expect(keep.get("state") == "kept", f"the project is not kept: {keep}")
        # 4. The session continues the chat: asked to write README.md and commit it (the kept project pushes by itself)
        ask(cf, f"Use the Write tool to create README.md with one line saying what {name} is. Then use the Bash tool to run exactly this command: "
                "git add README.md && git -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m 'Add README'. Then reply with the word done.")
        t0 = time.time()
        while time.time() - t0 < 240 and cf.get_by_test_id("turn-end").count() < 2:
            if cf.get_by_test_id("permission").count():
                cf.get_by_test_id("perm-once").first.click()
            page.wait_for_timeout(1000)
        expect(cf.get_by_test_id("turn-end").count() >= 2, "the session did not finish writing README.md within 240 s")
        shot(page, "journey-3-code-session")
        # 5. Forgejo has the repository with README.md (pushed by the kept project after the turn), and so does the Git tab
        t0, st = time.time(), 0
        while time.time() - t0 < 120 and st != 200:
            st, _ = checks_git.forgejo(ctx, "GET", f"/api/v1/repos/{owner}/{name}/contents/README.md?ref=main")
            if st != 200:
                time.sleep(3)
        expect(st == 200, f"README.md is not in {owner}/{name} on the git server after 120 s: HTTP {st}")
        page.evaluate("p => { location.hash = '#git/' + p; }", f"{owner}/{name}")
        gf = frame_of(page, "git")
        gf.wait_for_url(re.compile(re.escape(f"/{owner}/{name}") + r"/?$"), timeout=30000)
        see(gf.locator("body")).to_contain_text("README.md", timeout=30000)
        shot(page, "journey-4-git-tab")
        probs = rec.problems(allow=LOCKED_OK + [r"^401 GET " + re.escape(CODE) + r"/\?handoff=", r"No token found in localStorage"])
        rec.save()
        expect(not probs, f"errors: {probs[:6]}")
        # 6. (JON-1158) the Terminal tab's Projects panel lists the new project too, as kept: one list for Chat's project, Code and Terminal
        page.goto(origin() + "/")
        page.click(".tab[data-tab=terminal]")
        tf = T.terminal_frame(page)
        if tf.locator("h1", has_text="Unlock the terminal").count() or tf.locator("#password").count():
            T.unlock_in(tf, ENV["PORTAL_PASSWORD"])
        try:
            T.show_projects_widget(page)
            T.wait_panel(page, f"/workspace/{name} is not listed as a kept project",
                         lambda rs: any(x["path"] == f"/workspace/{name}" and x["id"] == proj["id"] and "kept" in x["flags"] for x in rs))
            shot(page, "journey-5-terminal-panel")
        finally:
            T.reset_layout(page)
        return f"{HAIKU}: a chat about {name} → Make it a project → the dialog (read-only, nothing made) → Create → kept, a session read the chat → README.md in {owner}/{name} and in the Git tab → listed (kept) in the Terminal tab's Projects panel"
    finally:
        # what this check made: its session, the project's record and folder, the repository, the chat
        try:
            if c is not None:
                st = c.api("GET", "/api/state")["json"]
                for x in st.get("sessions", []):
                    if x.get("open") and (x.get("title") or "").startswith("From the chat"):
                        c.api("DELETE", f"/api/sessions/{x['id']}")
                _drop_projects(c, (name,))
                c.api("DELETE", f"/api/fs?path={name}")
        except Exception:  # noqa: BLE001 — tidying never fails the check
            pass
        try:
            checks_git.forgejo(ctx, "DELETE", f"/api/v1/repos/{owner}/{name}")
            if chat_id:
                owui_api(frame_of(page, "chat"), f"/api/v1/chats/{chat_id}", "DELETE")
        except Exception:  # noqa: BLE001
            pass
