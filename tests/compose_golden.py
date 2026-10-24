#!/usr/bin/env python3
"""The stack's internal names as Docker Compose renders them, for tests/test_brand.sh's golden check: reads
`docker compose config --format json` on stdin and prints only what data, links and running services depend on — the
project's name; each service's container name, image, volumes (named ones by name, binds by where they go), networks,
labels and published ports; the project's volumes and networks by their names. A path of this computer is written as
the placeholder its argument names (PLACEHOLDER=PATH ..., the longest first), so the output is the same anywhere.

Usage: docker compose config --format json | tests/compose_golden.py '<STACK>=/path/to/checkout' '<HOME>=/home/me'
"""

from __future__ import annotations

import json
import sys


def main(argv: list[str]) -> int:
    subs = sorted((a.split("=", 1) for a in argv), key=lambda kv: -len(kv[1]))

    def p(v):
        if isinstance(v, str):
            for name, path in subs:
                if path:
                    v = v.replace(path, name)
        return v

    c = json.load(sys.stdin)
    out = {"name": c.get("name"), "services": {}, "volumes": {}, "networks": {}}
    for name, s in sorted((c.get("services") or {}).items()):
        vols = []
        for v in s.get("volumes") or []:
            vols.append({k: p(v.get(k)) for k in ("type", "source", "target", "read_only") if v.get(k) is not None})
        nets = s.get("networks") or {}
        out["services"][name] = {
            "container_name": s.get("container_name"),
            "image": p(s.get("image")),
            "volumes": vols,
            "networks": sorted(nets) if isinstance(nets, dict) else sorted(nets),
            "labels": {k: p(v) for k, v in sorted((s.get("labels") or {}).items())},
            "ports": [{k: str(x.get(k)) for k in ("host_ip", "published", "target", "protocol") if x.get(k) is not None}
                      for x in s.get("ports") or []],
        }
    for kind in ("volumes", "networks"):
        for key, v in sorted((c.get(kind) or {}).items()):
            out[kind][key] = {"name": p((v or {}).get("name")), "external": bool((v or {}).get("external"))}
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
