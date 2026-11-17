"""Check how the skill score depends on sampling frequency: fetch one window hourly, then
score the same data hourly, every 6 hours, daily and weekly."""
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

from fetch import POOL_5, sample
from score import cumsum, steps

HOUR = 300
VAULTS = [
    ("guni-5", "0xa6c49fd13e50a30c65e6c8480aada132011d0613", "0x1322d954"),
    ("vault5763-5", "0x5763bf13a2ce7a76784b36aadf2f9098325d4038", "0xc4a7761e"),
]


def skill(rows):
    st = steps(rows)
    return cumsum([s["rv"] - s["rf"] for s in st])[-1]


def main():
    start = int(sys.argv[1]) if len(sys.argv) > 1 else 15_000_000
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    end = start + days * 7_200
    here = os.path.dirname(__file__)
    out = {}
    for name, vault, getter in VAULTS:
        blocks = list(range(start, end + 1, HOUR))
        with ThreadPoolExecutor(8) as ex:
            rows = [r for r in ex.map(lambda b: sample(vault, POOL_5, getter, b), blocks) if r]
        res = {"hourly_samples": len(rows)}
        for label, every in (("1h", 1), ("6h", 6), ("1d", 24), ("1w", 168)):
            res[label] = skill(rows[::every])
        out[name] = res
        print(name, f"{len(rows)} hourly samples, skill vs passive:",
              "  ".join(f"{k} {100 * v:+.3f}%" for k, v in res.items() if k != "hourly_samples"))
    with open(os.path.join(here, "results", "sampling.json"), "w") as f:
        json.dump({"start": start, "end": end, "results": out}, f, indent=1)


if __name__ == "__main__":
    main()
