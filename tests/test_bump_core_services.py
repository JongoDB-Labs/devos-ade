"""bin/bump-core-services against faked GitHub / registry / Docker Hub answers: no network, no real files of the repo."""
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("bump", str(ROOT / "bin" / "bump-core-services"))
_spec = importlib.util.spec_from_loader("bump", _loader)
bump = importlib.util.module_from_spec(_spec)
sys.modules["bump"] = bump
_loader.exec_module(bump)

NOW = "2026-10-27T12:00:00Z"
D = lambda n: "sha256:" + f"{n:x}".ljust(64, "0")   # a digest


def rel(tag, when, body="", pre=False):
    return {"tag_name": tag, "published_at": when, "prerelease": pre, "draft": False, "body": body,
            "html_url": f"https://github.com/x/y/releases/tag/{tag}"}


def ghsa(aid, repo, patched, pkg=None):
    return {"ghsa_id": aid, "source_code_location": "https://github.com/" + repo,
            "vulnerabilities": [{"package": {"ecosystem": "other", "name": pkg or repo.split("/")[1]}, "first_patched_version": patched}]}


class FakeNet:
    """Answers the three network calls from tables; any other request fails the test."""

    def __init__(self, gh=None, hub=None, digests=None, hashes=None, adv=None):
        self.gh, self.hub, self.digests, self.hashes = gh or {}, hub or {}, digests or {}, hashes or {}
        self.adv = adv or {}   # advisory id -> advisory dict (GHSA) ; CVE id -> list
        self.calls = []

    def json(self, url):
        self.calls.append(url)
        if "/advisories" in url:
            if "cve_id=" in url:
                return self.adv.get(url.split("cve_id=")[1], [])
            key = url.rsplit("/", 1)[-1]
            if key in self.adv:
                return self.adv[key]
            raise urllib.error.HTTPError(url, 404, "not found", None, None)
        for repo, rels in self.gh.items():
            if f"/repos/{repo}/releases" in url:
                return rels if "page=1" in url else []
        for repo, d in self.hub.items():
            if f"/repositories/{repo}/tags" in url:
                return {"results": d, "next": None}
        raise AssertionError("unexpected request " + url)

    def digest(self, registry, name, tag):
        self.calls.append(f"digest {registry}/{name}:{tag}")
        return self.digests[f"{name}:{tag}"]

    def sha256(self, url):
        self.calls.append("sha256 " + url)
        return self.hashes[url]


def tree(files):
    d = tempfile.mkdtemp()
    for rel_, text in files.items():
        p = Path(d) / rel_
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return d


def read(d, rel_):
    return (Path(d) / rel_).read_text()


def now():
    return bump.parse_time(NOW)


