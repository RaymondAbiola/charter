"""Replay each vault's actual strategy as a Charter lease, using the hook's settlement rules.

The manager runs the vault's real per-share holdings. Depositors are owed the same capital as
full-range units plus the pool's full-range fees (LeaseMath.owed). Rent accrues on the units'
full-range value and is paid from the bond. The lease is liquidated when held + bond - rent falls
below owed plus the 1% maintenance margin (RiskLogic._assess) and closes as LeaseLogic._close
does: the bond covers any gap first, anything beyond it is uncovered.

The daily samples only show that a lease failed somewhere inside a day. With --fetch, each failure
is narrowed to the hour, then to 25 blocks, then to the block, from archive state, and the samples
are cached in data/intraday-*.json. The hook checks every swap, so the block it fails in is still
a little late. Values are in token1 (WETH), the bond's currency on these pools.
"""
import glob
import json
import os
import sys

Q96, Q128, M = 2 ** 96, 2 ** 128, 2 ** 256
DAY = 7_200
MAINTENANCE = 0.01
BONDS = (0.05, 0.10, 0.20)
RENTS = (0.0, 0.05)
STEPS = (300, 25, 1)


def series(rows):
    """Per sample: price, held value per share, and full-range fees per unit since the first sample, in token1."""
    out, f0, f1 = [], 0, 0
    for i, r in enumerate(rows):
        if i:
            f0 += (r["fg0"] - rows[i - 1]["fg0"]) % M
            f1 += (r["fg1"] - rows[i - 1]["fg1"]) % M
        s = r["sqrtX96"] / Q96
        p = s * s
        out.append({"block": r["block"], "s": s, "eth": 1e12 / p,
                    "held": (r["a0"] * p + r["a1"]) / r["supply"],
                    "fees": f0 / Q128 * p + f1 / Q128})
    return out


def replay(days, bond_pct, rent):
    d0 = days[0]
    units = d0["held"] / (2 * d0["s"])  # the capital, as full-range units worth one share
    bond = bond_pct * d0["held"]
    paid = 0.0
    for prev, d in zip(days, days[1:]):
        paid += 2 * units * d["s"] * rent * (d["block"] - prev["block"]) / DAY / 365
        owed = 2 * units * d["s"] + units * d["fees"]
        if d["held"] + bond - paid >= owed * (1 + MAINTENANCE) and d is not days[-1]:
            continue
        failed = d["held"] + bond - paid < owed * (1 + MAINTENANCE)
        gap = max(owed + paid - d["held"], 0.0)
        uncovered = max(gap - bond, 0.0)
        return {
            "liquidated_day": round((d["block"] - d0["block"]) / DAY, 2) if failed else None,
            "liquidated_block": d["block"] if failed else None,
            "checked_after": prev["block"],
            "eth_then": d["eth"],
            # from here the depositors' capital and the benchmark are the same full-range position
            "depositor_vs_passive": (paid - uncovered) / owed,
            "rent_pct": paid / owed,
            "uncovered_pct": uncovered / owed,
            "bond_used_pct": min(gap, bond) / bond,
            "manager_pnl_pct": (d["held"] - owed - paid + uncovered) / d0["held"],
        }


def bond_needed(days, rent):
    """The smallest bond, as a share of the capital, that keeps the lease open the whole period."""
    d0 = days[0]
    units = d0["held"] / (2 * d0["s"])
    paid, worst = 0.0, 0.0
    for prev, d in zip(days, days[1:]):
        paid += 2 * units * d["s"] * rent * (d["block"] - prev["block"]) / DAY / 365
        owed = 2 * units * d["s"] + units * d["fees"]
        worst = max(worst, owed * (1 + MAINTENANCE) + paid - d["held"])
    return worst / d0["held"]


