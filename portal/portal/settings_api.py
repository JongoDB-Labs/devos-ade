"""/api/settings/*: the Settings page (portal/portal/settings.py has the data and the request files).

Every change goes through the same front door as Update/Rollback/Clean: a session, X-Requested-With, the portal's
own Origin, the portal password typed again (counted by the login throttle), and REMOTE_ADMIN_ACTIONS for remote
sessions. Keys that could send data elsewhere (the AWS key, OpenRouter, speech-to-text, the alert webhook) are taken
only from local sessions. The helper checks all of it again (lib/settings_helper.sh)."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from . import admin, answers, brand, code, explabs, keycheck
from . import local_models as lm
from . import model_browser as mb
from . import settings as st
from .security import NEXT_MAX_AGE, Sessions, cookie_params, hash_password, same_origin, verify_password

# the password-free Check server: this computer only (localhost, 127.x.x.x, ::1), the address's host and nothing else
_LOOPBACK_URL = re.compile(r"https?://(?:localhost|127\.\d{1,3}\.\d{1,3}\.\d{1,3}|\[::1\]|\[::ffff:127\.\d{1,3}\.\d{1,3}\.\d{1,3}\])(?::\d{1,5})?(?:/|$)", re.I)
log = logging.getLogger("portal.settings")


class RateLimit:
    def __init__(self, min_interval: float, per_hour: int, clock=time.monotonic):
        self.min_interval, self.per_hour, self._clock, self._times = min_interval, per_hour, clock, deque()

    def retry_after(self) -> int:
        now = self._clock()
        while self._times and now - self._times[0] > 3600:
            self._times.popleft()
        if self._times and now - self._times[-1] < self.min_interval:
            return int(self.min_interval - (now - self._times[-1])) + 1
        if len(self._times) >= self.per_hour:
            return int(3600 - (now - self._times[0])) + 1
        return 0

    def hit(self) -> None:
        self._times.append(self._clock())


@dataclass
class Ctx:
    """What the routes need from app.py's create_app."""
    settings: object
    sessions: Sessions
    throttle: object
    remote: Callable[[Request], bool]           # the remote site (Caddy's marker, with the proxy secret)
    api_guard: Callable[[Request], Response | None]
    session_login: Callable[[Request], str | None]
    set_session: Callable                     # set_session(resp, remote, login, iat)
    on_signout: Callable[[], None] = lambda: None   # after revoke_all: end the Admin sessions too (appsso.Sweeper)


def _no_store(r: Response) -> Response:
    r.headers["Cache-Control"] = "no-store"
    return r


def err(status: int, msg: str, retry: int = 0, **extra) -> Response:
    r = JSONResponse({"error": msg, **extra}, status_code=status)
    if retry:
        r.headers["Retry-After"] = str(retry)
    return _no_store(r)


# The in-form key check (check_key below): the keys whose form checks them before the password, and its body's cap
KEY_VALIDATORS = ("or_key", "xl_key", "stt_key", "ws_key")
CHECK_BODY = 2048


