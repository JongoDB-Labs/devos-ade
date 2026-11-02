"""The Git page and its search (JON-979; static/git.js, static/search.js, portal/gitsearch.py), in Chromium against the throwaway
(the built-in git server is on, as on a new install; no model calls). A repository, an issue and a pull request are made on
the throwaway's own git server first (Forgejo's API through its Caddy site, with the portal session and the owner's password
from the throwaway's .env), and removed after: the Git tab is in the sidebar after Files with a pop-out and frames the
git server signed in as the owner; #git/<owner>/<repo>/issues/N opens that issue in the frame; the search's Git group finds
the repository, the issue and the pull request and Enter opens each; the portal's read-only token is in no page, answer or
log. With the git server off the tab says so (unit: portal/tests/test_gitsearch.py; switching it needs the helper)."""

from __future__ import annotations

import base64
import json
import re
import time
from urllib.parse import quote

from common import ENV, Skip, check, expect, http, origin
from checks_browser import frame_of, login, shot

ON = ENV.get("LOCALGIT", "on").strip().lower() not in ("off", "false", "0", "no")
OWNER = "devos"
STAMP = str(int(time.time()))
REPO = f"e2e-git-{STAMP}"
DESC = f"Notes for the zebra crossing {STAMP}"
ISSUE = f"Fix the zebra crossing {STAMP}"
PR = f"Add the zebra crossing {STAMP}"
FORM = {"Content-Type": "application/json", "Accept": "application/json"}
made: dict = {}


def need_on():
    if not ON:
        raise Skip("the built-in git server is off in this throwaway (LOCALGIT=off)")


def forgejo(ctx, method: str, path: str, body=None) -> tuple[int, dict | list | str]:
    """One call of Forgejo's API through its Caddy site: the portal session passes Caddy's check, the owner's password is Forgejo's."""
    basic = base64.b64encode(f"{OWNER}:{ENV['LOCALGIT_ADMIN_PASSWORD']}".encode()).decode()
    r = http(method, "git", path, {**FORM, "Authorization": f"Basic {basic}"}, json.dumps(body) if body is not None else None, cookie=ctx.session())
    try:
        return r.status, r.json()
    except ValueError:
        return r.status, r.text()


def make(ctx):
    """The repository (with a first commit), an issue and a pull request, once for the checks of this file."""
    if made:
        return made
    st, _ = forgejo(ctx, "POST", "/api/v1/user/repos", {"name": REPO, "description": DESC, "auto_init": True, "default_branch": "main", "private": True})
    expect(st == 201, f"the repository was not made: HTTP {st}")
    made["repo"] = True
    st, i = forgejo(ctx, "POST", f"/api/v1/repos/{OWNER}/{REPO}/issues", {"title": ISSUE})
    expect(st == 201 and i["number"] == 1, f"the issue was not made: HTTP {st}")
    st, _ = forgejo(ctx, "POST", f"/api/v1/repos/{OWNER}/{REPO}/contents/crossing.txt",
                    {"content": base64.b64encode(b"zebra\n").decode(), "branch": "main", "new_branch": "crossing", "message": "Add a crossing"})
    expect(st == 201, f"the branch was not made: HTTP {st}")
    st, p = forgejo(ctx, "POST", f"/api/v1/repos/{OWNER}/{REPO}/pulls", {"head": "crossing", "base": "main", "title": PR})
    expect(st == 201, f"the pull request was not made: HTTP {st}")
    made["pr"] = p["number"]
    return made


def tidy(ctx):
    if made.get("repo"):
        forgejo(ctx, "DELETE", f"/api/v1/repos/{OWNER}/{REPO}")
        made.clear()


def open_search(page):
    """The search, open: by the sidebar's button, only while it is closed (Ctrl+K toggles it, and after a result opens the focus
    can be in the Git frame, whose page does not pass the keys on)."""
    if not page.locator("#search[open]").count():
        page.click("#search-btn")
        page.wait_for_selector("#search[open]")


def ask(page, text: str) -> list[str]:
    """Search for TEXT: the Git group's option texts once the portal's Git answer for TEXT is in and drawn (the search keeps its
    last answer while it is closed, so until then the group can show an older one; no group: nothing found)."""
    open_search(page)
    with page.expect_response(lambda r: f"/api/search/git?q={quote(text, safe='')}" in r.url, timeout=30000):
        page.fill("#search-input", text)
    page.wait_for_function("() => !document.querySelector('#sg-git ~ .search-busy')", timeout=15000)
    return page.locator("#search-list [role=group][aria-labelledby=sg-git] .search-opt").all_inner_texts()


