"""Can this stack's AWS key search with Amazon Bedrock AgentCore Web Search? (lib/websearch.sh:
websearch_agentcore_check)

Runs in a one-off container of LiteLLM's image (python, botocore), with the AWS sign-in LiteLLM itself uses (.env's
key, or the EC2 instance role). Free calls only, no search: STS GetCallerIdentity (who this key is, for the IAM
command it may need), AgentCore's ListGateways when no gateway is given (one with a web search target is looked for in
REGION), and the gateway's MCP tools/list (signed for bedrock-agentcore: answers only a key with
bedrock-agentcore:InvokeGateway, and lists the web search target's tool). ./stack then makes the one real search, through
LiteLLM.

Usage: python3 -I -c "$(cat websearch_probe.py)" REGION [GATEWAY_URL]
Prints KEY=VALUE lines (values checked here: no line break, no quote): status (ready | denied | no-gateway | no-target
| unverified), url, tool, account, principal (user/NAME or role/NAME), region, why. Never a credential.
"""

import json
import re
import sys
import urllib.error
import urllib.request

GATEWAY_URL = re.compile(r"https://([a-z0-9-]{1,100})\.gateway\.bedrock-agentcore\.([a-z0-9-]{1,30})\.amazonaws\.com/mcp")
TOOL = re.compile(r"[A-Za-z0-9_-]{1,100}___WebSearch")
# the MCP revision LiteLLM 1.105.0 speaks to a gateway (litellm/llms/bedrock/search/transformation.py): one whose
# supportedVersions are unset takes this one only
MCP_VERSION = "2025-03-26"
TIMEOUT = 20


def say(**kv):
    for k, v in kv.items():
        v = "" if v is None else str(v)
        v = re.sub(r"[^ -~]", " ", v).replace('"', "'").replace("\\", "/")[:300]
        print(f"{k}={v}")