class PickTests(unittest.TestCase):
    def cands(self, *items):
        return [bump.Candidate(v, bump.parse_time(w), "u", n) for v, w, n in items]

    def test_newest_past_the_cooldown_wins_and_the_newer_is_held_back(self):
        c = self.cands(("1.6.5", "2026-10-27T10:00:00Z", ""), ("1.6.3", "2026-10-24T09:00:00Z", ""), ("1.6.2", "2026-10-21T00:00:00Z", ""))
        chosen, newest, why = bump.pick(c, "1.5.0", now())
        self.assertEqual((chosen.version, newest.version), ("1.6.3", "1.6.5"))
        self.assertIn("held back: 1.6.5 is 0d old", why)

    def test_exactly_three_days_old_counts(self):
        c = self.cands(("2.0.0", "2026-10-24T12:00:00Z", ""), ("1.9.0", "2026-09-01T00:00:00Z", ""))
        self.assertEqual(bump.pick(c, "1.9.0", now())[0].version, "2.0.0")
        c = self.cands(("2.0.0", "2026-10-24T12:00:01Z", ""), ("1.9.0", "2026-09-01T00:00:00Z", ""))
        self.assertEqual(bump.pick(c, "1.9.0", now())[0].version, "1.9.0")

    SEC = ("1.0.4", "2026-10-27T10:00:00Z", "This release contains security fixes. CVE-2026-1234")

    def test_notes_that_say_security_never_skip_the_cooldown(self):
        c = self.cands(self.SEC, ("1.0.3", "2026-10-01T00:00:00Z", ""))
        chosen, _, why = bump.pick(c, "1.0.1", now())
        self.assertEqual(chosen.version, "1.0.3")
        self.assertIn("REVIEW: upstream says security fix in 1.0.4", why)
        self.assertIn("--allow-security", why)
        self.assertIn("held back", why)

    def test_a_confirmed_advisory_skips_the_cooldown_to_the_oldest_patched_release(self):
        c = self.cands(("1.0.5", "2026-10-27T11:00:00Z", ""), self.SEC, ("1.0.3", "2026-10-01T00:00:00Z", ""))
        chosen, newest, why = bump.pick(c, "1.0.1", now(), patched=("1.0.4", "GHSA-aaaa-bbbb-cccc"))
        self.assertEqual((chosen.version, newest.version), ("1.0.4", "1.0.5"))   # not the newest: the smallest step that fixes it
        self.assertIn("security fix: GHSA-aaaa-bbbb-cccc", why)

    def test_an_advisory_does_not_move_a_release_already_past_the_patch(self):
        c = self.cands(("1.0.6", "2026-10-01T00:00:00Z", ""), ("1.0.5", "2026-09-01T00:00:00Z", ""))
        chosen, _, why = bump.pick(c, "1.0.1", now(), patched=("1.0.4", "GHSA-aaaa-bbbb-cccc"))
        self.assertEqual(chosen.version, "1.0.6")
        self.assertNotIn("security fix", why)

    def test_an_advisory_with_no_release_at_the_patch_changes_nothing(self):
        c = self.cands(("1.0.3", "2026-10-01T00:00:00Z", ""))
        chosen, _, why = bump.pick(c, "1.0.1", now(), patched=("1.0.4", "GHSA-aaaa-bbbb-cccc"))
        self.assertEqual(chosen.version, "1.0.3")
        self.assertIn("no release at or past it", why)

    def test_words_that_only_mention_security_do_not_count(self):
        c = self.cands(("1.0.4", "2026-10-27T10:00:00Z", "Various improvements to performance, stability, and security."), ("1.0.3", "2026-10-01T00:00:00Z", ""))
        self.assertEqual(bump.pick(c, "1.0.1", now())[0].version, "1.0.3")

    def test_never_older_than_the_pin(self):
        c = self.cands(("1.0.4", "2026-10-27T10:00:00Z", ""), ("1.0.0", "2026-09-01T00:00:00Z", ""))
        self.assertEqual(bump.pick(c, "1.0.2", now())[0].version, "1.0.2")   # nothing newer is past the cooldown: it stays

    def test_version_order_is_numeric(self):
        c = self.cands(("1.9.0", "2026-01-01T00:00:00Z", ""), ("1.10.0", "2026-01-02T00:00:00Z", ""))
        self.assertEqual(bump.pick(c, "1.0.0", now())[0].version, "1.10.0")


COMPOSE = """services:
  litellm:
    image: ghcr.io/berriai/litellm:1.105.0
  open-webui:
    build:
      args:
        image: ghcr.io/open-webui/open-webui:v0.12.0-slim@%s
    image: ${COMPOSE_PROJECT_NAME:-bedrock-now}/open-webui:local
  caddy:
    image: caddy:2.11.7-alpine@%s
""" % (D(1), D(2))


