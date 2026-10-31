"""The UI control inventory (JON-869): name normalization and the diff between two releases' controls.json."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "e2e" / "browser"))
sys.path.insert(0, str(ROOT / "tests" / "e2e"))
import ui_inventory as inv  # noqa: E402
import ui_inventory_diff as dif  # noqa: E402


def c(role="button", name="Save", id="", disabled=False, frame=""):
    return {"role": role, "name": name, "disabled": disabled, "id": id, "frame": frame}


def book(*controls, hidden=(), key="portal-home-desktop-light"):
    return {key: {"visible": list(controls), "hidden_ids": list(hidden)}}


ALLOW = {"state": "portal-home-*", "control": "button:Save", "why": "moved into the menu", "changelog": "v0.45.1"}


class Normalize(unittest.TestCase):
    def test_numbers_versions_times_ids(self):
        n = inv.normalize_name
        self.assertEqual(n("Update to v0.45.1"), "Update to <ver>")
        self.assertEqual(n("Update to v0.45.1-rc.2"), "Update to <ver>")
        self.assertEqual(n("3 sessions"), "# sessions")
        self.assertEqual(n("Checked 2026-10-31T12:00:01+00:00"), "Checked <time>")
        self.assertEqual(n("Checked 2026-10-31"), "Checked <time>")
        self.assertEqual(n("at 4:05 PM"), "at <time>")
        self.assertEqual(n("Oct 31, 2026"), "<time>")
        self.assertEqual(n("session 3fa9c21b0d"), "session <id>")
        self.assertEqual(n("$1,234.50 spent"), "$# spent")

    def test_words_and_spacing_survive(self):
        self.assertEqual(n := inv.normalize_name("  Update   now \n"), "Update now")
        self.assertEqual(inv.normalize_name("Deploy the feature"), "Deploy the feature")   # "feature", "Deploy": hex-looking words stay
        self.assertEqual(inv.normalize_name(""), "")
        self.assertEqual(inv.normalize_name(None), "")

    def test_normalize_controls_and_merge(self):
        raw = {"visible": [{"role": "button", "name": "Open 3", "disabled": False, "id": "x"}], "hidden": ["gone"]}
        vis, hid = inv.normalize_controls(raw, "code.h")
        self.assertEqual(vis[0]["name"], "Open #")
        self.assertEqual(hid, ["code.h#gone"])
        b = {}
        inv.merge_state(b, "k", vis, hid)
        inv.merge_state(b, "k", vis, hid)
        self.assertEqual(len(b["k"]["visible"]), 1)


class Diff(unittest.TestCase):
    def run_(self, old, new, allow=()):
        return dif.run(old, new, list(allow))

    def kinds(self, res):
        return sorted((p["kind"], p["control"]) for p in res["problems"])

    def test_identical_is_clean(self):
        b = book(c(), c("link", "Docs"))
        self.assertEqual(self.run_(b, b)["problems"], [])

    def test_lost_control(self):
        r = self.run_(book(c(), c(name="Update now", id="update-now")), book(c()))
        self.assertEqual(self.kinds(r), [("lost", "#update-now")])

    def test_hidden_with_id_is_reported_as_still_in_page(self):
        r = self.run_(book(c(name="Update now", id="update-now")), book(hidden=["#update-now"]))
        self.assertIn("hidden", r["problems"][0]["detail"])

    def test_disabled(self):
        r = self.run_(book(c()), book(c(disabled=True)))
        self.assertEqual(self.kinds(r), [("disabled", "button:Save")])
        self.assertEqual(self.run_(book(c(disabled=True)), book(c()))["problems"], [])   # re-enabled is fine

    def test_lost_name(self):
        r = self.run_(book(c(id="b1")), book(c(name="", id="b1")))
        self.assertEqual(self.kinds(r), [("unnamed", "#b1")])

    def test_lost_state(self):
        r = self.run_({**book(c()), **book(c(), key="portal-settings-phone-dark")}, book(c()))
        self.assertEqual(self.kinds(r), [("lost-state", "*")])

    def test_new_controls_are_info_only(self):
        r = self.run_(book(c()), book(c(), c("link", "New")))
        self.assertEqual(r["problems"], [])
        self.assertEqual(r["new"], [{"state": "portal-home-desktop-light", "control": "link:New"}])

    def test_match_by_id_survives_a_rename(self):
        r = self.run_(book(c(name="Update now", id="u")), book(c(name="Update", id="u")))
        self.assertEqual(r["problems"], [])

    def test_two_ids_with_the_same_name_are_not_confused(self):
        r = self.run_(book(c(name="Open", id="a")), book(c(name="Open", id="b")))
        self.assertEqual(r["problems"], [])   # same role and name: still there (the id changed, the control did not go)

    def test_match_by_name_without_ids_and_other_frame_is_not_a_match(self):
        self.assertEqual(self.run_(book(c(frame="chat.h")), book(c(frame="chat.h")))["problems"], [])
        self.assertEqual(self.kinds(self.run_(book(c(frame="chat.h")), book(c()))), [("lost", "button:Save")])

    def test_allowlist_covers_by_state_glob_and_control(self):
        r = self.run_(book(c()), book(), [ALLOW])
        self.assertEqual(r["problems"], [])
        self.assertEqual(r["allowed"][0]["allowed_by"]["changelog"], "v0.45.1")
        other = self.run_(book(c(), key="portal-settings-desktop-light"), book(key="portal-settings-desktop-light"), [ALLOW])
        self.assertEqual(len(other["problems"]), 1)   # another state: not covered

    def test_allowlist_by_id_and_whole_state(self):
        a = {**ALLOW, "control": "#update-now"}
        self.assertEqual(self.run_(book(c(name="X", id="update-now")), book(), [a])["problems"], [])
        s = {**ALLOW, "state": "portal-settings-*", "control": "*"}
        old = {**book(c()), **book(c(), key="portal-settings-phone-dark")}
        self.assertEqual(self.run_(old, book(c()), [s])["problems"], [])

    def test_allowlist_entry_without_changelog_or_why_is_rejected(self):
        for drop in ("changelog", "why", "control", "state"):
            e = {k: v for k, v in ALLOW.items() if k != drop}
            with tempfile.TemporaryDirectory() as t:
                p = Path(t) / "a.json"
                p.write_text(json.dumps([e]))
                with self.assertRaises(ValueError, msg=drop):
                    dif.load_allow(p)
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "a.json"
            p.write_text(json.dumps([{**ALLOW, "changelog": "soon"}]))
            with self.assertRaises(ValueError):
                dif.load_allow(p)

    def test_cli_exit_codes_and_report(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / "o.json").write_text(json.dumps(book(c())))
            (t / "n.json").write_text(json.dumps(book()))
            (t / "ok.json").write_text(json.dumps([ALLOW]))
            (t / "bad.json").write_text(json.dumps([{"state": "*", "control": "*"}]))
            self.assertEqual(dif.main([str(t / "o.json"), str(t / "n.json"), "--allow", str(t / "none.json")]), 1)
            self.assertTrue(json.loads((t / "inventory-diff.json").read_text())["problems"])
            self.assertEqual(dif.main([str(t / "o.json"), str(t / "n.json"), "--allow", str(t / "ok.json")]), 0)
            self.assertEqual(dif.main([str(t / "o.json"), str(t / "n.json"), "--allow", str(t / "bad.json")]), 2)


if __name__ == "__main__":
    unittest.main()