def _signed(creds, method, url, region, service, body=None):
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest

    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if service == "bedrock-agentcore":
        headers["MCP-Protocol-Version"] = MCP_VERSION
    req = AWSRequest(method=method, url=url, data=body, headers=headers)
    SigV4Auth(creds, service, region).add_auth(req)
    r = urllib.request.Request(url, data=body.encode() if body else None, headers=dict(req.headers), method=method)
    try:
        with urllib.request.urlopen(r, timeout=TIMEOUT) as resp:
            return resp.status, resp.read(1_000_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(100_000).decode("utf-8", "replace")


def _mcp_json(text):
    """A JSON-RPC answer, sent as JSON or as Streamable HTTP's server-sent events (the last data: line that parses)."""
    try:
        return json.loads(text)
    except ValueError:
        pass
    found = None
    for line in text.splitlines():
        if line.startswith("data:"):
            try:
                found = json.loads(line[5:].strip())
            except ValueError:
                continue
    return found


def web_search_tool(creds, url):
    """(status, tool, why) from the gateway's tools/list: ready with the web search target's tool, denied (403: no
    bedrock-agentcore:InvokeGateway for this key), no-gateway (404, MCP error -32004: "Requested gateway does not exist",
    as AWS answers before it checks the permission), no-target, or unverified."""
    region = GATEWAY_URL.fullmatch(url).group(2)
    cursor = None
    for _ in range(5):
        params = {"cursor": cursor} if cursor else {}
        code, text = _signed(creds, "POST", url, region, "bedrock-agentcore",
                             json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": params}))
        if code == 403:
            return "denied", "", "bedrock-agentcore:InvokeGateway"
        doc = _mcp_json(text)
        err = doc.get("error") if isinstance(doc, dict) else None
        if code == 404 or (isinstance(err, dict) and err.get("code") == -32004):
            return "no-gateway", "", "not found"
        if code != 200:
            return "unverified", "", f"the gateway answered HTTP {code}: {text[:160]}"
        if not isinstance(doc, dict) or not isinstance(doc.get("result"), dict):
            return "unverified", "", f"the gateway's tools/list: {json.dumps(err)[:160] if err else text[:160]}"
        for t in doc["result"].get("tools") or []:
            name = t.get("name") if isinstance(t, dict) else None
            if isinstance(name, str) and TOOL.fullmatch(name):
                return "ready", name, ""
        cursor = doc["result"].get("nextCursor")
        if not cursor:
            break
    return "no-target", "", "the gateway has no web search target (connector web-search)"


def _config():
    from botocore.config import Config

    return Config(connect_timeout=TIMEOUT, read_timeout=TIMEOUT, retries={"max_attempts": 2})


def gateways(session, creds, region):
    """[(gateway id, url)] of the READY, AWS_IAM, MCP gateways in REGION, or None when this key may not list them."""
    from botocore.exceptions import ClientError, UnknownServiceError

    items = []
    try:
        client = session.client("bedrock-agentcore-control", region_name=region, config=_config())
        token = None
        for _ in range(10):
            page = client.list_gateways(maxResults=100, **({"nextToken": token} if token else {}))
            items += page.get("items") or []
            token = page.get("nextToken")
            if not token:
                break
    except UnknownServiceError:   # (a botocore without AgentCore's model: its REST call, signed the same way)
        code, text = _signed(creds, "GET", f"https://bedrock-agentcore-control.{region}.amazonaws.com/gateways/?maxResults=100",
                             region, "bedrock-agentcore")
        if code in (401, 403):
            return None
        items = (json.loads(text).get("items") or []) if code == 200 else []
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") in ("AccessDeniedException", "UnauthorizedException", "AccessDenied"):
            return None
        raise
    out = []
    for g in items:
        gid = g.get("gatewayId") if isinstance(g, dict) else None
        if (isinstance(gid, str) and re.fullmatch(r"[a-z0-9-]{1,100}", gid) and g.get("status") == "READY"
                and g.get("authorizerType") in (None, "AWS_IAM") and g.get("protocolType") in (None, "MCP")):
            out.append((gid, f"https://{gid}.gateway.bedrock-agentcore.{region}.amazonaws.com/mcp"))
    return out


def main():
    region = sys.argv[1] if len(sys.argv) > 1 and re.fullmatch(r"[a-z0-9-]{1,30}", sys.argv[1]) else "us-east-1"
    url = sys.argv[2] if len(sys.argv) > 2 else ""
    if url and not GATEWAY_URL.fullmatch(url):
        return say(status="no-gateway", region=region, why="WEBSEARCH_AGENTCORE_GATEWAY is not a gateway's MCP URL")
    try:
        import boto3

        session = boto3.Session()
        creds = session.get_credentials()
        if creds is None:
            return say(status="unverified", region=region, why="no AWS credentials")
        creds = creds.get_frozen_credentials()
        who = session.client("sts", region_name=region, config=_config()).get_caller_identity()
        account = who.get("Account", "")
        m = re.fullmatch(r"arn:aws[a-z-]*:(?:iam|sts)::[0-9]{12}:(user|assumed-role)/([\w+=,.@/-]+)", who.get("Arn", ""))
        principal = (f"user/{m.group(2).split('/')[-1]}" if m.group(1) == "user" else f"role/{m.group(2).split('/')[0]}") if m else ""
        if url:
            status, tool, why = web_search_tool(creds, url)
            return say(status=status, url=url, tool=tool, account=account, principal=principal,
                       region=GATEWAY_URL.fullmatch(url).group(2), why=why)
        found = gateways(session, creds, region)
        if found is None:
            return say(status="no-gateway", account=account, principal=principal, region=region,
                       why="bedrock-agentcore:ListGateways")
        last = ("no-gateway", "", "", "none in " + region)
        for _gid, gurl in found:
            status, tool, why = web_search_tool(creds, gurl)
            if status == "ready":
                return say(status=status, url=gurl, tool=tool, account=account, principal=principal, region=region)
            if last[0] == "no-gateway" or status == "denied":
                last = (status, gurl, tool, why)
        return say(status=last[0], url=last[1], tool=last[2], account=account, principal=principal, region=region, why=last[3])
    except Exception as e:  # noqa: BLE001 — any other answer: the check could not tell (never a reason to turn it off)
        return say(status="unverified", region=region, url=url, why=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