class ImageTargetTests(unittest.TestCase):
    def target(self, name):
        return next(t for t in bump.targets() if t.name == name)

    def test_litellm_is_pinned_by_digest_and_the_e2e_tested_version_follows(self):
        d = tree({"compose.yaml": COMPOSE, bump.E2E_TESTED: 'TESTED_WITH = {"open-webui": "v0.12.0-slim", "litellm": "1.105.0", "rustfs": "1.0.1"}\n'})
        net = FakeNet(gh={"BerriAI/litellm": [rel("v1.106.5", "2026-10-27T11:00:00Z"), rel("v1.106.3", "2026-10-24T09:00:00Z"),
                                              rel("v1.105.0", "2026-10-01T00:00:00Z"), rel("v1.107.0rc1", "2026-10-20T00:00:00Z", pre=True)]},
                      digests={"berriai/litellm:1.106.3": D(7)})
        fs = bump.Files(d)
        m = self.target("litellm").run(net, fs, now(), 3)
        fs.flush()
        self.assertEqual((m.old, m.new, m.newest), ("1.105.0", "1.106.3", "1.106.5"))
        self.assertIn("ghcr.io/berriai/litellm:1.106.3@" + D(7), read(d, "compose.yaml"))
        self.assertIn('"litellm": "1.106.3"', read(d, bump.E2E_TESTED))
        self.assertIn('"rustfs": "1.0.1"', read(d, bump.E2E_TESTED))   # the others stay
        self.assertTrue(m.held)

    def test_open_webui_moves_everywhere_it_is_named(self):
        d = tree({"compose.yaml": COMPOSE, "open-webui/Dockerfile": "ARG image=ghcr.io/open-webui/open-webui:v0.12.0-slim@%s\nFROM ${image}\n" % D(1),
                  bump.E2E_TESTED: '{"open-webui": "v0.12.0-slim"}'})
        net = FakeNet(gh={"open-webui/open-webui": [rel("v0.12.4", "2026-10-25T08:00:00Z", "🛡️ **Security Advisory**: This release contains **security fixes**."),
                                                    rel("v0.12.3", "2026-10-16T08:00:00Z")]},
                      digests={"open-webui/open-webui:v0.12.4-slim": D(9)},
                      adv={"GHSA-xxxx-yyyy-zzzz": ghsa("GHSA-xxxx-yyyy-zzzz", "open-webui/open-webui", "0.12.4")})
        fs = bump.Files(d)
        m = self.target("open-webui").run(net, fs, now(), 3, bump.Allow(["GHSA-xxxx-yyyy-zzzz"], net))
        fs.flush()
        self.assertEqual(m.new, "0.12.4")
        self.assertIn("security fix", m.why)
        for f in ("compose.yaml", "open-webui/Dockerfile"):
            self.assertIn("open-webui:v0.12.4-slim@" + D(9), read(d, f))
            self.assertNotIn("v0.12.0", read(d, f))
        self.assertIn(f"{COMPOSE.splitlines()[-2][:0]}", read(d, "compose.yaml"))
        self.assertIn("/open-webui:local", read(d, "compose.yaml"))   # the local build's name is not a pin

    def test_caddy_keeps_both_images_in_step_and_the_arg(self):
        d = tree({"compose.yaml": COMPOSE,
                  "caddy/Dockerfile": "ARG CADDY_VERSION=2.11.7\nFROM caddy:2.11.7-builder-alpine@%s AS build\nFROM caddy:2.11.7-alpine@%s\n" % (D(3), D(2))})
        net = FakeNet(gh={"caddyserver/caddy": [rel("v2.12.0", "2026-10-01T00:00:00Z")]},
                      digests={"library/caddy:2.12.0-alpine": D(5), "library/caddy:2.12.0-builder-alpine": D(6)})
        fs = bump.Files(d)
        self.target("caddy").run(net, fs, now(), 3)
        fs.flush()
        t = read(d, "caddy/Dockerfile")
        self.assertIn("ARG CADDY_VERSION=2.12.0", t)
        self.assertIn("caddy:2.12.0-builder-alpine@" + D(6), t)
        self.assertIn("caddy:2.12.0-alpine@" + D(5), t)
        self.assertIn("caddy:2.12.0-alpine@" + D(5), read(d, "compose.yaml"))

    def test_the_same_release_keeps_its_digest_and_asks_the_registry_nothing(self):
        d = tree({"compose.yaml": COMPOSE, "caddy/Dockerfile": "ARG CADDY_VERSION=2.11.7\nFROM caddy:2.11.7-builder-alpine@%s AS build\nFROM caddy:2.11.7-alpine@%s\n" % (D(3), D(2))})
        net = FakeNet(gh={"caddyserver/caddy": [rel("v2.11.7", "2026-10-03T00:00:00Z")]})
        fs = bump.Files(d)
        m = self.target("caddy").run(net, fs, now(), 3)
        self.assertFalse(m.changed)
        self.assertEqual(fs.flush(), [])
        self.assertFalse([c for c in net.calls if c.startswith("digest")])

    def test_a_pin_without_a_digest_gets_one(self):
        d = tree({"compose.yaml": "  rustfs:\n    image: rustfs/rustfs:1.0.1\n"})
        net = FakeNet(gh={"rustfs/rustfs": [rel("1.0.4", "2026-10-25T16:00:00Z"), rel("1.0.3", "2026-10-17T00:00:00Z")]},
                      digests={"rustfs/rustfs:1.0.3": D(4)})
        fs = bump.Files(d)
        self.target("rustfs").run(net, fs, now(), 3)
        fs.flush()
        self.assertIn("image: rustfs/rustfs:1.0.3@" + D(4), read(d, "compose.yaml"))

    def test_docker_hub_tags_use_their_push_date(self):
        d = tree({"compose.yaml": "    image: pgvector/pgvector:0.8.7-pg17@%s\n" % D(1)})
        tags = [{"name": "0.9.0-pg17", "tag_last_pushed": "2026-10-26T00:00:00Z"}, {"name": "0.8.8-pg17", "tag_last_pushed": "2026-10-20T00:00:00Z"},
                {"name": "0.9.0-pg16", "tag_last_pushed": "2026-10-01T00:00:00Z"}, {"name": "latest", "tag_last_pushed": "2026-10-27T00:00:00Z"}]
        net = FakeNet(hub={"pgvector/pgvector": tags}, digests={"pgvector/pgvector:0.8.8-pg17": D(8)})
        fs = bump.Files(d)
        m = self.target("pgvector").run(net, fs, now(), 3)
        fs.flush()
        self.assertEqual((m.new, m.newest), ("0.8.8", "0.9.0"))
        self.assertIn("pgvector:0.8.8-pg17@" + D(8), read(d, "compose.yaml"))

    def test_searxng_date_tags(self):
        d = tree({"compose.yaml": "    image: searxng/searxng:2026.10.11-ad46ebd7d@%s\n" % D(1)})
        tags = [{"name": "2026.10.27-28423d332", "tag_last_pushed": "2026-10-27T01:00:00Z"}, {"name": "2026.10.24-ef0ec03da", "tag_last_pushed": "2026-10-24T01:00:00Z"}]
        net = FakeNet(hub={"searxng/searxng": tags}, digests={"searxng/searxng:2026.10.24-ef0ec03da": D(2)})
        fs = bump.Files(d)
        m = self.target("searxng").run(net, fs, now(), 3)
        self.assertEqual(m.new, "2026.10.24-ef0ec03da")
        fs.flush()
        self.assertIn("searxng:2026.10.24-ef0ec03da@" + D(2), read(d, "compose.yaml"))