@check("browser", "git-nav-item-and-embed")
def nav_and_embed(ctx):
    need_on()
    page, rec = ctx.page("git-nav")
    login(page)
    tab = page.locator(".tabs .tab[data-tab=git]")
    tab.wait_for(timeout=15000)
    labels = page.locator(".tabs .tab").evaluate_all("els => els.map(e => e.dataset.tab)")
    expect(labels.index("git") == labels.index("files") + 1, f"the Git tab is not right after Files: {labels}")
    pop = page.locator("a.popout[data-app=git]")
    expect(pop.get_attribute("href") == origin("git") + "/" and pop.get_attribute("target") == "_blank", f"pop-out: {pop.get_attribute('href')}")
    tab.click()
    f = frame_of(page, "git")
    expect(page.locator('iframe[data-app="git"]').get_attribute("title") == "Git — your local git server", "the frame's name")
    expect(page.evaluate("location.hash") == "#git", f"the address: {page.evaluate('location.hash')}")
    # Caddy signed the owner in after the portal's check: Forgejo's own page shows the account, with no sign-in form
    f.wait_for_selector("#navbar", timeout=30000)
    expect(f.locator("#navbar .user-menu, #navbar [data-tooltip-content]").count() > 0 or OWNER in f.locator("#navbar").inner_text(),
           "the frame is not signed in as the owner")
    expect("/user/login" not in f.url, f"the frame shows the sign-in form: {f.url}")
    shot(page, "git-1-embed")
    with page.context.expect_page() as popped:
        pop.click()
    win = rec.attach(popped.value)
    win.wait_for_selector("#navbar", timeout=30000)
    expect(win.url.startswith(origin("git")), f"the pop-out opened {win.url}")
    probs = rec.problems(host_filter="git.")
    rec.save()
    expect(not probs, f"errors: {probs}")
    return f"Git after Files, a pop-out to {origin('git')}/, the git server signed in as {OWNER} in the frame (title and address as the page says)"


@check("browser", "git-phone-more-sheet")
def phone(ctx):
    need_on()
    page, rec = ctx.page("git-phone", device="phone")
    login(page)
    expect(not page.locator(".tabs .git-item").is_visible(), "Git is in the phone's bottom bar")
    page.click("#more-btn")
    link = page.locator("#more-git")
    link.wait_for(timeout=10000)
    link.click()
    f = frame_of(page, "git")
    f.wait_for_selector("body", timeout=30000)
    shot(page, "git-2-phone")
    rec.save()
    return "under More on a phone: the link opens the Git tab, which frames the git server"


@check("browser", "git-deep-link")
def deep_link(ctx):
    need_on()
    m = make(ctx)
    page, rec = ctx.page("git-deep")
    login(page)
    page.goto(origin() + f"/#git/{OWNER}/{REPO}/issues/1")
    page.reload()
    page.wait_for_selector('iframe[data-app="git"]', state="attached", timeout=30000)
    f = frame_of(page, "git")
    f.wait_for_url(re.compile(re.escape(f"/{OWNER}/{REPO}/issues/1") + r"$"), timeout=30000)
    expect(ISSUE in f.locator("body").inner_text(), "the issue's title is not in the frame")
    expect(page.evaluate("location.hash") == "#git", f"the address keeps only the tab: {page.evaluate('location.hash')}")
    # a place that is none of the known shapes loads nothing of the git server
    for bad in ("admin/settings", "../x", f"{OWNER}/{REPO}/settings"):
        page.evaluate("p => { location.hash = '#git/' + p; }", bad)
        page.wait_for_timeout(500)
        expect(not re.search(r"/(admin|settings)", frame_of(page, "git").url.replace(origin("git"), "")), f"{bad} was loaded: {frame_of(page, 'git').url}")
    shot(page, "git-3-deep-link")
    rec.save()
    return f"#git/{OWNER}/{REPO}/issues/1 loads that issue in the frame; odd places load nothing; made: {sorted(m)}"


