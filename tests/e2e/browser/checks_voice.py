"""Voice: Bedrock speech-to-text (the stt container, Mistral Voxtral through LiteLLM) as Open WebUI and Home use it.
Each check follows the throwaway's current setting (.env), so run.sh runs them again after ./stack stt remove and
./stack stt set bedrock (results id@stt-off / id@stt-on-again)."""

from __future__ import annotations

import base64
import json
import re
import time
from pathlib import Path

from playwright.sync_api import Error as PwError

from checks_browser import chat_frame, login, shot
from common import ENV, Skip, check, expect, need, origin

FIXTURE = Path(__file__).parent / "fixtures" / "speech.webm"   # espeak-ng: fixtures/make-speech.sh
# Since October 2026 Bedrock refuses audio for both Voxtral models: ./stack turns Bedrock speech-to-text off once and
# says so (lib/stt.sh STT_REFUSED_NOTICE) — on Home's voice line and as one Activity item
# (where speech-to-text is turned on: the link the voice line ends with, catalog/setup-links.tsv voice-off)
VOICE_SETUP = "Settings › Chat & voice › Speech-to-text"
REFUSED_NOTICE = ("Voice: Bedrock speech-to-text was turned off: AWS no longer accepts audio for the Voxtral models (since "
                  "October 2026). Voice uses your browser's speech recognition; or use your own OpenAI/Groq key: "
                  "./stack stt set openai|groq.")


def stt_mode() -> str:
    """bedrock | openai | groq while server speech-to-text is on, else browser."""
    if ENV.get("OWUI_STT_ENGINE") == "openai" and ENV.get("STT_PROVIDER") in ("bedrock", "openai", "groq"):
        return ENV["STT_PROVIDER"]
    return "browser"


@check("browser", "home-voice-line")
def home_voice(ctx):
    page, rec = ctx.page("home-voice")
    login(page)
    note = page.locator("#voice-note")
    page.locator("#models-more").wait_for(state="attached", timeout=30000)
    # the voice line lives in Home's collapsed "more" details (JON-515): open it
    if not page.evaluate("() => document.getElementById('models-more').open"):
        page.click("#models-more > summary")
    note.wait_for(timeout=30000)
    page.locator("#voice-note", has_text="Voice:").wait_for(timeout=30000)
    text = note.inner_text()
    if stt_mode() == "bedrock":
        expect(text.startswith("Voice: Bedrock Mistral Voxtral"), f"voice line {text!r}")
        expect("estimated" in text and "per minute of audio" in text and "your AWS account" in text, f"voice line {text!r}")
    elif stt_mode() == "browser" and text.startswith("Voice: Bedrock speech-to-text was turned off"):
        # AWS refused the audio: the notice, word for word, then where speech-to-text is turned on (a link to Settings at
        # its row: catalog/setup-links.tsv voice-off), and its one Activity item (a voice choice ends both)
        expect(text == f"{REFUSED_NOTICE} {VOICE_SETUP}", f"voice line {text!r}")
        link = note.locator("a[href='#settings/STT_PROVIDER']")
        expect(link.count() == 1 and link.inner_text() == VOICE_SETUP, f"voice line's link: {link.count()}")
        act = page.evaluate("""async () => { const r = await fetch('/api/activity', {headers: {'X-Requested-With': 'devos-ade'}});
            return {status: r.status, body: await r.text()}; }""")
        expect(act["status"] == 200, f"/api/activity {act['status']}")
        items = [i for i in json.loads(act["body"]).get("items") or [] if i.get("kind") == "voice"]
        expect(len(items) == 1 and items[0]["title"] == "Bedrock speech-to-text was turned off"
               and items[0]["link"] == "#settings/STT_PROVIDER", f"Activity voice items {items!r}")
        rec.save()
        return "browser speech after AWS refused Voxtral's audio: the notice on Home and one Activity item"
    elif stt_mode() == "browser":
        expect(text.startswith("Voice: browser speech recognition (Call is unavailable)") and text.endswith(VOICE_SETUP), f"voice line {text!r}")
    rec.save()
    return f"{stt_mode()}: {text[:110]!r}"


# The call's own End call button. (Open WebUI 0.13 opens a call as a chat tab too, and that tab's close button is also
# named "End call": it is the one with a title, "Close · <shortcut>".)
END_CALL = "button[aria-label='End call']:not([title])"


# Chat has set up its new conversation once its model picker names the selected model. Open WebUI 0.13.5 sets a new chat
# up after the model list arrives, and that ends any call (Chat.svelte initNewChat: voiceCall false): a call started
# before it never opens, silently (0.79.0a: the first call of a lane; the next one, with the list already fetched, opened).
SETTLED = "#model-selector-model-button[aria-label^='Selected model:']"


def chat_settled(fl) -> float:
    """Waits (30 s at most) until Chat has set up its new conversation; returns the seconds it took."""
    t0 = time.monotonic()
    fl.locator(SETTLED).wait_for(timeout=30000)
    return time.monotonic() - t0