def routes(ctx: Ctx) -> list[Route]:
    s = ctx.settings
    apply_rate = RateLimit(5, 30)
    action_rate = RateLimit(5, 30)
    check_rate = RateLimit(1, 60)

    def is_remote(request: Request) -> bool:
        # remote if either says so: Caddy's verified marker, or the bare header (admin.is_remote) — the safe side
        return ctx.remote(request) or admin.is_remote(request)

    def allowed(request: Request) -> bool:
        return not is_remote(request) or admin.remote_allowed(s)

    async def front_door(request: Request) -> tuple[dict, str] | Response:
        """Session, X-Requested-With, same Origin, remote rule, a bounded JSON body and the password again."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        length = request.headers.get("content-length", "")
        if not length.isdigit() or not length.isascii():
            return err(411, "Content-Length required")
        if int(length) > st.MAX_BODY:
            return err(413, "request too large")
        body = await request.body()
        if len(body) > st.MAX_BODY:
            return err(413, "request too large")
        try:
            data = json.loads(body)
        except ValueError:
            return err(400, "not JSON")
        if not isinstance(data, dict):
            return err(400, "not a JSON object")
        password = data.get("password")
        if wait := ctx.throttle.retry_after():
            return err(429, f"Too many wrong passwords. Try again in {wait} s.", wait)
        if not isinstance(password, str) or not await asyncio.to_thread(verify_password, password, s.password_hash):
            ctx.throttle.failure()
            log.warning("settings: wrong password (%d in a row)", ctx.throttle.failures)
            return err(403, "That password is not right (PORTAL_PASSWORD in .env).")
        ctx.throttle.success()
        if len(password.encode("utf-8", "surrogatepass")) > st.MAX_AUTH:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes, more than a request to the update helper "
                            "can carry: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        return data, password

    def helper_ready() -> Response | None:
        state = admin.helper_state(s.status_dir)
        if not state["running"]:
            return err(503, f"{admin.not_running(state)}. Nothing can be applied from here until it runs: ./stack helper "
                            "install starts it, or use ./stack config set KEY in a terminal.")
        if not st.capability(s.status_dir)["settings"]:
            return err(503, "This update helper predates Settings: ./stack helper install refreshes it.")
        if admin.job_in_progress(state):
            return err(409, "Another action is still running.")
        return None

    async def get_settings(request: Request) -> Response:
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        rem = is_remote(request)
        st.sweep_requests(s.request_dir)
        state = admin.helper_state(s.status_dir)
        cap = st.capability(s.status_dir)
        snap = st.snapshot(s.status_dir)
        return _no_store(JSONResponse({
            "available": snap is not None, "snapshot": snap, "layout": st.layout(s.catalog_dir),
            "helper": {"running": state["running"], "heartbeat_at": state["heartbeat_at"], "settings": cap["settings"],
                       "diagnostics": cap["diagnostics"], "projects": cap["projects"], "sessions": cap["sessions"],
                       "subscriptions": cap["subscriptions"], "screen": cap["screen"],
                       "in_progress": admin.job_in_progress(state), "job": state["job"]},
            # the folders of this computer the Code page's sandbox sees (./stack project; lib/projects.sh)
            "projects": st.project_folders(s.status_dir),
            # what DevOS ADE may read of your Claude Code and devos-claude sessions here (lib/sessions.sh)
            "sessions": st.sessions_consent(s.status_dir),
            # your AI subscriptions' tools in the sandbox and what each says of its own login (answers.py; never a login)
            "subscriptions": answers.tools(s.catalog_dir, s.status_dir),
            "here": {"remote": rem, "allowed": allowed(request)},
            "apps": s.app_urls(ctx.remote(request)), "user": s.user_email, "backups": st.backups(s.status_dir), "versions": st.versions(s.status_dir),
            "remote": {"on": s.remote_on(), "mode": s.remote_mode if s.remote_on() else "off",
                       "url": s.origin(remote=True) if s.remote_on() else ""},
            # Experiential Labs' chosen models its key's list does not name (left out; the card says so, with the
            # alias the list has instead: lib/explabs.sh xl_missing)
            "explabs": {"missing": [{**m, "text": explabs.missing_text(m)} for m in (explabs.read(s.litellm_dir) or {}).get("missing") or []]},
        }))

    def check_values(values: dict, snap: dict, local: bool, same_password: bool = False) -> dict:
        """{KEY: what is wrong} (no value in any message); the same rules as lib/settings.sh settings_check_batch."""
        rows, fields = st.by_key(snap), {}
        ctx = {k: r.get("value") or "" for k, r in rows.items()}   # (the other settings, for REMOTE_PREVIEW's rule)
        for k, v in values.items():
            row = rows.get(k)
            if row is None or row["policy"] not in st.EDITABLE:
                fields[k] = st.policy_error(row, v, local, ctx) if row else f"is not a {brand.NAME} setting"
                continue
            e = st.policy_error(row, v, local, ctx) or st.validate(row["validator"], v, snap["remote_on"])
            if e:
                fields[k] = e
        if fields:
            return fields
        eff = lambda k: values[k] if k in values else (rows.get(k) or {}).get("value", "")  # noqa: E731
        if ("AWS_ACCESS_KEY_ID" in values) != ("AWS_SECRET_ACCESS_KEY" in values):
            fields["AWS_SECRET_ACCESS_KEY"] = "goes together with the access key ID: replace both"
        if same_password:   # (verified off the event loop by the caller: 600,000 rounds)
            fields["PORTAL_PASSWORD"] = "is the password you have now"
        if "LITELLM_UI_PASSWORD" in values and values["LITELLM_UI_PASSWORD"] == s.litellm_ui_password:
            fields["LITELLM_UI_PASSWORD"] = "is the password you have now"
        if "OPENWEBUI_ADMIN_EMAIL" in values and \
                values["OPENWEBUI_ADMIN_EMAIL"].lower() == ((rows.get("OPENWEBUI_ADMIN_EMAIL") or {}).get("value") or "").lower():
            fields["OPENWEBUI_ADMIN_EMAIL"] = "is the owner email you have now"
        # (the Code page with the terminal off turns the terminal on too: ./stack checks its folder, settings_check_batch)
        if "TAILSCALE_ALLOWED_LOGIN" in values and values["TAILSCALE_ALLOWED_LOGIN"] == "":
            fields["TAILSCALE_ALLOWED_LOGIN"] = "cannot be made blank here"
        chat = {m[0] for m in snap["choices"]["chat_models"]}
        for k in ("CHAT_DEFAULT_MODEL", "CHAT_TASK_MODEL", "CLAUDE_MODEL_OPUS", "CLAUDE_MODEL_SONNET", "CLAUDE_MODEL_HAIKU"):
            if values.get(k) and values[k] not in chat:
                fields[k] = "is not a chat model your AWS key can use"
            elif k.startswith("CLAUDE_MODEL_") and values.get(k) and not values[k].startswith("claude-"):
                fields[k] = "must be a Claude model (Claude Code speaks Anthropic's API)"
        if values.get("MODELS_HIDDEN") and not set(values["MODELS_HIDDEN"].split(",")) <= chat:
            fields["MODELS_HIDDEN"] = "lists a model your AWS key cannot use"
        # Settings › Claude Code › Models: models the stack serves (litellm/code-models.tsv; not checked before it exists)
        code = {m[0] for m in snap["choices"].get("code_models") or []}
        if code and values.get("CODE_DEFAULT_MODEL") and values["CODE_DEFAULT_MODEL"] not in code:
            fields["CODE_DEFAULT_MODEL"] = "is not a chat model this stack serves"
        if code and values.get("CODE_MODELS") not in (None, "", "all", "anthropic") and not set(values["CODE_MODELS"].split(",")) <= code:
            fields["CODE_MODELS"] = "lists a model this stack does not serve"
        if {"STT_PROVIDER", "STT_API_KEY", "STT_MODEL"} & set(values):
            p, model = eff("STT_PROVIDER"), eff("STT_MODEL")
            models = snap["choices"]["stt_models"].get(p, [])
            if p in ("openai", "groq"):
                key_set = values.get("STT_API_KEY", "") != "" or ("STT_API_KEY" not in values and (rows.get("STT_API_KEY") or {}).get("set"))
                if not key_set:
                    fields["STT_API_KEY"] = f"{p} needs an API key"
            if p and model and model not in models:
                fields["STT_MODEL"] = f"is not a {p} speech-to-text model ({', '.join(models)})"
            if p == "bedrock" and (model or "voxtral-small") in snap["choices"].get("stt_bedrock_refused", []):
                fields["STT_PROVIDER"] = st.STT_REFUSED
            elif p == "bedrock" and (model or "voxtral-small") not in snap["choices"]["stt_bedrock_ready"]:
                fields["STT_PROVIDER"] = "Voxtral is not usable with your AWS key (the last model check)"
        return fields

    async def apply(request: Request) -> Response:
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        snap = st.snapshot(s.status_dir)
        if snap is None:
            return err(409, "Settings are not available yet: run ./stack up once.")
        if data.get("base") != snap["base"]:
            return err(409, "Settings changed on disk since you opened the page — reload it.")
        values = data.get("set") if data.get("set") is not None else {}
        regen = data.get("regen") or []
        if not isinstance(regen, list) or any(k not in st.REGEN for k in regen) or len(set(regen)) != len(regen):
            return err(400, "only RUSTFS_ACCESS_KEY and SHARED_MCP_TOKEN can be regenerated")
        if not isinstance(values, dict) or not (values or regen) or len(values) + len(regen) > st.MAX_KEYS - 1:
            return err(400, f"between 1 and {st.MAX_KEYS - 1} settings at a time")
        if any(not isinstance(k, str) or not st.NAME.fullmatch(k) or not isinstance(v, str) for k, v in values.items()):
            return err(400, "settings are names and text values")
        local = not is_remote(request)
        confirm = data.get("confirm") or []
        if not isinstance(confirm, list) or any(c not in st.CONFIRMS for c in confirm):
            return err(400, "unknown confirmation")
        same = "PORTAL_PASSWORD" in values and await asyncio.to_thread(verify_password, values["PORTAL_PASSWORD"], s.password_hash)
        fields = check_values(values, snap, local, same)
        if fields:
            return err(400, "Some settings need another value.", fields=fields)
        if (busy := helper_ready()) is not None:
            return busy
        if wait := apply_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next change.", wait)
        values = dict(values)
        new_hash = None
        if "PORTAL_PASSWORD" in values:
            new_hash = await asyncio.to_thread(hash_password, values["PORTAL_PASSWORD"])
            values["PORTAL_PASSWORD_HASH"] = new_hash
        try:
            nonce = st.write_request(s.request_dir, snap["base"], local, password, values, regen=tuple(regen),
                                     confirm=tuple(confirm))
        except ValueError:
            return err(413, "These settings do not fit in one change: save them in smaller groups.")
        except OSError as e:
            log.warning("cannot write a settings request to %s (%s)", s.request_dir, e)
            return err(500, "Could not hand the change to the helper (see ./stack logs portal).")
        apply_rate.hit()
        keys = [k for k in values if k != "PORTAL_PASSWORD_HASH"] + list(regen)
        log.warning("settings change requested: %s%s", ", ".join(keys), "" if local else " (remote)")
        resp = _no_store(JSONResponse({"id": nonce, "keys": keys}, status_code=202))
        if new_hash:
            # Carry-over: this browser stays signed in after the portal restarts with the new password; the
            # running portal (old hash) refuses this cookie, every other session ends with the restart.
            rem = ctx.remote(request)
            c = cookie_params(s, rem, carry=True)
            token = Sessions(s.secret, new_hash).issue(login=ctx.session_login(request))
            resp.set_cookie(c["key"], token, max_age=NEXT_MAX_AGE, path="/", domain=c["domain"], httponly=True,
                            samesite="strict", secure=c["secure"])
        return resp

    async def check_key(request: Request) -> Response:
        """A provider key typed in a form, checked before the password (portal/keycheck.py): its shape by the same rule
        as a change, then — for a provider with a free check — one call to that provider. No password (nothing changes),
        but a session, X-Requested-With, the portal's own Origin, the remote rule and the key's own policy (a key that
        could send data elsewhere: this computer only), at most one a second and 60 an hour. The key is never stored or
        logged; the helper checks it again before anything is saved."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        length = request.headers.get("content-length", "")
        if not length.isdigit() or not length.isascii():
            return err(411, "Content-Length required")
        if int(length) > CHECK_BODY:
            return err(413, "request too large")
        body = await request.body()
        try:
            data = json.loads(body) if len(body) <= CHECK_BODY else None
        except ValueError:
            data = None
        if not isinstance(data, dict):
            return err(400, "not a JSON object")
        key, value, prov = data.get("key"), data.get("value"), data.get("provider")
        if not isinstance(key, str) or not isinstance(value, str) or (prov is not None and not isinstance(prov, str)):
            return err(400, "key and value are text")
        snap = st.snapshot(s.status_dir)
        row = st.by_key(snap).get(key)
        if snap is None or row is None or row["validator"] not in KEY_VALIDATORS:
            return err(400, "not a key this form checks")
        value = value.strip()
        if (e := st.policy_error(row, value, not is_remote(request))):
            return err(403, f"{row['label']} {e}.")
        if not value:
            return err(400, "Enter the new key.", fields={key: "is empty"})
        if (e := st.validate(row["validator"], value, snap["remote_on"])):
            return err(400, f"{row['label']} {e}.", fields={key: e})
        p = keycheck.provider(key, prov)
        if p is None:   # (a web search key, or speech-to-text without a provider that takes one: nothing to ask)
            return _no_store(JSONResponse({"result": "unchecked", "message": "", "url": "", "models": None}))
        if wait := check_rate.retry_after():
            return err(429, f"Please wait {wait} s before checking another key.", wait)
        check_rate.hit()
        got = await keycheck.check(request.app.state.http, p, value)
        log.warning("settings: %s checked with %s from the form: %s%s", key, p.host, got["result"],
                    " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse(got))

    def reveal_value(key: str) -> str:
        env = {"claude-code": "LITELLM_KEY_CLAUDE_CODE", "open-webui": "LITELLM_KEY_OPENWEBUI", "setup": "LITELLM_KEY_SETUP"}
        keys = {env[a]: v for a, _, v in s.keys if a in env}
        return {"LITELLM_UI_PASSWORD": s.litellm_ui_password, "RUSTFS_ACCESS_KEY": s.rustfs_access_key,
                "RUSTFS_SECRET_KEY": s.rustfs_secret_key, "SHARED_MCP_TOKEN": s.shared_mcp_token, **keys}.get(key, "")

    async def reveal(request: Request) -> Response:
        """One of the values the portal holds anyway (st.REVEAL), after the password again."""
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        key = got[0].get("key")
        if key not in st.REVEAL:
            return err(403, "That setting is never shown here.")
        value = reveal_value(key)
        if not value:
            return err(404, "Not set.")
        log.warning("settings: %s revealed%s", key, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"key": key, "value": value}))

    async def action(request: Request) -> Response:
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        act = data.get("action")
        if act not in st.DIAG_ACTIONS:
            return err(400, "unknown action")
        if (busy := helper_ready()) is not None:
            return busy
        if act not in st.capability(s.status_dir)["diagnostics"]:
            return err(409, "This update helper does not offer that yet: ./stack helper install refreshes it.")
        if wait := action_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next action.", wait)
        try:
            nonce = st.write_action(s.request_dir, act, password)
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the %s request to %s (%s)", act, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        action_rate.hit()
        log.warning("diagnostic requested: %s%s", act, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "action": act}, status_code=202))

    async def project_action(request: Request) -> Response:
        """A project folder action for the helper: the folder chooser on this computer's screen (local sessions only:
        a request never names a path), or a folder removed / made read-only by its id (narrowing: from anywhere)."""
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        act, when = data.get("action"), data.get("when", "now")
        if act not in st.PROJECT_ACTIONS or when not in ("now", "idle"):
            return err(400, "unknown action")
        if act == "project-pick" and is_remote(request):
            return err(403, f"A folder is added only from the computer running {brand.NAME}: its folder chooser opens on that screen.")
        project = data.get("project")
        if act != "project-pick":
            if not isinstance(project, str) or not st.PROJECT_ID.fullmatch(project):
                return err(400, "bad project id")
            if not any(f["id"] == project for f in st.project_folders(s.status_dir)["folders"]):
                return err(404, "No such project folder (removed already?).")
        mode, hide = data.get("mode", "rw"), data.get("hide", False)
        if act == "project-pick" and (mode not in ("rw", "ro") or not isinstance(hide, bool)):
            return err(400, "bad request")
        if (busy := helper_ready()) is not None:
            return busy
        cap = st.capability(s.status_dir)
        if act not in cap["projects"]:
            return err(409, "This update helper does not offer project folders yet: ./stack helper install refreshes it.")
        if act == "project-pick" and not cap["screen"]:
            return err(409, "The update helper cannot show a dialog on this computer's screen: in a terminal there, ./stack project add DIR.")
        if wait := action_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next action.", wait)
        try:
            nonce = st.write_project_action(s.request_dir, act, password, when, project=project if act != "project-pick" else None,
                                            mode=mode, hide=hide)
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the %s request to %s (%s)", act, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        action_rate.hit()
        log.warning("project folder action requested: %s%s", act, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "action": act}, status_code=202))

    async def sessions_action(request: Request) -> Response:
        """What DevOS ADE may read of your sessions on this computer, taken back (narrowing: from anywhere; given only
        on the computer itself): by a project's id, or all, and a tool — never a path."""
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        act, project, tool = data.get("action"), data.get("project"), data.get("tool")
        if act not in st.SESSIONS_ACTIONS:
            return err(400, "unknown action")
        if not (project == "all" or (isinstance(project, str) and st.PROJECT_ID.fullmatch(project))) or tool not in st.REVOKE_TOOLS \
                or (isinstance(tool, str) and tool.startswith("setup-") and project != "all"):
            return err(400, "bad request")
        if (busy := helper_ready()) is not None:
            return busy
        if act not in st.capability(s.status_dir)["sessions"]:
            return err(409, "This update helper does not take that back yet: ./stack helper install refreshes it, or ./stack sessions consent --revoke in a terminal.")
        if wait := action_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next action.", wait)
        try:
            nonce = st.write_sessions_action(s.request_dir, password, project, tool)
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the %s request to %s (%s)", act, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        action_rate.hit()
        log.warning("sessions consent taken back: %s %s%s", project, tool, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "action": act}, status_code=202))

    async def subscriptions_action(request: Request) -> Response:
        """Your AI subscriptions, through the helper: ask the sandbox again, or one tool's own sign-out (narrowing:
        wherever Settings actions are allowed) — by the tool's id, never a path."""
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        act, tool = data.get("action"), data.get("tool")
        if act not in st.SUBS_ACTIONS:
            return err(400, "unknown action")
        if act in st.SUBS_SIGNOUT and tool not in st.SUBS_SIGNOUT[act]:
            return err(400, "That tool signs out inside its own screen (Gemini CLI: /auth signout, Copilot: /logout).")
        if (busy := helper_ready()) is not None:
            return busy
        if act not in st.capability(s.status_dir)["subscriptions"]:
            return err(409, "This update helper does not offer that yet: ./stack helper install refreshes it, or ./stack subscriptions in a terminal.")
        if wait := action_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next action.", wait)
        try:
            nonce = st.write_subs_action(s.request_dir, password, act, tool if act in st.SUBS_SIGNOUT else None)
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the %s request to %s (%s)", act, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        action_rate.hit()
        log.warning("subscriptions: %s%s%s", act, f" {tool}" if act in st.SUBS_SIGNOUT else "", " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "action": act}, status_code=202))

    async def signout_others(request: Request) -> Response:
        """Every other browser and device signs in again; this one stays (its new session starts just after)."""
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        ctx.sessions.revoke_all()
        ctx.on_signout()
        resp = _no_store(JSONResponse({"ok": True}))
        rem = ctx.remote(request)
        ctx.set_session(resp, rem, ctx.session_login(request), ctx.sessions.not_before + 0.001)
        c = cookie_params(s, rem, carry=True)
        resp.delete_cookie(c["key"], path="/", domain=c["domain"], httponly=True, samesite="strict", secure=c["secure"])
        log.warning("settings: signed out every other device%s", " (remote)" if is_remote(request) else "")
        return resp

    async def get_report(request: Request) -> Response:
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not allowed(request):
            return err(403, "Diagnostics are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        return _no_store(JSONResponse(st.report(s.status_dir)))

    # --- the model browser (portal/portal/model_browser.py; Browse models) ---
    browse_rate = RateLimit(1, 120)
    try_rate = RateLimit(3, 40)

    def _keys_on(rows: dict) -> dict:
        aws = rows.get("AWS_ACCESS_KEY_ID") or {}
        return {"bedrock": bool(aws.get("set")) or bool((rows.get("AWS_AUTH") or {}).get("value")),
                "openrouter": bool(s.openrouter_api_key), "explabs": bool((rows.get("EXPLABS_API_KEY") or {}).get("set"))}

    def _setup_key() -> str:
        return next((k for a, _, k in s.keys if a == "setup" and k), "")

    async def models_browse(request: Request) -> Response:
        # a read, like GET /api/settings: the session and X-Requested-With (api_guard) are the gate; no Origin on a GET
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        st.sweep_requests(s.request_dir)
        snap = st.snapshot(s.status_dir)
        if snap is None:
            return _no_store(JSONResponse({"error": "Settings are not available yet: run ./stack up once."}, status_code=409))
        rows = st.by_key(snap)
        values = {k: (r.get("value") or "") for k, r in rows.items()}
        keys_on = _keys_on(rows)
        refresh = request.query_params.get("refresh") == "1"
        or_public = request.query_params.get("openrouter") == "public"
        or_rows, or_meta = ([], {"at": None, "error": None})
        if keys_on["openrouter"] or or_public:
            if (wait := browse_rate.retry_after()) and refresh:
                return err(429, f"Please wait {wait} s before reading the lists again.", wait)
            or_rows, or_meta = await mb.openrouter_list(request.app.state.http, refresh=refresh)
            if refresh:
                browse_rate.hit()
        code_rows, _scope = code.read_code_models(s.litellm_dir)
        data = mb.browse(s.status_dir, s.catalog_dir, s.litellm_dir, values, keys_on, or_rows, or_meta, code_rows)
        # ask the update helper to read any stale list again (no password: a free, read-only listing); without the
        # helper nobody reads it, so the list says so instead of "reading" (reading: False)
        asked, helper_on = False, admin.helper_state(s.status_dir)["running"]
        for prov, p in data.items():
            if p["on"] and p["stale"] and prov != "openrouter":
                p["reading"] = helper_on
                asked = True
        if (asked or refresh) and helper_on:
            try:   # (Read again: every list read again, not only the stale ones — lib/model_browser.sh model_browser_tick)
                (s.request_dir / mb.WANTED).write_text("force" if refresh else "", encoding="utf-8")
            except OSError:
                pass
        state = admin.helper_state(s.status_dir)
        cap = st.capability(s.status_dir)
        can_change = state["running"] and cap["settings"] and allowed(request)
        why_not = "" if can_change else (
            "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env)." if not allowed(request)
            else f"{admin.not_running(state)}. ./stack helper install, or ./stack config set in a terminal.")
        return _no_store(JSONResponse({
            "providers": data, "base": snap["base"], "can_change": bool(can_change), "why_not": why_not,
            "try": bool(_setup_key()) and allowed(request) and state["running"],
        }))

    def _find(data: dict, provider: str, source_id: str) -> dict | None:
        return next((r for r in (data.get(provider) or {}).get("rows", []) if r["source_id"] == source_id), None)

    async def models_plan(request: Request) -> Response:
        """The setting change that adds or removes one model (no password; the change itself goes through apply)."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        try:
            body = json.loads(await request.body())
        except ValueError:
            return err(400, "not JSON")
        provider, ident, act = (body or {}).get("provider"), (body or {}).get("id"), (body or {}).get("action")
        if provider not in mb.SETTING or act not in ("add", "remove") or not isinstance(ident, str) or len(ident) > 200:
            return err(400, "bad request")
        snap = st.snapshot(s.status_dir)
        if snap is None:
            return err(409, "Settings are not available yet.")
        rows = st.by_key(snap)
        key = mb.SETTING[provider]
        row = rows.get(key)
        if row is None:
            return err(400, "not a setting this version serves")
        value = row.get("value") or ""
        free = last = None
        if provider in ("openrouter", "explabs"):
            or_rows, or_meta = (await mb.openrouter_list(request.app.state.http)) if provider == "openrouter" else ([], {})
            data = mb.browse(s.status_dir, s.catalog_dir, s.litellm_dir, {k: (r.get("value") or "") for k, r in rows.items()},
                             _keys_on(rows), or_rows, or_meta, code.read_code_models(s.litellm_dir)[0])
            r = _find(data, provider, ident)
            free = bool(r["free"]) if r else None
            if provider == "explabs":
                terms = [t for t in (value or mb.XL_DEFAULT).replace("xl/", "").split(",") if t.strip()]
                last = act == "remove" and len(terms) <= 1
        res = mb.plan(provider, value, ident, act == "add", free=free, last=last)
        if res is None:
            return _no_store(JSONResponse({"ok": False, "error": "Nothing to change — it is already as you asked."}))
        new_key, new_value = res
        e = st.policy_error(row, new_value, not is_remote(request)) or st.validate(row["validator"], new_value, snap["remote_on"])
        note = f"{mb.PROVIDER[provider]}'s models update and the model gateway restarts (about 30 s)."
        return _no_store(JSONResponse({"ok": e is None, "key": new_key, "value": new_value, "note": note, "error": e}))

    async def models_try(request: Request) -> Response:
        """Try it: the cost of one short call first (estimate), then — on confirm, with an expensive model acknowledged —
        the call itself on the setup key (its budget and Home's Setup row count it). Never starts on Opus by itself: an
        expensive model runs only when the page sent expensive_ok."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Try it is off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        try:
            body = json.loads(await request.body())
        except ValueError:
            return err(400, "not JSON")
        model = (body or {}).get("model")
        if not isinstance(model, str) or not st.MODEL_ID.fullmatch(model):
            return err(400, "bad model id")
        code_rows, _ = code.read_code_models(s.litellm_dir)
        row = next((r for r in code_rows if r["id"] == model), None)
        if row is None:
            return err(404, "That model is not one this stack serves.")
        est = mb.try_estimate({"in": row["prices"].get("in"), "out": row["prices"].get("out"), "id": model, "free": row["free"]})
        if not (body or {}).get("confirm"):
            return _no_store(JSONResponse({"ok": True, **est}))
        if est["expensive"] and not (body or {}).get("expensive_ok"):
            return err(403, "This model is expensive: confirm before spending on it.", expensive=True)
        key = _setup_key()
        if not key:
            return err(503, "No setup key yet (run ./stack setup).")
        if wait := try_rate.retry_after():
            return err(429, f"Please wait {wait} s before another Try.", wait)
        try_rate.hit()
        out = await mb.try_model(request.app.state.http, s.litellm_url, key, model)
        log.warning("settings: Try it ran on %s (%s)%s", model, out["status"], " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse(out))

    # --- Local models (portal/portal/local_models.py; Settings › Models & providers › Local models) ---
    local_search_rate = RateLimit(6, 60)

    def _local_can(request: Request) -> tuple[bool, str]:
        state = admin.helper_state(s.status_dir)
        cap = st.capability(s.status_dir)
        if not allowed(request):
            return False, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env)."
        if not state["running"]:
            return False, f"{admin.not_running(state)}. ./stack helper install, or ./stack local-models pull ORG/REPO QUANT in a terminal."
        if "local-pull" not in cap["local"]:
            return False, "This update helper does not do local models yet: ./stack helper install refreshes it."
        return True, ""

    async def local_models_get(request: Request) -> Response:
        """The Local models section: the runtime ./stack found (or how to turn one on), this computer's memory, what is
        downloaded and its disk, and the download's progress — read from .state/status/local-models.json, asked for again
        (no password: a free, read-only look) while it is more than half a minute old."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        data = lm.read_status(s.status_dir)
        job_live = data["job"]["state"] in lm.LIVE
        if (data["stale"] or request.query_params.get("refresh") == "1") and not job_live and admin.helper_state(s.status_dir)["running"]:
            try:
                (s.request_dir / lm.WANTED).write_text("", encoding="utf-8")
            except OSError:
                pass
        ok, why = _local_can(request)
        rows = st.by_key(st.snapshot(s.status_dir))
        cap = st.capability(s.status_dir)["local"]
        choice = (rows.get("LOCAL_RUNTIME") or {}).get("value") or ""
        return _no_store(JSONResponse({**data, "can_change": ok, "why_not": why, "can_stop": ok and "local-stop" in cap,
                                       "hf_token_set": bool((rows.get("HF_TOKEN") or {}).get("set")),
                                       "wait": data["stale"] and not data["known"],
                                       "runtimes": lm.read_runtimes(s.status_dir), "can_runtime": ok and "local-runtime" in cap,
                                       "choice": choice if choice in ("auto", "mlx", "dmr", "ollama") else "auto"}))

    async def local_models_search(request: Request) -> Response:
        """Hugging Face's GGUF repos for ?q= (public API from here, no key); with ?repo=org/name that repo's quants, each with
        its size, license and whether it fits this computer's memory."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        data = lm.read_status(s.status_dir)
        repo = request.query_params.get("repo")
        if repo:
            row, e = await lm.repo_files(request.app.state.http, repo, fmt=("mlx" if data["runtime"]["kind"] == "mlx" else "gguf"))
            if e or row is None:
                return _no_store(JSONResponse({"error": e or "not found"}, status_code=502 if e and "did not answer" in e else 404))
            return _no_store(JSONResponse({"repo": lm.annotate(row, data["memory"], data["gpu"], data["installed"])}))
        if wait := local_search_rate.retry_after():
            return err(429, f"Please wait {wait} s before searching again.", wait)
        local_search_rate.hit()
        rows, e = await lm.search(request.app.state.http, request.query_params.get("q", ""), fmt=("mlx" if data["runtime"]["kind"] == "mlx" else "gguf"))
        return _no_store(JSONResponse({"rows": rows, "error": e}))

    async def local_models_change(request: Request) -> Response:
        """A download or a removal: the password, a repo and a quant. The facts of a download (size, tool use, context,
        license) are worked out here from Hugging Face's answer, never taken from the page."""
        st.sweep_requests(s.request_dir)
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        act = data.get("action")
        repo, quant = data.get("repo"), data.get("quant")
        if act not in st.LOCAL_ACTIONS or not isinstance(repo, str) or not isinstance(quant, str) \
                or not lm.REPO.fullmatch(repo) or not lm.QUANT.fullmatch(quant):
            return err(400, "bad request")
        ok, why = _local_can(request)
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        if admin.job_in_progress(admin.helper_state(s.status_dir)) and act == "local-pull":
            return err(409, "Another action is still running.")
        status = lm.read_status(s.status_dir)
        if status["job"]["state"] in lm.LIVE:
            return err(409, "A download or a removal is still running.")
        j = status["job"]
        if act == "local-pull" and j["state"] == "paused" and (j["repo"].lower(), j["quant"].lower()) != (repo.lower(), quant.lower()):
            return err(409, f"{j['repo']} is paused: Resume or Cancel it first.")
        fields: dict = {}
        if act == "local-pull":
            if status["runtime"]["kind"] == "none":
                return err(409, f"No model runner is running on this computer. {status['runtime']['how']}")
            row, e = await lm.repo_files(request.app.state.http, repo, fmt=("mlx" if status["runtime"]["kind"] == "mlx" else "gguf"))
            if row is None:
                return err(502, e or "Hugging Face did not describe that repo.")
            if row.get("blocked"):
                return err(422, row["blocked"])
            q = lm.find_quant(row, quant)
            if q is None:
                return err(404, "That repo has no such quantization.")
            fields = lm.pull_fields(row, q)
            quant = q["quant"]
        elif not any(i["repo"].lower() == repo.lower() and i["quant"].lower() == quant.lower() for i in status["installed"]):
            return err(404, "That is not a model downloaded here.")
        if wait := action_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next action.", wait)
        try:
            nonce = st.write_local_action(s.request_dir, password, act, repo, quant,
                                          size=fields.get("bytes", 0), tools=fields.get("tools", "unknown"), context=fields.get("context", 0),
                                          params_m=fields.get("params_m", 0), license=fields.get("license", "unknown"))
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the %s request to %s (%s)", act, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        action_rate.hit()
        log.warning("local models: %s %s:%s%s", act, repo, quant, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "action": act}, status_code=202))


    stop_rate = RateLimit(1, 120)

    async def local_models_stop(request: Request) -> Response:
        """Pause or Cancel the running download (Cancel also deletes a paused or stopped one's part). No password: it only
        ever stops something and spends nothing; otherwise the same door as every other change (session, X-Requested-With,
        same Origin, the remote rule, a bounded JSON body). The helper stops it within seconds; the page reads the outcome
        from the status (paused or cancelled)."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        length = request.headers.get("content-length", "")
        if not length.isdigit() or not length.isascii() or int(length) > st.MAX_BODY:
            return err(411 if not length.isdigit() else 413, "Content-Length required" if not length.isdigit() else "request too large")
        try:
            data = json.loads(await request.body())
        except ValueError:
            return err(400, "not JSON")
        op = data.get("op") if isinstance(data, dict) else None
        if op not in ("pause", "cancel"):
            return err(400, "bad request")
        ok, why = _local_can(request)
        if ok and "local-stop" not in st.capability(s.status_dir)["local"]:
            ok, why = False, "This update helper cannot pause or cancel yet: ./stack helper install refreshes it."
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        j = lm.read_status(s.status_dir)["job"]
        if not (j["state"] == "pulling" or op == "cancel" and j["state"] in ("paused", "failed") and j["repo"]):
            return err(409, "No download is running." if op == "pause" else "There is no download to cancel.")
        if wait := stop_rate.retry_after():
            return err(429, f"Please wait {wait} s.", wait)
        try:
            nonce = st.write_local_stop_action(s.request_dir, op)
        except OSError as e:
            log.warning("cannot write the download %s request to %s (%s)", op, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        stop_rate.hit()
        log.warning("local models: %s %s:%s%s", op, j["repo"], j["quant"], " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "op": op}, status_code=202))

    runtime_rate = RateLimit(1, 5)
    runtime_free_rate = RateLimit(1, 2)
    runtime_log_rate = RateLimit(1, 1)   # (its own: reading the log never holds up a Stop or a Cancel)

    def _runtime_can(request: Request) -> tuple[bool, str]:
        ok, why = _local_can(request)
        if ok and "local-runtime" not in st.capability(s.status_dir)["local"]:
            ok, why = False, "This update helper does not install runtimes yet: ./stack helper install refreshes it."
        return ok, why

    async def local_models_runtime(request: Request) -> Response:
        """A model runtime installed, started or removed (lib/runtimes.sh: ./stack runtimes OP ID on the computer). Session +
        password like the rest of Settings; the page follows the job in GET /api/local-models (runtimes.job)."""
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        op, rid = data.get("op"), data.get("id")
        if op not in st.RUNTIME_OPS_PW or rid not in st.RUNTIME_IDS:
            return err(400, "bad request")
        ok, why = _runtime_can(request)
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        r = lm.read_runtimes(s.status_dir)
        if r["job"]["state"] == "running":
            return err(409, "A runtime job is running: wait for it.")
        cur = next((x for x in r["runtimes"] if x["id"] == rid), None)
        if op == "install" and cur and cur["state"] in ("external", "unsupported"):
            return err(409, f"Ollama cannot be installed here: {cur['why_not'] or 'an Ollama of yours already runs on 127.0.0.1:11434'}.")
        if wait := runtime_rate.retry_after():
            return err(429, f"Please wait {wait} s.", wait)
        try:
            nonce = st.write_runtime_action(s.request_dir, op, rid, password)
        except ValueError:
            return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
        except OSError as e:
            log.warning("cannot write the runtime %s request to %s (%s)", op, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        runtime_rate.hit()
        log.warning("runtimes: %s %s%s", op, rid, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "op": op}, status_code=202))

    async def local_models_runtime_stop(request: Request) -> Response:
        """A runtime stopped, the running install cancelled, or its log asked for. No password: it stops something or reads
        its log, and spends nothing; otherwise the same door as every other change (session, X-Requested-With, same Origin,
        the remote rule, a bounded JSON body)."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        length = request.headers.get("content-length", "")
        if not length.isdigit() or not length.isascii() or int(length) > st.MAX_BODY:
            return err(411 if not length.isdigit() else 413, "Content-Length required" if not length.isdigit() else "request too large")
        try:
            data = json.loads(await request.body())
        except ValueError:
            return err(400, "not JSON")
        op, rid = (data.get("op"), data.get("id")) if isinstance(data, dict) else (None, None)
        if op not in st.RUNTIME_OPS_FREE or rid not in st.RUNTIME_IDS:
            return err(400, "bad request")
        ok, why = _runtime_can(request)
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        r = lm.read_runtimes(s.status_dir)
        cur = next((x for x in r["runtimes"] if x["id"] == rid), None)
        if op == "stop" and not (cur and cur["managed"] and cur["state"] in ("running", "starting")):
            return err(409, "It is not running (and one of yours is never stopped from here).")
        if op == "cancel" and not (r["job"]["state"] == "running" and r["job"]["op"] == "install"):
            return err(409, "No install is running.")
        if op != "logs" and r["job"]["state"] == "running" and op != "cancel":
            return err(409, "A runtime job is running: wait for it.")
        rate = runtime_log_rate if op == "logs" else runtime_free_rate
        if wait := rate.retry_after():
            return err(429, f"Please wait {wait} s.", wait)
        try:
            nonce = st.write_runtime_action(s.request_dir, op, rid)
        except OSError as e:
            log.warning("cannot write the runtime %s request to %s (%s)", op, s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        rate.hit()
        if op != "logs":
            log.warning("runtimes: %s %s%s", op, rid, " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "op": op}, status_code=202))

    async def local_models_runtime_logs(request: Request) -> Response:
        """The last lines of a runtime's log, as the helper last copied them (POST …/runtime-stop op logs asks for a fresh copy)."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        rid = request.query_params.get("id")
        if rid not in st.RUNTIME_IDS:
            return err(400, "bad request")
        return _no_store(JSONResponse(lm.read_runtime_logs(s.status_dir, rid)))

    server_rate = RateLimit(1, 300)

    async def local_models_server(request: Request) -> Response:
        """The model-server form: probe a candidate address (nothing saved), save it with the models to register, change
        a saved server's models or key, remove it. Session + password like the rest of Settings; the work is the helper's,
        on this computer (so no server address is ever fetched from the portal's container). The API key goes to the
        helper in the one owner-only request and is never answered or logged; the page reads the outcome from the status
        (result, matched by the ref returned here)."""
        got = await front_door(request)
        if isinstance(got, Response):
            return got
        data, password = got
        op, name, url = data.get("op"), data.get("name") or "", data.get("url") or ""
        key, models = data.get("key") or "", data.get("models") or []
        if op not in st.LOCAL_SERVER_OPS or not all(isinstance(x, str) for x in (name, url, key)) \
                or not isinstance(models, list) or not all(isinstance(x, str) for x in models) or len(models) > 200:
            return err(400, "bad request")
        ok, why = _local_can(request)
        if ok and "local-server" not in st.capability(s.status_dir)["local"]:
            ok, why = False, "This update helper does not do model servers yet: ./stack helper install refreshes it."
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        if wait := server_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next change.", wait)
        url = url.strip()
        if url and "://" in url and not re.match(r"https?://", url):
            return err(400, "The address starts with http:// or https:// (or is just host:port).")
        if url and "://" not in url:
            url = "http://" + url
        trust = data.get("trust") is True and url.startswith("https://")   # (a certificate only exists for https)
        ref = secrets.token_hex(8)
        try:
            nonce = st.write_local_server_action(s.request_dir, password, op, name=name, url=url, trust=trust, key=key.strip(),
                                                 models=",".join(models), ref=ref)
        except ValueError as e:
            if "password" in str(e):
                return err(413, f"The portal password is longer than {st.MAX_AUTH} bytes: set a shorter one with ./stack config set PORTAL_PASSWORD.")
            return err(400, "That address, name, key or model list is not one DevOS ADE can use (names: lowercase letters, digits and -).")
        except OSError as e:
            log.warning("cannot write the model-server request to %s (%s)", s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        server_rate.hit()
        log.warning("model servers: %s %s%s", op, name or "(candidate)", " (remote)" if is_remote(request) else "")
        return _no_store(JSONResponse({"id": nonce, "op": op, "ref": ref}, status_code=202))

    async def local_models_probe(request: Request) -> Response:
        """"Check server": ask a candidate address for its model list. Read-only for the stack and nothing is saved, so no
        password: but the same door as every other change otherwise (session, X-Requested-With, same Origin, the remote
        rule, a bounded JSON body) and the same rate limit. The probe itself is the helper's, on this computer, with every
        SSRF guard it always had (metadata and link-local refused, the name canonicalized, the checked address pinned): the
        portal fetches nothing. The key, if typed, goes to the helper in the one owner-only request and is never answered."""
        if (deny := ctx.api_guard(request)) is not None:
            return deny
        if not same_origin(request.headers, s):
            return err(403, "cross-site request refused")
        if not allowed(request):
            return err(403, "Settings changes are off for remote access (REMOTE_ADMIN_ACTIONS in .env).")
        length = request.headers.get("content-length", "")
        if not length.isdigit() or not length.isascii() or int(length) > st.MAX_BODY:
            return err(411 if not length.isdigit() else 413, "Content-Length required" if not length.isdigit() else "request too large")
        try:
            data = json.loads(await request.body())
        except ValueError:
            return err(400, "not JSON")
        if not isinstance(data, dict):
            return err(400, "not a JSON object")
        url, key = data.get("url") or "", data.get("key") or ""
        if not isinstance(url, str) or not isinstance(key, str) or not url.strip():
            return err(400, "bad request")
        ok, why = _local_can(request)
        if ok and "local-probe" not in st.capability(s.status_dir)["local"]:
            ok, why = False, "This update helper cannot check servers without the password yet: ./stack helper install refreshes it."
        if not ok:
            return err(403 if not allowed(request) else 503, why)
        if wait := server_rate.retry_after():
            return err(429, f"Please wait {wait} s before the next check.", wait)
        url = url.strip()
        if "://" in url and not re.match(r"https?://", url):
            return err(400, "The address starts with http:// or https:// (or is just host:port).")
        if "://" not in url:
            url = "http://" + url
        # (no password only for this computer's own addresses; the helper judges the pinned address again and refuses the rest)
        if not _LOOPBACK_URL.match(url):
            return err(403, "Checking another computer asks for your portal password.")
        trust = data.get("trust") is True and url.startswith("https://")
        ref = secrets.token_hex(8)
        try:
            nonce = st.write_local_probe_action(s.request_dir, url=url, trust=trust, key=key.strip(), ref=ref)
        except ValueError:
            return err(400, "That address or key is not one DevOS ADE can use.")
        except OSError as e:
            log.warning("cannot write the model-server check to %s (%s)", s.request_dir, e)
            return err(500, "Could not hand the request to the helper (see ./stack logs portal).")
        server_rate.hit()
        return _no_store(JSONResponse({"id": nonce, "op": "probe", "ref": ref}, status_code=202))

    return [
        Route("/api/local-models", local_models_get, methods=["GET"]),
        Route("/api/local-models/search", local_models_search, methods=["GET"]),
        Route("/api/local-models/change", local_models_change, methods=["POST"]),
        Route("/api/local-models/server", local_models_server, methods=["POST"]),
        Route("/api/local-models/probe", local_models_probe, methods=["POST"]),
        Route("/api/local-models/stop", local_models_stop, methods=["POST"]),
        Route("/api/local-models/runtime", local_models_runtime, methods=["POST"]),
        Route("/api/local-models/runtime-stop", local_models_runtime_stop, methods=["POST"]),
        Route("/api/local-models/runtime-logs", local_models_runtime_logs, methods=["GET"]),
        Route("/api/models/browse", models_browse, methods=["GET"]),
        Route("/api/models/browse/plan", models_plan, methods=["POST"]),
        Route("/api/models/try", models_try, methods=["POST"]),
        Route("/api/settings", get_settings, methods=["GET"]),
        Route("/api/settings/apply", apply, methods=["POST"]),
        Route("/api/settings/check-key", check_key, methods=["POST"]),
        Route("/api/settings/reveal", reveal, methods=["POST"]),
        Route("/api/settings/action", action, methods=["POST"]),
        Route("/api/settings/project", project_action, methods=["POST"]),
        Route("/api/settings/sessions", sessions_action, methods=["POST"]),
        Route("/api/settings/subscriptions", subscriptions_action, methods=["POST"]),
        Route("/api/settings/signout-others", signout_others, methods=["POST"]),
        Route("/api/settings/report", get_report, methods=["GET"]),
    ]