class BaseAndToolTests(unittest.TestCase):
    def test_a_base_image_digest_moves_only_when_the_tag_push_is_past_the_cooldown(self):
        text = "FROM python:3.12-slim@%s AS base\n" % D(1)
        for pushed, moved in (("2026-10-20T00:00:00Z", True), ("2026-10-26T00:00:00Z", False)):
            d = tree({"portal/Dockerfile": text, "shared-mcp/Dockerfile": text})
            net = FakeNet(hub={"library/python": [{"name": "3.12-slim", "tag_last_pushed": pushed}]}, digests={"library/python:3.12-slim": D(2)})
            fs = bump.Files(d)
            t = bump.BaseTarget("python-slim", "Python", "python", "3.12-slim", ["portal/Dockerfile", "shared-mcp/Dockerfile"])
            m = t.run(net, fs, now(), 3)
            fs.flush()
            self.assertEqual(m.changed, moved)
            self.assertEqual(D(2) in read(d, "portal/Dockerfile"), moved)
            self.assertEqual(D(2) in read(d, "shared-mcp/Dockerfile"), moved)

    def test_a_tool_gets_its_version_and_the_sha256_of_each_file(self):
        df = "ARG GH_VERSION=2.102.0\nARG GH_SHA256_AMD64=aaa\nARG GH_SHA256_ARM64=bbb\nARG OTHER=1\n"
        d = tree({"terminal/Dockerfile": df})
        base = "https://github.com/cli/cli/releases/download/v2.103.2/gh_2.103.2_linux_%s.tar.gz"
        net = FakeNet(gh={"cli/cli": [rel("v2.103.3", "2026-10-26T00:00:00Z"), rel("v2.103.2", "2026-10-23T00:00:00Z")]},
                      hashes={base % "amd64": "c" * 64, base % "arm64": "d" * 64})
        fs = bump.Files(d)
        gh = next(t for t in bump.targets() if t.name == "gh")
        m = gh.run(net, fs, now(), 3)
        fs.flush()
        self.assertEqual(m.new, "2.103.2")
        self.assertEqual(read(d, "terminal/Dockerfile"), f"ARG GH_VERSION=2.103.2\nARG GH_SHA256_AMD64={'c' * 64}\nARG GH_SHA256_ARM64={'d' * 64}\nARG OTHER=1\n")

    def test_an_unchanged_tool_downloads_nothing(self):
        d = tree({"terminal/Dockerfile": "ARG TTYD_VERSION=1.7.7\nARG TTYD_SHA256_AMD64=a\nARG TTYD_SHA256_ARM64=b\n"})
        net = FakeNet(gh={"tsl0922/ttyd": [rel("1.7.7", "2024-03-30T00:00:00Z")]})
        fs = bump.Files(d)
        next(t for t in bump.targets() if t.name == "ttyd").run(net, fs, now(), 3)
        self.assertEqual(fs.flush(), [])
        self.assertFalse([c for c in net.calls if c.startswith("sha256")])


