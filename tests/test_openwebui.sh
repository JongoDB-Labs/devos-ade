# shellcheck shell=bash
# Open WebUI's own image (open-webui/): the pinned Open WebUI with the Python runner's packages vendored into it —
# vendor.py's lock rewrite (only verified wheels, and only with all they need, get a relative name), its bounds, one
# pin everywhere, compose's local name that no pull can replace, the build's retry and the status line. No Docker:
# vendor.py runs here with a fake download.
. "$STACK_DIR/lib/commands.sh"

OWUI="$STACK_DIR/open-webui"

# _vendor_py SCRIPT — runs SCRIPT (Python, on stdin) with vendor.py loaded as `v` (isolated: python3 -I)
_vendor_py() {
  command -v python3 >/dev/null || return 77
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[1])
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
exec(sys.stdin.read())' "$OWUI/vendor.py"
}

test_vendor_rewrites_only_verified_wheels_with_all_they_need() {
  _vendor_py <<'PY' || return $?
import hashlib, json, os, tempfile
sha = lambda b: hashlib.sha256(b).hexdigest()
CDN = "https://cdn.jsdelivr.net/pyodide/v1/full/"
blobs = {"a": b"wheel a", "b": b"wheel b", "c": b"wheel c", "bad": b"not what the lock says", "needsbad": b"wheel nb", "other": b"x"}
lock = {"info": {"python": "3.14"}, "packages": {
  "a": {"file_name": CDN + "a-1-py3-none-any.whl", "sha256": sha(blobs["a"]), "depends": ["b"]},
  "b": {"file_name": CDN + "b-1-py3-none-any.whl", "sha256": sha(blobs["b"]), "depends": []},
  "c": {"file_name": CDN + "c-1-py3-none-any.whl", "sha256": sha(blobs["c"]), "depends": ["gone"]},
  "bad": {"file_name": CDN + "bad-1-py3-none-any.whl", "sha256": sha(b"the lock's own bytes"), "depends": []},
  "needsbad": {"file_name": CDN + "needsbad-1-py3-none-any.whl", "sha256": sha(blobs["needsbad"]), "depends": ["bad"]},
  "odd": {"file_name": CDN + "..%2fpyodide.js", "sha256": sha(b"x"), "depends": []},
  "own": {"file_name": CDN + "own-1-py3-none-any.whl", "sha256": sha(b"x"), "depends": []},
  "untouched": {"file_name": CDN + "untouched-1-py3-none-any.whl", "sha256": sha(b"u"), "depends": []},
  "offline": {"file_name": CDN + "offline-1-py3-none-any.whl", "sha256": sha(b"o"), "depends": []},
}}
asked = []
def fetch(url, limit):
    asked.append(url)
    name = url.rsplit("/", 1)[1].split("-")[0]
    if name == "offline":
        raise OSError("network unreachable\tnow\n")
    return blobs[name]
dest, tmp = tempfile.mkdtemp(), tempfile.mkdtemp()
open(os.path.join(dest, "pyodide.asm.wasm"), "wb").write(b"the runtime's own")
open(os.path.join(dest, "own-1-py3-none-any.whl"), "wb").write(b"the image's own")
new, rep = v.vendor(lock, ["a", "c", "needsbad", "odd", "own", "offline", "nope"], dest, fetch=fetch, tmp=tmp)
ready = [r["name"] for r in rep["ready"]]
why = {x["name"]: x["why"] for x in rep["left_out"]}
assert ready == ["b", "a"], ready
# a relative name only for the verified wheels (with everything they need); every other package keeps its CDN URL
assert new["packages"]["a"]["file_name"] == "a-1-py3-none-any.whl"
assert new["packages"]["b"]["file_name"] == "b-1-py3-none-any.whl"
for n in ["c", "bad", "needsbad", "odd", "own", "untouched", "offline"]:
    assert new["packages"][n]["file_name"] == lock["packages"][n]["file_name"], n
assert lock["packages"]["a"]["file_name"].startswith(CDN), "the lock read is never changed in place"
# why each was left out
assert why["bad"] == "its sha256 does not match the lock's", why
assert why["needsbad"] == "needs bad, left out", why
assert why["gone"] == "not in the image's pyodide-lock.json", why
assert why["c"] == "needs gone, left out", why
assert why["odd"] == "its file name in the lock is not a plain wheel name", why
assert why["own"] == "its file name is one of the runtime's own files", why
assert why["nope"] == "not in the image's pyodide-lock.json", why
assert why["offline"].startswith("download failed (OSError: network unreachable now "), why
assert "\t" not in why["offline"] and "\n" not in why["offline"]
# only the ready wheels are in the folder (the runtime's own file untouched); nothing else was downloaded for them
assert sorted(os.listdir(dest)) == ["a-1-py3-none-any.whl", "b-1-py3-none-any.whl", "own-1-py3-none-any.whl", "pyodide.asm.wasm"], os.listdir(dest)
assert open(os.path.join(dest, "pyodide.asm.wasm"), "rb").read() == b"the runtime's own"
assert open(os.path.join(dest, "own-1-py3-none-any.whl"), "rb").read() == b"the image's own"
assert not any("odd" in u or "own-1" in u or "untouched" in u for u in asked), asked
assert rep["bytes"] == len(blobs["a"]) + len(blobs["b"])
# the status lines: ready / left, tab-separated, printable
lines = v.summary(rep).splitlines()
assert lines[0] == "ready\tb\t7" and lines[1] == "ready\ta\t7", lines
assert "left\tbad\tits sha256 does not match the lock's" in lines
PY
}

