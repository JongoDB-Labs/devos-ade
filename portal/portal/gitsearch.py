"""The built-in git server for the portal's global search (GET /api/search/git?q=…): repositories (name, description) and
issues and pull requests (titles), from Forgejo's own search API (GET /api/v1/repos/search, GET /api/v1/repos/issues/search),
asked from here, inside the stack.

How it reaches Forgejo: the portal is not on the git server's network (it is internal, shared with Caddy and the terminal's
gateway alone), so the asks go through Caddy's internal :8099 site (caddy/localgit-on.caddy: those two GET paths among the
few it passes), as the code container's mirroring does. How it signs in: a token of the git server's owner with the
narrowest scopes that work, read:repository and read:issue (lib/localgit.sh makes it; .env's LOCALGIT_READ_TOKEN, passed to
this container alone). It is sent only in the Authorization header of those two requests — never logged, never in an
answer, a page or an error message, never to a browser or the sandbox. The git server answers what the token's account may
see: the owner's own repositories.

Nothing about a repository is kept here: each search is passed on and its answer reduced to what the search box shows —
owner/name (checked against the shape a repository's name can have), a description or a title as plain text (capped,
control characters dropped; they are other people's and Claude's words), the number and whether it is a pull request —
at most MAX_REPOS repositories and MAX_ISSUES issues and pull requests.

The query: at most chatsearch.MAX_QUERY characters, control characters dropped; a few requests a second at most (the page
waits for typing to pause). Code is not searched: Forgejo has no API for it, and its repository indexer is off unless
LOCALGIT_CODE_INDEXER=true (then the page offers the git server's own code search, which shows its results itself)."""

from __future__ import annotations

import asyncio
import re

import httpx

from .chatsearch import MAX_ANSWER, RateLimit, SearchError, clean   # (the chat search's limits and text rules)
from .config import Settings

TIMEOUT = httpx.Timeout(5.0, connect=2.0)
MAX_REPOS = 8
MAX_ISSUES = 8
MAX_TITLE = 200
MAX_DESCRIPTION = 200
FULL_NAME = re.compile(r"([A-Za-z0-9._-]{1,100})/([A-Za-z0-9._-]{1,100})")


def _name_ok(part: str) -> bool:
    return part not in (".", "..") and not part.endswith(".git")


def repo_params(q: str) -> dict:
    return {"q": q, "limit": MAX_REPOS, "sort": "updated", "order": "desc"}


def issue_params(q: str) -> dict:
    return {"q": q, "limit": MAX_ISSUES, "state": "all"}


def split_full_name(v) -> tuple[str, str] | None:
    """(owner, name) of an "owner/name" Forgejo gave, or None when it is not the shape a repository's name can have."""
    m = FULL_NAME.fullmatch(v) if isinstance(v, str) else None
    if not m or not _name_ok(m.group(1)) or not _name_ok(m.group(2)):
        return None
    return m.group(1), m.group(2)


def repo_row(x) -> dict | None:
    if not isinstance(x, dict):
        return None
    pair = split_full_name(x.get("full_name"))
    if pair is None:
        return None
    return {"repo": f"{pair[0]}/{pair[1]}", "description": clean(x.get("description"), MAX_DESCRIPTION),
            "private": x.get("private") is True, "archived": x.get("archived") is True}


def issue_row(x) -> dict | None:
    if not isinstance(x, dict):
        return None
    repo = x.get("repository")
    pair = split_full_name(repo.get("full_name") if isinstance(repo, dict) else None)
    n = x.get("number")
    if pair is None or not isinstance(n, int) or isinstance(n, bool) or not 0 < n < 10**9:
        return None
    return {"repo": f"{pair[0]}/{pair[1]}", "number": n, "title": clean(x.get("title"), MAX_TITLE) or f"#{n}",
            "pr": bool(x.get("pull_request")), "state": "closed" if x.get("state") == "closed" else "open"}


class GitSearch:
    def __init__(self, settings: Settings, clock=None):
        self.s = settings
        self.rate = RateLimit(clock) if clock else RateLimit()

    def ready(self) -> bool:
        """The git server is on and the portal has its search token."""
        return self.s.git and bool(self.s.git_token)

    async def _get(self, client: httpx.AsyncClient, path: str, params: dict):
        try:
            r = await client.get(f"{self.s.git_api_url}{path}", params=params,
                                 headers={"Authorization": f"token {self.s.git_token}", "Accept": "application/json"},
                                 timeout=TIMEOUT)
        except httpx.HTTPError as e:
            raise SearchError(f"The git server did not answer ({type(e).__name__})") from None
        if r.status_code in (401, 403):
            raise SearchError(f"The git server refused the portal's search token (HTTP {r.status_code}): ./stack up makes a new one")
        if r.status_code != 200:
            raise SearchError(f"The git server answered HTTP {r.status_code}")
        if len(r.content) > MAX_ANSWER:
            raise SearchError("The git server's answer was too large")
        try:
            return r.json()
        except ValueError:
            raise SearchError("The git server's answer was not JSON") from None

    async def search(self, client: httpx.AsyncClient, q: str) -> dict:
        """{"repos": [{repo, description, private, archived}], "issues": [{repo, number, title, pr, state}]} for Q. Both asks
        are made at once; if either fails the whole search does (a SearchError the page turns into "Search in Git")."""
        if not self.s.git:
            raise SearchError("The local git server is off", 409)
        if not self.s.git_token:
            raise SearchError("The portal has no search token for the git server yet: ./stack up makes it", 503)
        repos, issues = await asyncio.gather(self._get(client, "/api/v1/repos/search", repo_params(q)),
                                             self._get(client, "/api/v1/repos/issues/search", issue_params(q)))
        rows = repos.get("data") if isinstance(repos, dict) else None
        if not isinstance(rows, list) or not isinstance(issues, list):
            raise SearchError("The git server's answer was not what a search gives")
        out_repos = [r for r in (repo_row(x) for x in rows) if r is not None][:MAX_REPOS]
        out_issues = [r for r in (issue_row(x) for x in issues) if r is not None][:MAX_ISSUES]
        return {"repos": out_repos, "issues": out_issues}