class PipTests(unittest.TestCase):
    OLD = "# header\n#    uv pip compile --generate-hashes --python-version 3.12 requirements.in -o requirements.txt\nanyio==4.15.1 \\\n    --hash=sha256:aa\nstarlette==1.7.0 \\\n    --hash=sha256:bb\n"

    def test_relock_with_hashes_and_the_cooldown_as_the_cutoff(self):
        d = tree({"portal/requirements.txt": self.OLD, "portal/requirements.in": "starlette\n"})
        seen = {}

        def runner(cmd, cwd):
            seen["cmd"], seen["cwd"] = cmd, cwd
            out = cmd[cmd.index("-o") + 1]
            Path(out).write_text(self.OLD.replace("1.7.0", "1.10.0").replace("--hash=sha256:bb", "--hash=sha256:cc").replace("requirements.txt", out))

        fs = bump.Files(d)
        m = bump.PipLock("pip-portal", "portal").run(FakeNet(), fs, now(), 3, runner)
        fs.flush()
        self.assertIn("--generate-hashes", seen["cmd"])
        self.assertEqual(seen["cmd"][seen["cmd"].index("--exclude-newer") + 1], "2026-10-24T12:00:00Z")
        self.assertTrue(seen["cwd"].endswith("portal"))
        self.assertIn("starlette 1.7.0 -> 1.10.0", m.why)
        t = read(d, "portal/requirements.txt")
        self.assertIn("starlette==1.10.0", t)
        self.assertIn("--hash=sha256:cc", t)
        self.assertIn("-o requirements.txt", t)   # not the temporary file's path

    def test_nothing_moved_leaves_the_file_alone(self):
        d = tree({"portal/requirements.txt": self.OLD, "portal/requirements.in": "starlette\n"})
        runner = lambda cmd, cwd: Path(cmd[cmd.index("-o") + 1]).write_text(self.OLD)
        fs = bump.Files(d)
        bump.PipLock("pip-portal", "portal").run(FakeNet(), fs, now(), 3, runner)
        self.assertEqual(fs.flush(), [])


class HoldAndRetryTests(unittest.TestCase):
    def test_a_held_pin_is_reported_and_never_rewritten(self):
        d = tree({"compose.tailscale.yaml": "    image: tailscale/tailscale:v1.102.5@%s\n" % D(1)})
        net = FakeNet(gh={"tailscale/tailscale": [rel("v1.104.2", "2026-10-20T00:00:00Z")]}, digests={"tailscale/tailscale:v1.104.2": D(2)})
        out = io.StringIO()
        rc = bump.main(["--now", NOW, "--only", "tailscale"], net=net, root=d, out=out)
        self.assertEqual(rc, 0)
        self.assertIn("HELD", out.getvalue())
        self.assertIn("would move to 1.104.2", out.getvalue())
        self.assertIn("v1.102.5@" + D(1), read(d, "compose.tailscale.yaml"))

    def test_a_dropped_connection_is_tried_again_but_a_404_is_not(self):
        n = {"calls": 0}

        def flaky():
            n["calls"] += 1
            if n["calls"] < 3:
                raise __import__("http.client").client.IncompleteRead(b"x")
            return "ok"

        orig = bump.time.sleep
        bump.time.sleep = lambda s: None
        try:
            self.assertEqual(bump.Net.retrying(flaky), "ok")
            self.assertEqual(n["calls"], 3)

            def gone():
                n["calls"] += 1
                raise urllib.error.HTTPError("u", 404, "no", {}, None)
            n["calls"] = 0
            with self.assertRaises(urllib.error.HTTPError):
                bump.Net.retrying(gone)
            self.assertEqual(n["calls"], 1)
        finally:
            bump.time.sleep = orig


