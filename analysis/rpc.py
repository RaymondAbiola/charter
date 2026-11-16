import json
import os
import time
import urllib.request


def _url():
    url = os.environ.get("MAINNET_RPC_URL")
    if url:
        return url
    path = os.environ.get("ENV_FILE", os.path.join(os.path.dirname(__file__), "..", ".env"))
    with open(path) as f:
        for line in f:
            if line.startswith("MAINNET_RPC_URL="):
                return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("MAINNET_RPC_URL is not set")


URL = _url()


def call(method, params, tries=5):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for i in range(tries):
        try:
            req = urllib.request.Request(URL, body, {"content-type": "application/json"})
            res = json.load(urllib.request.urlopen(req, timeout=30))
            if "error" in res:
                raise RuntimeError(res["error"].get("message", "rpc error"))
            return res["result"]
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(1.5 * (i + 1))


def eth_call(to, data, block="latest"):
    blk = block if isinstance(block, str) else hex(block)
    try:
        return call("eth_call", [{"to": to, "data": data}, blk])
    except Exception:
        return None


def words(h):
    h = h[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]
