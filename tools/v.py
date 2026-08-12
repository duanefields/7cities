#!/usr/bin/env python3
"""Thin JSON-RPC client for the vice-mcp HTTP server."""
import json, sys, urllib.request
from typing import Any

URL = "http://127.0.0.1:6510/mcp"
_id = [100]


def rpc(method, params=None):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method,
                       "params": params or {}}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read().decode()
    if raw.startswith("event:") or raw.startswith("data:"):
        for line in raw.splitlines():
            if line.startswith("data:"):
                raw = line[5:].strip()
                break
    return json.loads(raw)


def call(tool, **args) -> Any:
    r = rpc("tools/call", {"name": tool, "arguments": args})
    if "error" in r:
        return {"_error": r["error"]}
    c = r.get("result", {}).get("content", [])
    out = []
    for item in c:
        if item.get("type") == "text":
            t = item["text"]
            try:
                out.append(json.loads(t))
            except Exception:
                out.append(t)
        else:
            out.append(item)
    if r.get("result", {}).get("structuredContent"):
        return r["result"]["structuredContent"]
    return out[0] if len(out) == 1 else out


def tools():
    return [t["name"] for t in rpc("tools/list").get("result", {}).get("tools", [])]


if __name__ == "__main__":
    if sys.argv[1] == "tools":
        for t in tools():
            print(t)
    else:
        kw = dict(a.split("=", 1) for a in sys.argv[2:])
        for k, v in kw.items():
            try:
                kw[k] = json.loads(v)
            except Exception:
                pass
        print(json.dumps(call(sys.argv[1], **kw), indent=1)[:4000])
