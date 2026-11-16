"""Sample each vault's per-share balances and its pool's state once a day, from archive state."""
import json
import os
from concurrent.futures import ThreadPoolExecutor

import rpc

POOL_5 = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
POOL_30 = "0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8"
DAY = 7_200

VAULTS = [
    ("guni-5", "0xa6c49fd13e50a30c65e6c8480aada132011d0613", POOL_5, "0x1322d954", 14_000_000, 18_000_000),
    ("vault5763-5", "0x5763bf13a2ce7a76784b36aadf2f9098325d4038", POOL_5, "0xc4a7761e", 14_000_000, 18_000_000),
    ("charm-30", "0x9bf7b46c7ad5ab62034e9349ab912c0345164322", POOL_30, "0xc4a7761e", 14_000_000, 18_000_000),
    ("vault381e-5", "0x381e7287eb6df7c74b52661f91b1b02269144198", POOL_5, "0xc4a7761e", 18_000_000, 21_400_000),
]


def ok(x):
    return x is not None and len(x) >= 66


def sample(vault, pool, getter, block):
    amounts = rpc.eth_call(vault, getter, block)
    supply = rpc.eth_call(vault, "0x18160ddd", block)
    slot0 = rpc.eth_call(pool, "0x3850c7bd", block)
    fg0 = rpc.eth_call(pool, "0xf3058399", block)
    fg1 = rpc.eth_call(pool, "0x46141319", block)
    if not all(ok(x) for x in (amounts, supply, slot0, fg0, fg1)) or len(amounts) < 130:
        return None
    a0, a1 = rpc.words(amounts)[:2]
    s = rpc.words(supply)[0]
    if s == 0:
        return None
    return {"block": block, "a0": a0, "a1": a1, "supply": s,
            "sqrtX96": rpc.words(slot0)[0], "fg0": rpc.words(fg0)[0], "fg1": rpc.words(fg1)[0]}


def main():
    out_dir = os.path.join(os.path.dirname(__file__), "data")
    os.makedirs(out_dir, exist_ok=True)
    for name, vault, pool, getter, start, end in VAULTS:
        blocks = list(range(start, end + 1, DAY))
        with ThreadPoolExecutor(8) as ex:
            rows = [r for r in ex.map(lambda b: sample(vault, pool, getter, b), blocks) if r]
        meta = {"vault": vault, "pool": pool, "start": start, "end": end, "step": DAY,
                "requested": len(blocks), "samples": len(rows)}
        with open(os.path.join(out_dir, f"{name}.json"), "w") as f:
            json.dump({"meta": meta, "rows": rows}, f)
        print(f"{name}: {len(rows)}/{len(blocks)} samples")


if __name__ == "__main__":
    main()