def call_opens(page, fl, f, rec, name: str) -> None:
    """Waits for the call's End call button; when it does not come in 15 s, fails with what Chat showed instead
    (a screenshot NAME-not-open and the frame's visible buttons and dialogs)."""
    try:
        fl.locator(END_CALL).wait_for(timeout=15000)
        return
    except PwError:
        pass
    shot(page, f"{name}-not-open")
    seen = f.evaluate("""() => {
        const vis = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
        const btn = [...document.querySelectorAll('button')].filter(vis).map(b =>
            ((b.getAttribute('aria-label') || b.textContent || '').trim().slice(0, 40)) + (b.title ? ' [title]' : ''));
        const dlg = [...document.querySelectorAll('[role=dialog], dialog, .modal')].filter(vis).map(d =>
            d.textContent.trim().replace(/\\s+/g, ' ').slice(0, 160));
        return {buttons: btn.slice(0, 40), dialogs: dlg.slice(0, 3)}; }""")
    rec.save()
    raise AssertionError(f"the call did not open in 15 s: dialogs {seen['dialogs']}; buttons {seen['buttons']}")


@check("browser", "chat-voice-call")
def chat_call(ctx):
    """Call with server speech-to-text: the call opens ("Listening…", End call); without it Open WebUI (v0.12.4) offers
    no Call button at all (README troubleshooting row)."""
    need("open-webui")
    page, rec = ctx.page("chat-call")
    page.context.grant_permissions(["microphone"], origin=origin("chat"))
    login(page)
    fl, f = chat_frame(page)
    if stt_mode() == "browser":
        # (the empty message box's button is Send, greyed: Call would take its place)
        fl.locator("button[aria-label='Send message']").wait_for(timeout=15000)
        page.wait_for_timeout(2000)
        expect(not fl.locator("button[aria-label='Voice mode']").count(), "Call is offered without server speech-to-text")
        shot(page, "10-chat-call-web-stt")
        rec.save()
        return "browser speech: no Call button"
    settled = chat_settled(fl)
    fl.locator("button[aria-label='Voice mode']").click()
    call_opens(page, fl, f, rec, "10-chat-call")
    fl.locator("text=Listening").first.wait_for(timeout=15000)
    shot(page, "10-chat-call-open")
    fl.locator(END_CALL).click()
    # A blocked screen wake lock is reported by chat-voice-call-wake-lock alone; anything else counts here.
    probs = rec.problems(allow=[r"No token found in localStorage", r"Permissions policy violation: screen-wake-lock"])
    rec.save()
    expect(not probs, f"errors: {probs}")
    return (f"{stt_mode()} speech-to-text: Call opens (Listening…, End call), no Web-STT error; Chat set up "
            f"{settled:.1f} s after its message box")


@check("browser", "chat-voice-call-wake-lock")
def chat_call_wake_lock(ctx):
    """In the Chat tab (the portal's frame) a Call may keep the screen awake: Open WebUI asks for a wake lock."""
    need("open-webui")
    if stt_mode() == "browser":
        raise Skip("no server speech-to-text: Call does not start")
    page, rec = ctx.page("chat-call-wake-lock")
    page.context.grant_permissions(["microphone"], origin=origin("chat"))
    login(page)
    fl, f = chat_frame(page)
    chat_settled(fl)
    fl.locator("button[aria-label='Voice mode']").click()
    call_opens(page, fl, f, rec, "10b-chat-call-wake-lock")
    fl.locator("text=Listening").first.wait_for(timeout=15000)
    fl.locator(END_CALL).click()
    blocked = [e["text"] for e in rec.events if e["t"] == "console" and "screen-wake-lock" in e["text"]]
    rec.save()
    expect(not blocked, f"{blocked[:1]} — the portal's iframe allow list lacks screen-wake-lock")
    return "Call in the portal frame may hold a screen wake lock"


@check("browser", "stt-transcription")
def stt_transcription(ctx):
    """A spoken WebM clip (as a browser records it) through Open WebUI's /api/v1/audio/transcriptions → Caddy :8090 →
    the stt container → LiteLLM → Bedrock Voxtral."""
    need("open-webui")
    if stt_mode() == "browser":
        raise Skip("speech-to-text is off (browser speech): nothing to transcribe on the server")
    page, rec = ctx.page("stt-transcription")
    login(page)
    fl, f = chat_frame(page)
    r = f.evaluate("""async (b64) => { const bin = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
        const fd = new FormData(); fd.append('file', new Blob([bin], {type: 'audio/webm'}), 'speech.webm');
        const r = await fetch('/api/v1/audio/transcriptions', {method: 'POST',
            headers: {Authorization: 'Bearer ' + localStorage.token}, body: fd});
        return {status: r.status, body: await r.text()}; }""", base64.b64encode(FIXTURE.read_bytes()).decode())
    expect(r["status"] == 200, f"/api/v1/audio/transcriptions {r['status']}: {r['body'][:200]}")
    text = (json.loads(r["body"]).get("text") or "").lower()
    said = (Path(__file__).parent / "fixtures" / "speech.txt").read_text(encoding="utf-8").lower()
    words = [w for w in ("hello", "world", "voice", "test") if w in said]
    heard = [w for w in words if re.search(rf"\b{w}\b", text)]
    rec.save()
    expect(len(heard) >= 3, f"transcript {text!r} lacks most of {words}")
    return f"{stt_mode()}: {FIXTURE.stat().st_size // 1024} KB WebM → {text!r}"
