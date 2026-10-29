"""Which Bedrock models this stack's AWS key could add, for the model browser (lib/model_browser.sh: model_browser_bedrock).

Runs in a one-off container of LiteLLM's image (python, boto3, LiteLLM's own price map), with the AWS sign-in LiteLLM
itself uses (.env's key, or the EC2 instance role): no AWS key ever reaches the portal. Read-only, free calls only:
- in REGION: ListFoundationModels (the text models), ListInferenceProfiles (the system-defined cross-region profiles a
  model without on-demand use is called through, and your own application inference profiles), and, when the key may
  not list profiles, GetInferenceProfile on each profile id it would otherwise guess (confirmed, or dropped when AWS has
  no such profile);
- in every other region botocore knows Bedrock in (in parallel, one try each, OTHER_BUDGET_S in all): the same lists,
  for the models REGION does not offer. Those are listed as "<region>/<id>" and called in their region. A region the
  account has not turned on is said ("off"); one that has not answered within the budget, "error" (some never answer
  from some networks: their name does not resolve, and no timeout of botocore's covers that).
Prices, context, tool use and image input come from LiteLLM's own price map (the copy in its image:
LITELLM_LOCAL_MODEL_COST_MAP), where it knows the model; nothing is fetched from elsewhere.

What is left out, and counted per reason in "left_out" (REGION's models only; the e2e check model-browser-complete holds
the page to exactly these): "not-text" (no text in, or not text-only out: image, video, speech), "embeddings" (embedding
and rerank models), "variant" (a context-length variant "…:0:200k" of a listed model), "provisioned" (provisioned
throughput only: nothing this stack can call on demand), "cap" (beyond MAX_MODELS).

Usage: python3 -I -c "$(cat model_browser_bedrock.py)" REGION
Prints one JSON object: {"provider": "bedrock", "region", "status": ok | denied | error, "why", "profiles": ok | denied |
error, "apps": ok | denied | error, "regions": {region: ok | off | denied | error}, "left_out": {reason: n}, "models":
[{id, model_id, name, vendor, inputs, lifecycle, how: on-demand | profile, region, kind: foundation | app-profile, guessed,
prices {in, out, cache_read, cache_write} USD per million tokens or null, context, max_out, tools, images}]}. id: what
the setting and LiteLLM's model name hold — the model's own id or its inference profile's; "<region>/<that>" for another
region's; "app/<profile id>" for your application inference profile. Never an ARN on that line (an ARN names the AWS
account): an application profile's ARN is printed on a line of its own after it, "ARN<tab>app/<id><tab><arn><tab><base
model id><tab><name>", which lib/model_browser.sh keeps where the portal cannot read it. Every string checked here: no
line break, no quote, no tab, a bounded length.
"""

import json
import os
import re
import sys

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
APP_ID = re.compile(r"[a-z0-9]{1,64}")
APP_ARN = re.compile(r"arn:aws[a-z-]*:bedrock:[a-z0-9-]+:[0-9]{12}:application-inference-profile/[a-z0-9]{1,64}")
REGION = re.compile(r"[a-z]{2}(-[a-z]+)+-[0-9]")
MAX_MODELS = 600
WORKERS = 16
OTHER_BUDGET_S = 45


def text(v, n=80):
    return re.sub(r"[^ -~]", " ", v if isinstance(v, str) else "").replace('"', "'").replace("\\", "/").strip()[:n]


def say(obj):
    print(json.dumps(obj, separators=(",", ":")))


def code_of(e):
    return (getattr(e, "response", None) or {}).get("Error", {}).get("Code", "")


def why_of(e):
    """A ClientError in words, with the permission it needs (no ARN, no account: the code and the operation only)."""
    code = code_of(e)
    op = getattr(e, "operation_name", "") or ""
    if code in ("AccessDeniedException", "UnauthorizedOperation", "AccessDenied"):
        return "denied", f"the AWS key may not call bedrock:{op or 'ListFoundationModels'} (ask your AWS admin to allow it; it is read-only and free)"
    if code in ("UnrecognizedClientException", "InvalidSignatureException", "ExpiredTokenException"):
        return "error", f"AWS did not accept the key ({text(code, 40)})"
    return "error", f"Bedrock answered {text(code, 60) or type(e).__name__} to {text(op, 40) or 'the listing'}"