class RegistryTests(unittest.TestCase):
    def test_digest_follows_the_registry_token_challenge(self):
        calls = []

        class R:
            headers = {"Docker-Content-Digest": D(5)}
            def __enter__(self): return self
            def __exit__(self, *a): return False

        net = bump.Net()

        def fake_open(url, headers=None, method="GET"):
            calls.append((method, url, (headers or {}).get("Authorization")))
            if not (headers or {}).get("Authorization"):
                raise urllib.error.HTTPError(url, 401, "no", {"WWW-Authenticate": 'Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:x/y:pull"'}, None)
            return R()

        net._open = fake_open
        net.json = lambda url: {"token": "T"}
        self.assertEqual(net.digest("ghcr.io", "x/y", "1.0"), D(5))
        self.assertEqual([c[0] for c in calls], ["HEAD", "HEAD"])
        self.assertEqual(calls[1][2], "Bearer T")

    def test_registry_names(self):
        self.assertEqual(bump.registry_of("caddy"), ("registry-1.docker.io", "library/caddy"))
        self.assertEqual(bump.registry_of("rustfs/rustfs"), ("registry-1.docker.io", "rustfs/rustfs"))
        self.assertEqual(bump.registry_of("ghcr.io/berriai/litellm"), ("ghcr.io", "berriai/litellm"))


