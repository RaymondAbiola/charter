"""Find managed-liquidity vaults on a v3 pool: contracts that mint directly into it
(not through the NFT position manager) and expose a vault-style balance getter."""
import collections
import sys

import rpc

MINT = "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"
NFPM = "0xc36442b4a4522e871399cd717abdd847ab11fe88"
GETTERS = {"getTotalAmounts": "0xc4a7761e", "getUnderlyingBalances": "0x1322d954"}


def owners(pool, windows, span=30_000, chunk=10_000):
    seen = collections.Counter()
    for w in windows:
        for s in range(w, w + span, chunk):
            for log in rpc.call("eth_getLogs", [{"address": pool, "topics": [MINT], "fromBlock": hex(s), "toBlock": hex(s + chunk - 1)}]):
                owner = "0x" + log["topics"][1][-40:]
                if owner != NFPM:
                    seen[owner] += 1
    return seen


def kind(addr):
    for name, sel in GETTERS.items():
        out = rpc.eth_call(addr, sel)
        if out and len(out) >= 130:
            return name
    return None


if __name__ == "__main__":
    pool = sys.argv[1]
    windows = [int(x) for x in sys.argv[2:]] or [14_200_000, 15_400_000, 16_600_000, 17_800_000]
    for owner, n in owners(pool, windows).most_common(30):
        k = kind(owner)
        if k:
            print(owner, n, k)