test_vendor_main_writes_only_its_files_and_keeps_going_offline() {
  _vendor_py <<'PY' || return $?
import hashlib, json, os, tempfile, urllib.error
sha = lambda b: hashlib.sha256(b).hexdigest()
dest = tempfile.mkdtemp()
lock = {"info": {"python": "3.14"}, "packages": {
  "micropip": {"file_name": "https://cdn.example/full/micropip-0.1-py3-none-any.whl", "sha256": sha(b"m"), "depends": []},
  "numpy": {"file_name": "https://cdn.example/full/numpy-2-cp314-wasm32.whl", "sha256": sha(b"n"), "depends": []}}}
json.dump(lock, open(os.path.join(dest, "pyodide-lock.json"), "w"))
lst = os.path.join(tempfile.mkdtemp(), "packages.txt")
open(lst, "w").write("# a comment\nmicropip\n\nNumPy  # case and comments\nmicropip\n")
assert v.wanted(open(lst).read()) == ["micropip", "numpy"]
# offline: every download fails — the image still works without them, and says so
def offline(url, limit):
    raise urllib.error.URLError("no network")
v.fetch_url = offline
assert v.main(["vendor.py", dest, lst]) == 0
assert json.load(open(os.path.join(dest, "pyodide-lock.json"))) == lock, "nothing vendored: the lock as it was"
assert sorted(os.listdir(dest)) == ["pyodide-lock.json", "vendored.json", "vendored.txt"], os.listdir(dest)
rep = json.load(open(os.path.join(dest, "vendored.json")))
assert rep["ready"] == [] and [x["name"] for x in rep["left_out"]] == ["micropip", "numpy"], rep
assert all(x["why"].startswith("download failed") for x in rep["left_out"])
# online (one verified, one not): the lock names the verified one by its bare name
v.fetch_url = lambda url, limit: b"m" if "micropip" in url else b"tampered"
assert v.main(["vendor.py", dest, lst]) == 0
new = json.load(open(os.path.join(dest, "pyodide-lock.json")))
assert new["packages"]["micropip"]["file_name"] == "micropip-0.1-py3-none-any.whl"
assert new["packages"]["numpy"]["file_name"] == lock["packages"]["numpy"]["file_name"]
assert open(os.path.join(dest, "vendored.txt")).read() == "ready\tmicropip\t1\nleft\tnumpy\tits sha256 does not match the lock's\n"
assert not [f for f in os.listdir(dest) if f.endswith(".bn-new")]
# a lock that cannot be read: nothing vendored, said, and no failure
os.remove(os.path.join(dest, "pyodide-lock.json"))
assert v.main(["vendor.py", dest, lst]) == 0
assert "pyodide-lock.json" not in os.listdir(dest)
assert all(x["why"] == "the image's pyodide-lock.json has no packages" for x in json.load(open(os.path.join(dest, "vendored.json")))["left_out"])
PY
}