def refine(name, meta, rows, extra):
    """Narrows every failure to the block it happened in, fetching samples the cache lacks."""
    import fetch  # needs MAINNET_RPC_URL with archive state

    for _ in range(len(STEPS) + 1):
        merged = sorted({r["block"]: r for r in rows + extra}.values(), key=lambda r: r["block"])
        days = series(merged)
        wanted = set()
        for b in BONDS:
            for r in RENTS:
                l = replay(days, b, r)
                if not l["liquidated_block"]:
                    continue
                lo, hi = l["checked_after"], l["liquidated_block"]
                step = next((s for s in STEPS if s < hi - lo), None)
                if step:
                    wanted.update(range(lo + step, hi, step))
        have = {r["block"] for r in merged}
        wanted -= have
        if not wanted:
            return extra
        print(f"  {name}: fetching {len(wanted)} samples")
        for block in sorted(wanted):
            row = fetch.sample(meta["vault"], meta["pool"], meta["getter"], block)
            if row:
                extra.append(row)
    return extra


def study(path, fetching):
    data = json.load(open(path))
    name = os.path.basename(path)[:-5]
    meta = dict(data["meta"])
    rows = data["rows"]
    cache = os.path.join(os.path.dirname(path), f"intraday-{name}.json")
    extra = json.load(open(cache))["rows"] if os.path.exists(cache) else []
    if fetching:
        import fetch
        meta["getter"] = next(v[3] for v in fetch.VAULTS if v[0] == name)
        extra = refine(name, meta, rows, extra)
        with open(cache, "w") as f:
            json.dump({"meta": {"vault": meta["vault"], "pool": meta["pool"]}, "rows": extra}, f)
    daily = series(sorted(rows, key=lambda r: r["block"]))
    days = series(sorted({r["block"]: r for r in rows + extra}.values(), key=lambda r: r["block"]))
    d0, last = daily[0], daily[-1]
    units = d0["held"] / (2 * d0["s"])
    owed = 2 * units * last["s"] + units * last["fees"]
    return {
        "vault": meta["vault"],
        "days": round((last["block"] - d0["block"]) / DAY),
        "eth_start": d0["eth"],
        "eth_end": last["eth"],
        "vault_vs_passive": last["held"] / owed - 1,
        "bond_needed": {f"{r:.2f}": bond_needed(daily, r) for r in RENTS},
        "leases": {f"bond {b:.2f} rent {r:.2f}": replay(days, b, r) for b in BONDS for r in RENTS},
        "leases_checked_daily": {f"bond {b:.2f} rent {r:.2f}": replay(daily, b, r) for b in BONDS for r in RENTS},
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    fetching = "--fetch" in sys.argv
    paths = [p for p in sorted(glob.glob(os.path.join(here, "data", "*.json"))) if "intraday-" not in p]
    results = {os.path.basename(p)[:-5]: study(p, fetching) for p in paths}
    with open(os.path.join(here, "results", "backtest.json"), "w") as f:
        json.dump(results, f, indent=1)

    pct = lambda x: f"{100 * x:+.2f}%"
    for name, r in results.items():
        print(f"\n{name}: {r['days']} days, ETH {r['eth_start']:.0f} -> {r['eth_end']:.0f}, "
              f"vault vs passive {pct(r['vault_vs_passive'])}")
        print(f"  bond to never be liquidated: {100 * r['bond_needed']['0.00']:.1f}% at 0% rent, "
              f"{100 * r['bond_needed']['0.05']:.1f}% at 5% rent")
        for k, l in r["leases"].items():
            daily = r["leases_checked_daily"][k]
            when = f"liquidated day {l['liquidated_day']:7.2f}" if l["liquidated_day"] is not None else "never liquidated  "
            print(f"  {k}: {when}  depositors vs passive {pct(l['depositor_vs_passive'])}  "
                  f"uncovered {pct(l['uncovered_pct'])} (daily check {pct(daily['uncovered_pct'])})  "
                  f"manager {pct(l['manager_pnl_pct'])}")


if __name__ == "__main__":
    main()