class AllowSecurityTests(unittest.TestCase):
    """Release notes never skip the cooldown; only --allow-security with an advisory the database confirms does."""
    PIN = "  rustfs:\n    image: rustfs/rustfs:1.0.1\n"

    def setUp(self):
        self.d = tree({"compose.yaml": self.PIN})

    def net(self, adv=None):
        return FakeNet(gh={"rustfs/rustfs": [rel("1.0.4", "2026-10-27T08:00:00Z", "Security fix: CVE-2026-9999 is patched."),
                                             rel("1.0.3", "2026-10-17T00:00:00Z")]},
                       digests={"rustfs/rustfs:1.0.3": D(4), "rustfs/rustfs:1.0.4": D(5)}, adv=adv)

    def run_main(self, net, *args):
        out = io.StringIO()
        rc = bump.main(["--now", NOW, "--only", "rustfs", *args], net=net, root=self.d, out=out)
        return rc, out.getvalue()

    def test_notes_alone_are_reported_and_not_taken(self):
        rc, out = self.run_main(self.net(), "--check")
        self.assertIn("!! rustfs: REVIEW: upstream says security fix in 1.0.4", out)
        self.assertIn("re-run with --allow-security", out)
        self.assertNotIn("1.0.4@", read(self.d, "compose.yaml"))
        rc, out = self.run_main(self.net())   # a real (non-check) run never auto-bypasses either
        self.assertIn("rustfs/rustfs:1.0.3@" + D(4), read(self.d, "compose.yaml"))

    def test_an_unknown_advisory_is_refused(self):
        rc, out = self.run_main(self.net(), "--allow-security", "GHSA-nope-nope-nope")
        self.assertEqual(rc, 1)
        self.assertIn("refused: not found in the GitHub Advisory Database", out)
        self.assertIn("rustfs/rustfs:1.0.3@" + D(4), read(self.d, "compose.yaml"))   # the cooldown pick, not 1.0.4

    def test_an_advisory_of_another_package_is_refused(self):
        net = self.net({"GHSA-aaaa-bbbb-cccc": ghsa("GHSA-aaaa-bbbb-cccc", "someone/else", "1.0.4")})
        rc, out = self.run_main(net, "--allow-security", "GHSA-aaaa-bbbb-cccc")
        self.assertEqual(rc, 1)
        self.assertIn("matches no pinned core service", out)
        self.assertNotIn("1.0.4@", read(self.d, "compose.yaml"))

    def test_a_cve_with_no_record_is_refused(self):
        rc, out = self.run_main(self.net(), "--allow-security", "CVE-2026-9999")
        self.assertEqual(rc, 1)
        self.assertNotIn("1.0.4@", read(self.d, "compose.yaml"))

    def test_an_advisory_whose_patch_is_not_in_the_release_does_not_skip_the_cooldown(self):
        net = self.net({"GHSA-aaaa-bbbb-cccc": ghsa("GHSA-aaaa-bbbb-cccc", "rustfs/rustfs", "1.0.9")})
        rc, out = self.run_main(net, "--allow-security", "GHSA-aaaa-bbbb-cccc")
        self.assertIn("no release at or past it exists yet", out)
        self.assertNotIn("1.0.4@", read(self.d, "compose.yaml"))

    def test_a_matching_advisory_allows_the_patched_release(self):
        net = self.net({"GHSA-aaaa-bbbb-cccc": ghsa("GHSA-aaaa-bbbb-cccc", "rustfs/rustfs", "1.0.4")})
        rc, out = self.run_main(net, "--allow-security", "GHSA-aaaa-bbbb-cccc")
        self.assertEqual(rc, 0)
        self.assertIn("security fix: GHSA-aaaa-bbbb-cccc is patched in 1.0.4", out)
        self.assertIn("rustfs/rustfs:1.0.4@" + D(5), read(self.d, "compose.yaml"))
        self.assertNotIn("REVIEW", out)

    def test_a_cve_id_is_looked_up_the_same_way(self):
        net = self.net({"CVE-2026-9999": [ghsa("GHSA-aaaa-bbbb-cccc", "rustfs/rustfs", "1.0.4")]})
        rc, _ = self.run_main(net, "--allow-security", "CVE-2026-9999")
        self.assertEqual(rc, 0)
        self.assertIn("rustfs/rustfs:1.0.4@" + D(5), read(self.d, "compose.yaml"))

    def test_the_flag_in_check_mode_changes_no_file(self):
        net = self.net({"GHSA-aaaa-bbbb-cccc": ghsa("GHSA-aaaa-bbbb-cccc", "rustfs/rustfs", "1.0.4")})
        rc, out = self.run_main(net, "--check", "--allow-security", "GHSA-aaaa-bbbb-cccc")
        self.assertEqual(rc, 3)
        self.assertEqual(read(self.d, "compose.yaml"), self.PIN)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.d = tree({"compose.yaml": "  rustfs:\n    image: rustfs/rustfs:1.0.1\n"})
        self.net = FakeNet(gh={"rustfs/rustfs": [rel("1.0.4", "2026-10-25T16:00:00Z"), rel("1.0.3", "2026-10-17T00:00:00Z")]},
                           digests={"rustfs/rustfs:1.0.3": D(4)})

    def run_main(self, *args):
        out = io.StringIO()
        rc = bump.main(["--now", NOW, "--only", "rustfs", *args], net=self.net, root=self.d, out=out)
        return rc, out.getvalue()

    def test_check_reports_and_changes_nothing(self):
        rc, out = self.run_main("--check")
        self.assertEqual(rc, 3)
        self.assertIn("1.0.1", out)
        self.assertIn("1.0.3", out)
        self.assertIn("https://github.com/x/y/releases/tag/1.0.3", out)   # the notes link
        self.assertIn("held back: 1.0.4", out)
        self.assertEqual(read(self.d, "compose.yaml"), "  rustfs:\n    image: rustfs/rustfs:1.0.1\n")

    def test_apply_then_check_is_quiet(self):
        rc, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("rustfs/rustfs:1.0.3@" + D(4), read(self.d, "compose.yaml"))
        rc, out = self.run_main("--check")
        self.assertEqual(rc, 0)
        self.assertIn("(up to date)", out)

    def test_the_manifest_lists_what_upstream_has(self):
        d = tree({"compose.yaml": "  rustfs:\n    image: rustfs/rustfs:1.0.1\n"})
        net = self.net
        fs = bump.Files(d)
        m = next(t for t in bump.targets() if t.name == "rustfs").run(net, fs, now(), 3)
        text = bump.write_manifest({"rustfs": m}, now())
        row = [l for l in text.splitlines() if l.startswith("rustfs\t")][0].split("\t")
        self.assertEqual(row[:3], ["rustfs", "RustFS", "1.0.4"])   # the newest upstream, not what is pinned
        self.assertEqual(row[3], "2026-10-25")                                    # when the newest came out
        self.assertEqual(row[4], "https://github.com/x/y/releases/tag/1.0.4")    # its notes, not the pinned release's
        self.assertRegex(row[5], r"^2026-10-2[78]$")                              # the day it was checked (local)

    def test_no_request_leaves_the_fake(self):
        # a test double that raises on anything it was not told: the tool asks only GitHub / registries through Net
        with self.assertRaises(AssertionError):
            FakeNet().json("https://example.invalid/")


if __name__ == "__main__":
    unittest.main()