test_vendor_downloads_are_bounded_https_only() {
  _vendor_py <<'PY' || return $?
import hashlib, io, tempfile, urllib.request
for url in ["http://cdn.example/a.whl", "file:///etc/passwd", "ftp://x/a.whl", "data:,x"]:
    try:
        v.fetch_url(url, 10)
        raise AssertionError("fetched " + url)
    except ValueError as e:
        assert "https" in str(e), e
class Body(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
seen = {}
def opener(url, timeout):
    seen["timeout"] = timeout
    return Body(b"x" * 1000)
urllib.request.urlopen = opener
assert v.fetch_url("https://cdn.example/a.whl", 1000) == b"x" * 1000
assert seen["timeout"] == v.DOWNLOAD_TIMEOUT_S
try:
    v.fetch_url("https://cdn.example/a.whl", 999)
    raise AssertionError("past the cap")
except ValueError as e:
    assert "larger than" in str(e)
# the caps: each wheel, and all of them
assert v.FILE_MAX <= 64 << 20 and v.TOTAL_MAX <= 128 << 20
got = []
lock = {"packages": {n: {"file_name": f"https://c/{n}-1-py3-none-any.whl", "sha256": hashlib.sha256(b"z").hexdigest(), "depends": []} for n in "pq"}}
v.vendor(lock, ["p", "q"], tempfile.mkdtemp(), fetch=lambda url, limit: got.append(limit) or b"z", tmp=tempfile.mkdtemp())
assert got == [v.FILE_MAX, min(v.FILE_MAX, v.TOTAL_MAX - 1)], got
PY
}

test_open_webui_one_pin_everywhere_and_a_local_image_no_pull_replaces() {
  local pin dflt tag svc
  # compose.yaml's build argument, the Dockerfile's default, the e2e's tested version: one pin, a tag and a digest
  svc="$(awk '/^  open-webui:$/ { f = 1; next } f && /^  [a-z]/ { f = 0 } f' "$STACK_DIR/compose.yaml")"
  pin="$(printf '%s\n' "$svc" | sed -n 's/^ *image: \(ghcr\.io\/open-webui\/open-webui:[^ ]*\)$/\1/p')"
  printf '%s\n' "$pin" | grep -qE '^ghcr\.io/open-webui/open-webui:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' || { echo "pin: $pin" >&2; return 1; }
  dflt="$(sed -n 's/^ARG image=\(.*\)$/\1/p' "$OWUI/Dockerfile")"
  assert_eq "$dflt" "$pin"
  assert_contains "$(cat "$OWUI/Dockerfile")" 'FROM ${image}'
  tag="${pin#ghcr.io/open-webui/open-webui:}"; tag="${tag%@*}"
  assert_contains "$(cat "$STACK_DIR/tests/e2e/browser/common.py")" "\"open-webui\": \"$tag\""
  # (the e2e reads it from compose.yaml as before: its tag)
  assert_eq "$(sed -n "s|^[[:space:]]*image:[[:space:]]*[^[:space:]]*open-webui/open-webui:\\([^@[:space:]]*\\).*|\\1|p" "$STACK_DIR/compose.yaml" | head -n 1)" "$tag"
  # a local image of this project, built here, never pulled
  assert_contains "$svc" 'image: ${COMPOSE_PROJECT_NAME:-bedrock-now}/open-webui:local'
  assert_contains "$svc" 'pull_policy: never'
  assert_contains "$svc" 'context: ./open-webui'
  # no other reference to Open WebUI's registry image anywhere in compose files
  assert_eq "$(grep -h 'open-webui/open-webui' "$STACK_DIR"/compose*.yaml | wc -l | tr -d ' ')" 1
  # what the build runs: vendor.py, isolated, on Pyodide's folder; nothing else copied in
  assert_contains "$(cat "$OWUI/Dockerfile")" 'python3 -I /tmp/bn-vendor/vendor.py /app/build/pyodide /tmp/bn-vendor/packages.txt'
  assert_eq "$(grep -c '^COPY' "$OWUI/Dockerfile" | tr -d ' ')" 1
  assert_contains "$(cat "$OWUI/Dockerfile")" 'COPY vendor.py packages.txt /tmp/bn-vendor/'
  # the default packages
  assert_eq "$(grep -v '^#' "$OWUI/packages.txt" | grep . | tr '\n' ' ')" "micropip numpy pandas matplotlib "
}

test_owui_build_tries_again_only_after_a_failed_download_and_keeps_its_try() {
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR/status"
  building() { shift; "$@"; }
  dc() { echo "dc $*" >> "$TMP/dc"; }
  python_runner_status() { :; }
  date() { echo 2026102509; }
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=0 open-webui"
  : > "$TMP/dc"
  printf 'ready\tmicropip\t1\nleft\tnumpy\tdownload failed (URLError: no network)\n' > "$STATE_DIR/status/python-runner.txt"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  # (all there now: the same try value from then on — Docker's cache holds that build, never the one before)
  printf 'ready\tmicropip\t1\nready\tnumpy\t2\n' > "$STATE_DIR/status/python-runner.txt"
  : > "$TMP/dc"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  # a package the lock does not have is no reason to build again
  printf 'ready\tmicropip\t1\nleft\tnope\tnot in the image'"'"'s pyodide-lock.json\n' > "$STATE_DIR/status/python-runner.txt"
  : > "$TMP/dc"
  owui_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q --build-arg BN_VENDOR_TRY=2026102509 open-webui"
  dc() { return 1; }
  if owui_build; then echo "a failed build must fail" >&2; return 1; fi
}

test_python_runner_line_says_what_is_ready_and_what_is_left_out() {
  STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR/status"
  assert_eq "$(python_runner_line)" ""
  printf 'ready\tmicropip\t120000\nready\tnumpy\t2900000\n' > "$STATE_DIR/status/python-runner.txt"
  assert_eq "$(python_runner_line)" "Python runner (Chat): 2 packages ready"
  printf 'ready\tmicropip\t1\nleft\tnumpy\tdownload failed (URLError: no network)\nleft\tpandas\tneeds numpy, left out\n' > "$STATE_DIR/status/python-runner.txt"
  assert_eq "$(python_runner_line)" "Python runner (Chat): 1 package ready; left out: numpy (download failed (URLError: no network)), pandas (needs numpy, left out)"
}
