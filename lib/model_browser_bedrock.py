"""Which Bedrock models this stack's AWS key could add, for the model browser (lib/model_browser.sh: model_browser_bedrock).

Runs in a one-off container of LiteLLM's image (python, boto3, LiteLLM's own price map), with the AWS sign-in LiteLLM
itself uses (.env's key, or the EC2 instance role): no AWS key ever reaches the portal. Read-only, free calls only, in
REGION: ListFoundationModels (the text models) and ListInferenceProfiles (the system-defined cross-region profiles a
model without on-demand use is called through). Prices, context, tool use and image input come from LiteLLM's own price
map (the copy in its image: LITELLM_LOCAL_MODEL_COST_MAP), where it knows the model; nothing is fetched from elsewhere.

Usage: python3 -I -c "$(cat model_browser_bedrock.py)" REGION
Prints one JSON object: {"provider": "bedrock", "region", "status": ok | denied | error, "why", "profiles": ok | denied |
error, "models": [{id, model_id, name, vendor, inputs, lifecycle, how: on-demand | profile, prices {in, out, cache_read,
cache_write} USD per million tokens or null, context, max_out, tools, images}]}. id: what LiteLLM is given (the model's
own id, or its inference profile's); never an ARN (an inference profile's names the AWS account). Every string checked
here: no line break, no quote, a bounded length.
"""

import json
import re
import sys

ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
REGION = re.compile(r"[a-z]{2}(-[a-z]+)+-[0-9]")
MAX_MODELS = 600


def text(v, n=80):
    return re.sub(r"[^ -~]", " ", v if isinstance(v, str) else "").replace('"', "'").replace("\\", "/").strip()[:n]


def say(obj):
    print(json.dumps(obj, separators=(",", ":")))


def why_of(e):
    """A ClientError in words, with the permission it needs (no ARN, no account: the code and the operation only)."""
    code = getattr(e, "response", {}).get("Error", {}).get("Code", "") if hasattr(e, "response") else ""
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


def main():
    region = sys.argv[1] if len(sys.argv) > 1 else ""
    out = {"provider": "bedrock", "region": region if REGION.fullmatch(region or "") else "", "status": "error", "why": "",
           "profiles": "ok", "models": []}
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
    # model id -> the system-defined profiles that serve it (us.…, eu.…, global.…)
    serves = {}
    try:
        token = None
        for _ in range(10):
            kw = {"typeEquals": "SYSTEM_DEFINED", "maxResults": 1000, **({"nextToken": token} if token else {})}
            page = bedrock.list_inference_profiles(**kw)
            for p in page.get("inferenceProfileSummaries") or []:
                pid = p.get("inferenceProfileId")
                if p.get("status") != "ACTIVE" or not isinstance(pid, str) or not ID.fullmatch(pid):
                    continue
                for m in p.get("models") or []:
                    arn = m.get("modelArn") if isinstance(m, dict) else None
                    mid = arn.rsplit("/", 1)[-1] if isinstance(arn, str) and "foundation-model/" in arn else None
                    if mid and ID.fullmatch(mid):
                        serves.setdefault(mid, []).append(pid)
            token = page.get("nextToken")
            if not token:
                break
    except ClientError as e:
        out["profiles"] = why_of(e)[0]
    except BotoCoreError:
        out["profiles"] = "error"
    geo = region.split("-", 1)[0]   # us-east-1 -> us; eu-west-1 -> eu; ap-… -> apac's profiles
    prefer = (("apac." if geo == "ap" else f"{geo}."), "global.")
    costs = price_map()
    seen = set()
    for m in fms:
        if not isinstance(m, dict):
            continue
        mid = m.get("modelId")
        outs = [x.lower() for x in m.get("outputModalities") or [] if isinstance(x, str)]
        ins = [x.lower() for x in m.get("inputModalities") or [] if isinstance(x, str)]
        kinds = m.get("inferenceTypesSupported") or []
        if not isinstance(mid, str) or not ID.fullmatch(mid) or outs != ["text"] or "text" not in ins:
            continue
        if re.search(r"embed|rerank", mid) or (mid.count(":") > 1):   # (embeddings; a context-length variant "…:0:200k")
            continue
        lifecycle = text((m.get("modelLifecycle") or {}).get("status"), 20) or "ACTIVE"
        if "ON_DEMAND" in kinds:
            ident, how = mid, "on-demand"
        else:
            profs = sorted(serves.get(mid) or [], key=lambda p: next((i for i, x in enumerate(prefer) if p.startswith(x)), len(prefer)))
            if not profs and out["profiles"] != "ok" and "INFERENCE_PROFILE" in kinds:
                # the key may not list the profiles (Claude is served only through them): the system-defined one's
                # usual id for the region's geography, us.<model id>, as the catalog calls it; the page says so
                profs = [prefer[0] + mid]
            if not profs:
                continue   # (provisioned throughput only: nothing this stack can call)
            ident, how = profs[0], "profile"
        if ident in seen:
            continue
        seen.add(ident)
        c = lookup(costs, (ident, mid))
        pin, pout = num(c.get("input_cost_per_token")), num(c.get("output_cost_per_token"))
        out["models"].append({
            "id": ident, "model_id": mid, "name": text(m.get("modelName")) or mid, "vendor": text(m.get("providerName"), 40),
            "inputs": [x for x in ins if x in ("text", "image", "document", "video", "audio")], "lifecycle": lifecycle, "how": how,
            "prices": {"in": per_million(pin), "out": per_million(pout), "cache_read": per_million(num(c.get("cache_read_input_token_cost"))),
                       "cache_write": per_million(num(c.get("cache_creation_input_token_cost")))} if pin is not None and pout is not None else None,
            "context": whole(c.get("max_input_tokens")), "max_out": whole(c.get("max_output_tokens")),
            "tools": c.get("supports_function_calling") if isinstance(c.get("supports_function_calling"), bool) else None,
            "images": ("image" in ins) if ins else (c.get("supports_vision") if isinstance(c.get("supports_vision"), bool) else None),
        })
        if len(out["models"]) >= MAX_MODELS:
            break
    out["status"] = "ok"
    say(out)


main()
