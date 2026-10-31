#!/usr/bin/env python3
"""Where a model server may be (lib/local_models.sh msrv_target): the one place a server's address is judged.

    python3 -I lib/msrv_target.py URL      prints one TAB line:
      ok       ADDRESS HOST PORT   the checked address to pin (every address the name gave passed)
      blocked  REASON              cloud metadata, link-local, multicast, reserved or unspecified: no model server lives there
      numeric  REASON              a numeric host that is not in standard form (octal, hex, short, leading zeros)
      dns      REASON              the name does not resolve

Standard library only. A host that ipaddress.ip_address() parses strictly is used as it is; a numeric-looking one it does
not parse is refused (curl and getaddrinfo would read 0251.0376.0251.0376, 169.254.43518 or 0xa9fea9fe as 169.254.169.254
while a hand-rolled check sees something else); any other host is resolved with getaddrinfo and EVERY result is checked,
IPv4 embedded in IPv6 (mapped, compatible, 6to4, Teredo, NAT64) included. Loopback and private addresses are allowed.
Tests set DEVOS_ADE_TESTING=1 and MSRV_TEST_RESOLVE="host=addr,addr;host2=addr" for a resolver of their own."""
import ipaddress
import os
import re
import socket
import sys
from urllib.parse import urlsplit

METADATA_NAMES = {"metadata.google.internal", "metadata.azure.internal", "instance-data", "metadata.goog"}
EXTRA_V4 = {ipaddress.ip_address("100.100.100.200"): "100.100.100.200 is a cloud metadata address"}
AWS_V6 = ipaddress.ip_address("fd00:ec2::254")


def embedded(ip):
    """The IPv4 addresses an IPv6 one carries, however it is wrapped."""
    out = []
    if ip.version != 6:
        return out
    if ip.ipv4_mapped:
        out.append(ip.ipv4_mapped)
    if ip.sixtofour:
        out.append(ip.sixtofour)
    if ip.teredo:
        out.extend(ip.teredo)   # (the server and the client)
    b = ip.packed
    if int(ip) >> 32 == 0 and int(ip) > 1:   # ::/96, IPv4-compatible (::1 is loopback, not this)
        out.append(ipaddress.IPv4Address(b[12:16]))
    if b[:12] == bytes.fromhex("0064ff9b0000000000000000"):   # NAT64 64:ff9b::/96
        out.append(ipaddress.IPv4Address(b[12:16]))
    if b[:6] == bytes.fromhex("0064ff9b0001"):               # 64:ff9b:1::/48 (RFC 6052: bits 48-63 and 72-87)
        out.append(ipaddress.IPv4Address(bytes([b[6], b[7], b[9], b[10]])))
        out.append(ipaddress.IPv4Address(b[12:16]))
    return out


def why_blocked(ip):
    """The reason this address is refused, or None."""
    if ip.version == 4:
        if ip in EXTRA_V4:
            return EXTRA_V4[ip]
        if ip.is_link_local:
            return "169.254.0.0/16 is the cloud metadata and link-local range"
        if int(ip) >> 24 == 0:
            return "0.0.0.0/8 is not a server address"
        if ip.is_multicast or ip == ipaddress.ip_address("255.255.255.255") or ip.is_reserved:
            return "multicast, broadcast and reserved addresses are not server addresses"
        return None
    if ip.is_loopback:
        return None
    if ip == AWS_V6:
        return "fd00:ec2::254 is the AWS metadata address"
    if ip.is_link_local:
        return "fe80::/10 is link-local"
    if ip.is_multicast:
        return "IPv6 multicast is not a server address"
    if ip.is_unspecified:
        return "the unspecified address is not a server address"
    for v4 in embedded(ip):
        r = why_blocked(v4)
        if r:
            return f"it wraps an IPv4 address that is refused ({v4}: {r})"
    return None


def looks_numeric(h):
    return bool(re.fullmatch(r"[0-9.]+", h)) or h.lower().startswith("0x") or bool(re.fullmatch(r"[0-9]+", h))


def strict_ip(h):
    """An ip_address for a canonical literal; None when it is not one."""
    if re.search(r"(^|\.)0[0-9]", h):    # (leading zeros: octal to curl, decimal to some parsers)
        return None
    try:
        return ipaddress.ip_address(h)
    except ValueError:
        return None


def resolve(h, port):
    if os.environ.get("DEVOS_ADE_TESTING") == "1" and "MSRV_TEST_RESOLVE" in os.environ:
        table = dict(p.split("=", 1) for p in os.environ["MSRV_TEST_RESOLVE"].split(";") if "=" in p)
        return [a for a in table.get(h, "").split(",") if a]
    try:
        return sorted({r[4][0].split("%")[0] for r in socket.getaddrinfo(h, port, type=socket.SOCK_STREAM)})
    except (socket.gaierror, UnicodeError, OSError):
        return []


def main(url):
    try:
        u = urlsplit(url)
        host, port = u.hostname, u.port or (443 if u.scheme == "https" else 80)
    except ValueError:
        return "blocked\tnot a server address"
    if not host or u.scheme not in ("http", "https"):
        return "blocked\tnot a server address"
    host = host.rstrip(".").lower()
    if host in METADATA_NAMES:
        return f"blocked\tno model server lives at a cloud metadata name ({host})"
    ip = strict_ip(host)
    if ip is None and (looks_numeric(host) or ":" in host):
        return "numeric\twrite the address in standard form (e.g. 192.168.1.20): this one could be read as another address"
    addrs = [ip] if ip is not None else []
    if ip is None:
        for a in resolve(host, port):
            try:
                addrs.append(ipaddress.ip_address(a))
            except ValueError:
                return f"blocked\t{host}: the resolver gave something that is not an address"
        if not addrs:
            return "dns\tits name does not resolve (DNS) from this computer"
    for a in addrs:
        r = why_blocked(a)
        if r:
            return f"blocked\t{host}: no model server lives there ({r})"
    return f"ok\t{addrs[0]}\t{host}\t{port}"


if __name__ == "__main__":
    print(main(sys.argv[1]) if len(sys.argv) == 2 else "blocked\tno address")
