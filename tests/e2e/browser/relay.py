"""The Linux browser's own network (browser-net.sh, for browser.sh, ui-sweep.sh and https.sh). The browser container is
not on the test host's network: there, Chromium cancels what it is loading whenever a Docker network or container of
any run on the host comes or goes (net::ERR_NETWORK_CHANGED: v0.57.0's first release run, four stages at once). It
reaches the stack's ports on the host's 127.0.0.1 through Unix sockets in a folder both see:

  relay.py host DIR PORT...             on the host: DIR/PORT.sock for each port, each connection on to 127.0.0.1:PORT;
                                        "ready" on stdout once every socket listens; ends with the process that
                                        started it
  relay.py inside DIR PORT... -- CMD..  in the container: 127.0.0.1:PORT for each port, each connection on to
                                        DIR/PORT.sock; then CMD, whose exit status is its own

Only the ports named. Bytes each way as they come, nothing read or changed (HTTP, TLS and WebSockets alike); a side
that ends its half ends the other's (half-close), so a request that ends its body still gets its answer."""
import asyncio
import os
import signal
import sys

BUF = 1 << 16


async def pipe(r: asyncio.StreamReader, w: asyncio.StreamWriter) -> None:
    try:
        while True:
            b = await r.read(BUF)
            if not b:
                break
            w.write(b)
            await w.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            if w.can_write_eof():
                w.write_eof()
        except (OSError, RuntimeError):
            pass


def opener(mode: str, d: str, port: int):
    if mode == "host":
        return lambda: asyncio.open_connection("127.0.0.1", port)
    return lambda: asyncio.open_unix_connection(os.path.join(d, f"{port}.sock"))


def handler(connect):
    async def splice(r1: asyncio.StreamReader, w1: asyncio.StreamWriter) -> None:
        try:
            r2, w2 = await connect()
        except OSError:
            w1.close()   # (nothing listens there: the connection is refused, as it would be without the relay)
            return
        try:
            await asyncio.gather(pipe(r1, w2), pipe(r2, w1))
        finally:
            for w in (w1, w2):
                w.close()
    return splice


async def listen(mode: str, d: str, ports: list[int]) -> list[asyncio.base_events.Server]:
    servers = []
    for p in ports:
        h = handler(opener(mode, d, p))
        if mode == "host":
            path = os.path.join(d, f"{p}.sock")
            if os.path.exists(path):
                os.unlink(path)
            servers.append(await asyncio.start_unix_server(h, path=path))
            os.chmod(path, 0o600)
        else:
            servers.append(await asyncio.start_server(h, host="127.0.0.1", port=p))
    return servers


async def host(d: str, ports: list[int]) -> int:
    await listen("host", d, ports)
    print("ready", flush=True)
    parent = os.getppid()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(s, stop.set)
    # (the shell that started it gone — killed, or ended without stopping it: no relay left behind)
    while not stop.is_set() and os.getppid() == parent:
        try:
            await asyncio.wait_for(stop.wait(), 2)
        except asyncio.TimeoutError:
            pass
    for p in ports:
        try:
            os.unlink(os.path.join(d, f"{p}.sock"))
        except OSError:
            pass
    return 0


async def inside(d: str, ports: list[int], cmd: list[str]) -> int:
    await listen("inside", d, ports)
    proc = await asyncio.create_subprocess_exec(*cmd)
    loop = asyncio.get_running_loop()
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(s, lambda s=s: proc.returncode is None and proc.send_signal(s))
    return await proc.wait()


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[0] not in ("host", "inside"):
        print(__doc__, file=sys.stderr)
        return 2
    mode, d, rest = argv[0], argv[1], argv[2:]
    cmd: list[str] = []
    if mode == "inside":
        if "--" not in rest or rest.index("--") == len(rest) - 1:
            print("relay.py inside: the command after --", file=sys.stderr)
            return 2
        cmd = rest[rest.index("--") + 1:]
        rest = rest[:rest.index("--")]
    try:
        ports = sorted({int(p) for p in rest})
    except ValueError:
        print(f"relay.py: not a port among {rest}", file=sys.stderr)
        return 2
    if not ports or any(not 0 < p < 65536 for p in ports):
        print(f"relay.py: no ports, or one out of range: {rest}", file=sys.stderr)
        return 2
    try:
        return asyncio.run(host(d, ports) if mode == "host" else inside(d, ports, cmd))
    except OSError as e:   # (a port taken, a socket's path too long: at most ~104 bytes)
        print(f"relay.py {mode}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