def price_map():
    """LiteLLM's own price map (the copy in its image), or {}: a model it does not know has no price here."""
    try:
        import litellm  # noqa: PLC0415 — slow to import; only here
        return litellm.model_cost if isinstance(litellm.model_cost, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def lookup(costs, ids):
    for k in ids:
        for key in (k, f"bedrock/{k}", f"bedrock/converse/{k}"):
            v = costs.get(key)
            if isinstance(v, dict):
                return v
    return {}


def num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v < 1 else None


def whole(v):
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 < v < 100_000_000 else None


def per_million(v):
    return round(v * 1_000_000, 6) if v is not None else None


def model_of(arn):
    """A foundation model's id from its ARN (…:foundation-model/<id>), else None."""
    mid = arn.rsplit("/", 1)[-1] if isinstance(arn, str) and "foundation-model/" in arn else None
    return mid if mid and ID.fullmatch(mid) else None


def profiles(bedrock, kind, errors):
    """(ok | denied | error, the ACTIVE profiles of KIND: SYSTEM_DEFINED or APPLICATION), up to 10 pages."""
    ClientError, BotoCoreError = errors
    out, token = [], None
    try:
        for _ in range(10):
            page = bedrock.list_inference_profiles(typeEquals=kind, maxResults=1000, **({"nextToken": token} if token else {}))
            out += [p for p in page.get("inferenceProfileSummaries") or [] if isinstance(p, dict) and p.get("status") == "ACTIVE"]
            token = page.get("nextToken")
            if not token:
                break
    except ClientError as e:
        return why_of(e)[0], out
    except BotoCoreError:
        return "error", out
    return "ok", out


def serves_of(summaries):
    """model id -> the system-defined profiles that serve it (us.…, eu.…, global.…)"""
    serves = {}
    for p in summaries:
        pid = p.get("inferenceProfileId")
        if not isinstance(pid, str) or not ID.fullmatch(pid):
            continue
        for m in p.get("models") or []:
            mid = model_of(m.get("modelArn") if isinstance(m, dict) else None)
            if mid:
                serves.setdefault(mid, []).append(pid)
    return serves


def prefer_of(region):
    geo = region.split("-", 1)[0]   # us-east-1 -> us; eu-west-1 -> eu; ap-… -> apac's profiles
    return (("apac." if geo == "ap" else f"{geo}."), "global.")


class Confirm:
    """GetInferenceProfile on a profile id the key could not list (free): True (it exists), False (AWS has no such
    profile) or None (the key may not ask either: it stays a guess). The first refusal stops the asking."""

    def __init__(self, bedrock, errors):
        self.bedrock, self.errors, self.denied = bedrock, errors, False

    def __call__(self, pid):
        if self.denied:
            return None
        ClientError, BotoCoreError = self.errors
        try:
            p = self.bedrock.get_inference_profile(inferenceProfileIdentifier=pid)
            return p.get("status", "ACTIVE") == "ACTIVE" if isinstance(p, dict) else None
        except ClientError as e:
            if code_of(e) in ("ResourceNotFoundException", "ValidationException"):
                return False
            self.denied = True
            return None
        except BotoCoreError:
            return None


def candidates(fms, left_out=None):
    """The text models of a ListFoundationModels answer: (model summary, id, inputs, kinds); LEFT_OUT counts the rest."""
    def leave(reason):
        if left_out is not None:
            left_out[reason] = left_out.get(reason, 0) + 1
    for m in fms:
        if not isinstance(m, dict) or not isinstance(m.get("modelId"), str) or not ID.fullmatch(m["modelId"]):
            continue
        mid = m["modelId"]
        outs = [x.lower() for x in m.get("outputModalities") or [] if isinstance(x, str)]
        ins = [x.lower() for x in m.get("inputModalities") or [] if isinstance(x, str)]
        if outs != ["text"] or "text" not in ins:
            leave("not-text")
        elif re.search(r"embed|rerank", mid):
            leave("embeddings")
        elif mid.count(":") > 1:   # (a context-length variant "…:0:200k")
            leave("variant")
        else:
            yield m, mid, ins, m.get("inferenceTypesSupported") or []


def row(m, mid, ins, ident, how, region, guessed, costs, kind="foundation", name=None):
    c = lookup(costs, (ident, mid))
    pin, pout = num(c.get("input_cost_per_token")), num(c.get("output_cost_per_token"))
    return {
        "id": ident, "model_id": mid, "name": name or text(m.get("modelName")) or mid, "vendor": text(m.get("providerName"), 40),
        "inputs": [x for x in ins if x in ("text", "image", "document", "video", "audio")],
        "lifecycle": text((m.get("modelLifecycle") or {}).get("status"), 20) or "ACTIVE", "how": how, "region": region,
        "kind": kind, "guessed": bool(guessed),
        "prices": {"in": per_million(pin), "out": per_million(pout), "cache_read": per_million(num(c.get("cache_read_input_token_cost"))),
                   "cache_write": per_million(num(c.get("cache_creation_input_token_cost")))} if pin is not None and pout is not None else None,
        "context": whole(c.get("max_input_tokens")), "max_out": whole(c.get("max_output_tokens")),
        "tools": c.get("supports_function_calling") if isinstance(c.get("supports_function_calling"), bool) else None,
        "images": ("image" in ins) if ins else (c.get("supports_vision") if isinstance(c.get("supports_vision"), bool) else None),
    }


def rows_of(region, fms, serves, listed, confirm, costs, skip=(), left_out=None):
    """REGION's callable text models, each once: on demand by its own id, else through a system-defined profile (the
    region's geography first, then global). Without the profiles listed (LISTED not ok), the usual id is guessed and
    asked about (CONFIRM). SKIP: model ids not wanted here (the stack's own region offers them)."""
    prefer = prefer_of(region)
    out, seen = [], set()
    for m, mid, ins, kinds in candidates(fms, left_out):
        if mid in skip:
            continue
        guessed = False
        if "ON_DEMAND" in kinds:
            ident, how = mid, "on-demand"
        else:
            profs = sorted(serves.get(mid) or [], key=lambda p: next((i for i, x in enumerate(prefer) if p.startswith(x)), len(prefer)))
            if not profs and listed != "ok" and "INFERENCE_PROFILE" in kinds:
                # the key may not list the profiles (Claude is served only through them): the system-defined one's usual
                # id for the region's geography (us.<model id>, as the catalog calls it), else global.<model id> —
                # confirmed when the key may ask (GetInferenceProfile), else shown as a guess
                for guess in (p + mid for p in prefer):
                    ok = confirm(guess)
                    if ok is False:
                        continue
                    profs, guessed = [guess], ok is None
                    break
            if not profs:
                if left_out is not None:
                    left_out["provisioned"] = left_out.get("provisioned", 0) + 1
                continue   # (provisioned throughput only, or no profile: nothing this stack can call)
            ident, how = profs[0], "profile"
        if ident in seen:
            continue
        seen.add(ident)
        out.append(row(m, mid, ins, ident, how, region, guessed, costs))
    return out


def app_rows(apps, fms, costs, private):
    """Your application inference profiles in the region: "app/<profile id>", named as you named them, priced as the
    model they copy; each one's ARN goes to PRIVATE, never to the list."""
    by_id = {m.get("modelId"): m for m in fms if isinstance(m, dict)}
    out = []
    for p in apps:
        pid, arn = p.get("inferenceProfileId"), p.get("inferenceProfileArn")
        if not isinstance(pid, str) or not APP_ID.fullmatch(pid) or not isinstance(arn, str) or not APP_ARN.fullmatch(arn):
            continue
        base = next((x for x in (model_of(m.get("modelArn")) for m in p.get("models") or [] if isinstance(m, dict)) if x), None)
        if not base:
            continue
        m = by_id.get(base) or {"modelId": base}
        ins = [x.lower() for x in m.get("inputModalities") or ["TEXT"] if isinstance(x, str)]
        name = text(p.get("inferenceProfileName"), 60) or pid
        out.append(row(m, base, ins, f"app/{pid}", "profile", arn.split(":")[3], False, costs, kind="app-profile", name=name))
        private.append(("ARN", f"app/{pid}", arn, base, name))
    return out


def other_regions(boto3, here):
    """The regions botocore knows Bedrock in, other than HERE: the same geography first, then the rest."""
    try:
        names = boto3.Session().get_available_regions("bedrock")
    except Exception:  # noqa: BLE001
        return []
    geo = here.split("-", 1)[0]
    names = sorted({r for r in names if isinstance(r, str) and REGION.fullmatch(r) and r != here})
    return sorted(names, key=lambda r: (r.split("-", 1)[0] != geo, r))


def read_other(boto3, cfg, errors, region, skip, costs):   # cfg: one try, short timeouts (OTHER_BUDGET_S bounds them all)
    """(status, rows) of one other region: its text models the stack's region does not offer (SKIP)."""
    ClientError, BotoCoreError = errors
    try:
        bedrock = boto3.client("bedrock", region_name=region, config=cfg)
        fms = bedrock.list_foundation_models(byOutputModality="TEXT").get("modelSummaries") or []
    except ClientError as e:
        if code_of(e) in ("UnrecognizedClientException", "InvalidSignatureException", "AuthFailure", "OptInRequired"):
            return "off", []   # (a region the account has not turned on)
        return why_of(e)[0], []
    except BotoCoreError:
        return "error", []
    if not any(mid not in skip for _, mid, _, _ in candidates(fms)):
        return "ok", []
    listed, sys_profiles = profiles(bedrock, "SYSTEM_DEFINED", errors)
    return "ok", rows_of(region, fms, serves_of(sys_profiles), listed, Confirm(bedrock, errors), costs, skip=skip)


def main():
    region = sys.argv[1] if len(sys.argv) > 1 else ""
    out = {"provider": "bedrock", "region": region if REGION.fullmatch(region or "") else "", "status": "error", "why": "",
           "profiles": "ok", "apps": "ok", "regions": {}, "left_out": {}, "models": []}
    if not out["region"]:
        out["why"] = "no AWS region"
        return say(out)
    try:
        import boto3  # noqa: PLC0415
        from botocore.config import Config  # noqa: PLC0415
        from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        out["why"] = "LiteLLM's image has no boto3"
        return say(out)
    errors = (ClientError, BotoCoreError)
    cfg = Config(connect_timeout=10, read_timeout=20, retries={"max_attempts": 2})
    try:
        bedrock = boto3.client("bedrock", region_name=region, config=cfg)
        fms = bedrock.list_foundation_models(byOutputModality="TEXT").get("modelSummaries") or []
    except NoCredentialsError:
        out["why"] = "no AWS sign-in in LiteLLM's environment"
        return say(out)
    except ClientError as e:
        out["status"], out["why"] = why_of(e)
        return say(out)
    except BotoCoreError as e:
        out["why"] = f"could not reach Bedrock in {region} ({type(e).__name__})"
        return say(out)
    costs = price_map()
    out["profiles"], sys_profiles = profiles(bedrock, "SYSTEM_DEFINED", errors)
    models = rows_of(region, fms, serves_of(sys_profiles), out["profiles"], Confirm(bedrock, errors), costs, left_out=out["left_out"])
    private = []
    out["apps"], apps = profiles(bedrock, "APPLICATION", errors)
    models += app_rows(apps, fms, costs, private)
    out["regions"][region] = "ok"
    # every other region, for the models this one does not offer (each model once: the nearest region that has it)
    here = {r["model_id"] for r in models}
    regions = other_regions(boto3, region)
    found = {}
    if regions:
        from concurrent.futures import ThreadPoolExecutor, wait  # noqa: PLC0415
        pool = ThreadPoolExecutor(max_workers=WORKERS)
        quick = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1})
        futs = {r: pool.submit(read_other, boto3, quick, errors, r, here, costs) for r in regions}
        wait(list(futs.values()), timeout=OTHER_BUDGET_S)
        for r, f in futs.items():
            if f.done() and not f.exception():
                out["regions"][r], found[r] = f.result()
            else:
                out["regions"][r] = "error"
        pool.shutdown(wait=False, cancel_futures=True)
    taken = set(here)
    for r in regions:
        for m in found.get(r) or []:
            if m["model_id"] in taken:
                continue
            taken.add(m["model_id"])
            m["id"] = f"{r}/{m['id']}"
            models.append(m)
    if len(models) > MAX_MODELS:
        out["left_out"]["cap"] = len(models) - MAX_MODELS
        models = models[:MAX_MODELS]
    out["models"] = models
    out["status"] = "ok"
    say(out)
    for line in private:
        print("\t".join(line))


main()
sys.stdout.flush()
# (a region still answering past the budget holds a thread: nothing more to wait for)
os._exit(0)
