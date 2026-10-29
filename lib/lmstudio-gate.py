"""LM Studio's gate (lib/lmstudio-agent.sh runs it): the only door to DevOS ADE's LM Studio, on 127.0.0.1:PORT.

LM Studio's own server has no key that can be set from outside its app, and it does not look at the name a request is
sent to, so a web page that points a name of its own at this computer (DNS rebinding) could use it: make it download a
model, load one, read its log. The gate lets a request through only when it is sent to this computer's own names
(127.0.0.1, localhost, or host.docker.internal: the model gateway's), carries the key made at install (etc/api-key),
and asks for the OpenAI-compatible API (/v1/...) or the list of loaded models (GET /api/v0/models); nothing else of
LM Studio's API is reachable here. One request per connection: its body is passed on by its Content-Length (no chunked
request bodies; an Expect: 100-continue is answered here), and the answer streams back as LM Studio sends it. LM Studio's server listens on a port chosen at each
start (BACKEND), on 127.0.0.1 too; the gate never logs a request.

    python3 -I lmstudio-gate.py PORT BACKEND KEYFILE
"""
import asyncio
import hmac
import re
import sys

MAX_HEAD = 64 * 1024
MAX_HEADERS = 100
MAX_BODY = 64 * 1024 * 1024
HOP = {b"connection", b"keep-alive", b"proxy-connection", b"proxy-authorization", b"upgrade", b"te", b"trailer"}
TARGET = re.compile(r"/[A-Za-z0-9._~!$&'()*+,;=:@%/?-]*")


def answer(writer, code, why):
    body = (why + "\n").encode()
    writer.write(b"HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                 % (code, {400: b"Bad Request", 401: b"Unauthorized", 403: b"Forbidden", 411: b"Length Required",
                           413: b"Payload Too Large", 417: b"Expectation Failed", 502: b"Bad Gateway"}[code], len(body)) + body)


def allowed(method, target):
    path = target.split("?", 1)[0]
    if "/../" in path + "/" or "/./" in path + "/" or "//" in path or "%" in path:
        return False
    return path.startswith("/v1/") or (method == "GET" and path == "/api/v0/models")


async def gate(reader, writer, port, backend, key):
    bw = None
    try:
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
            return
        lines = head[:-4].split(b"\r\n")
        req = lines[0].decode("latin-1").split(" ")
        if len(req) != 3 or req[2] not in ("HTTP/1.1", "HTTP/1.0") or not re.fullmatch(r"[A-Z]{3,7}", req[0]) or not TARGET.fullmatch(req[1]):
            return answer(writer, 400, "bad request")
        method, target = req[0], req[1]
        headers, host, auth, length, expect = [], None, None, None, None
        if len(lines) > MAX_HEADERS + 1:
            return answer(writer, 400, "bad request")
        for line in lines[1:]:
            name, colon, value = line.partition(b":")
            if not colon or not re.fullmatch(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or b"\n" in value or b"\r" in value or b"\0" in value:
                return answer(writer, 400, "bad request")
            n, value = name.lower(), value.strip()
            if n == b"host":
                if host is not None:
                    return answer(writer, 400, "bad request")
                host = value.decode("latin-1").lower()
            elif n == b"authorization":
                if auth is not None:
                    return answer(writer, 400, "bad request")
                auth = value
            elif n == b"transfer-encoding":
                return answer(writer, 411, "a request body needs a Content-Length")
            elif n == b"expect":
                expect = value.lower()
            elif n == b"content-length":
                if length is not None or not re.fullmatch(rb"[0-9]{1,12}", value):
                    return answer(writer, 400, "bad request")
                length = int(value)
            elif n not in HOP:
                headers.append((name, value))
        # (this computer's own names only: a page's name pointed at it is not one of them)
        if host not in ("127.0.0.1:%d" % port, "localhost:%d" % port, "host.docker.internal:%d" % port):
            return answer(writer, 403, "not this computer's name")
        if auth is None or not hmac.compare_digest(auth, b"Bearer " + key):
            return answer(writer, 401, "this needs DevOS ADE's key for LM Studio")
        if not allowed(method, target):
            return answer(writer, 403, "not part of the API DevOS ADE lets through")
        length = length or 0
        if length > MAX_BODY:
            return answer(writer, 413, "too large")
        if expect is not None:   # (the client waits for this before it sends the body)
            if expect != b"100-continue":
                return answer(writer, 417, "only 100-continue")
            if length:
                writer.write(b"HTTP/1.1 100 Continue\r\n\r\n")
                await writer.drain()
        try:
            body = await asyncio.wait_for(reader.readexactly(length), 300) if length else b""
        except (asyncio.IncompleteReadError, asyncio.TimeoutError):
            return
        try:
            br, bw = await asyncio.open_connection("127.0.0.1", backend)
        except OSError:
            return answer(writer, 502, "LM Studio is not answering")
        out = [b"%s %s HTTP/1.1" % (method.encode(), target.encode()), b"Host: 127.0.0.1:%d" % backend]
        out += [n + b": " + v for n, v in headers]
        out += [b"Content-Length: %d" % length] if length or method in ("POST", "PUT", "PATCH") else []
        bw.write(b"\r\n".join(out + [b"Connection: close", b"", b""]) + body)
        await bw.drain()
        while True:   # (its answer, as it comes: a streamed one too)
            chunk = await br.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        for w in (bw, writer):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def main():
    port, backend = int(sys.argv[1]), int(sys.argv[2])
    with open(sys.argv[3], "rb") as f:
        key = f.read().strip()
    if not re.fullmatch(rb"[0-9a-f]{64}", key) or not (0 < port < 65536 and 0 < backend < 65536) or port == backend:
        sys.exit("lmstudio-gate: no key, or not a port")
    server = await asyncio.start_server(lambda r, w: gate(r, w, port, backend, key), "127.0.0.1", port, limit=MAX_HEAD)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except OSError as e:
        sys.exit("lmstudio-gate: cannot listen on 127.0.0.1:%s (%s)" % (sys.argv[1], e.strerror))
    except KeyboardInterrupt:
        pass