@check("browser", "git-search-repo-issue-and-pull-request")
def search(ctx):
    need_on()
    make(ctx)
    page, rec = ctx.page("git-search")
    login(page)
    # the repository: by its name and by its description
    for text, want in ((REPO, REPO), (f"zebra crossing {STAMP}", ISSUE)):
        t0, got = time.time(), []
        while time.time() - t0 < 60:   # (Forgejo's issue index fills a moment after the issue is made)
            got = ask(page, text)
            if any(want in o for o in got):
                break
            page.keyboard.press("Escape")
            page.wait_for_timeout(1500)
        expect(any(want in o for o in got), f"search {text!r}: the Git group has {got}")
    # one group, labelled Git; the three kinds in it
    got = ask(page, f"zebra crossing {STAMP}")
    joined = " | ".join(got)
    expect(ISSUE in joined and PR in joined and "Pull request #" in joined and "Issue #1" in joined, f"issue and pull request: {got}")
    shot(page, "git-4-search")
    # a click opens each: the repository (titled owner/name), the issue, the pull request
    for want_path, text in ((f"/{OWNER}/{REPO}", REPO), (f"/{OWNER}/{REPO}/issues/1", ISSUE), (f"/{OWNER}/{REPO}/pulls/{made['pr']}", PR)):
        page.keyboard.press("Escape")
        opts = ask(page, text if text == REPO else f"zebra crossing {STAMP}")
        idx = next((i for i, o in enumerate(opts) if (text == REPO and o.startswith(f"{OWNER}/{REPO}")) or (text != REPO and text in o)), None)
        expect(idx is not None, f"no option for {text!r}: {opts}")
        page.locator("#search-list [role=group][aria-labelledby=sg-git] .search-opt").nth(idx).click()
        f = frame_of(page, "git")
        f.wait_for_url(re.compile(re.escape(want_path) + r"$"), timeout=30000)
        expect(page.locator(".tab[data-tab=git]").get_attribute("aria-current") == "page", "the Git tab is not the one shown")
    # one character is not searched; nothing typed leaves no Git group
    open_search(page)
    page.fill("#search-input", "z")
    page.wait_for_timeout(800)
    expect(page.locator("#sg-git").count() == 0, "a one-character search asked the git server")
    # the notes say code is not searched (the indexer is off unless LOCALGIT_INDEXER=true)
    if ENV.get("LOCALGIT_INDEXER") != "true":
        page.fill("#search-input", f"zebra {STAMP}")
        page.wait_for_selector("#search-notes:not([hidden])")
        expect("not code" in page.locator("#search-notes").inner_text(), "no note that code is not searched")
    rec.save()
    return "Git group: the repository (name, description), the issue and the pull request (titles); each opens its #git place in the frame"


@check("browser", "git-search-token-stays-in-the-portal")
def token_stays(ctx):
    need_on()
    try:
        return _token_stays(ctx)
    finally:
        tidy(ctx)   # (the last of this file's checks: the throwaway's git server is left as it was)


def _token_stays(ctx):
    tok = ENV.get("LOCALGIT_READ_TOKEN", "")
    expect(len(tok) >= 20, "the throwaway has no search token (./stack up makes LOCALGIT_READ_TOKEN)")
    sess = ctx.session()
    r = http("GET", None, f"/api/search/git?q={quote(REPO)}", {"X-Requested-With": "devos-ade"}, cookie=sess)
    expect(r.status == 200 and tok not in r.text() and "authorization" not in {k.lower() for k in dict(r.headers).keys()}, f"the answer: HTTP {r.status}")
    expect(http("GET", None, f"/api/search/git?q={quote(REPO)}", {"X-Requested-With": "devos-ade"}).status == 401, "the search answered without a session")
    for path in ("/", "/static/search.js", "/static/git.js", "/static/app.js", "/api/summary", "/api/settings"):
        body = http("GET", None, path, {"X-Requested-With": "devos-ade"}, cookie=sess).text()
        expect(tok not in body, f"the token is in {path}")
    page, rec = ctx.page("git-token")
    login(page)
    page.keyboard.press("Control+K")
    page.fill("#search-input", REPO)
    page.wait_for_timeout(2500)
    expect(tok not in page.content(), "the token is in the page")
    expect(not any(tok in json.dumps(e) for e in rec.events), "the token is in a request or answer the browser saw")
    # the sandbox gets none: the terminal's and the Code page's containers do not hold it (their environments are compose's)
    rec.save()
    return "the search answer, the page, the scripts, Summary and Settings, and the browser's own traffic hold no token"
