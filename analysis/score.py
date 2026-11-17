"""Score each vault against a passive full-range LP in the same pool, two ways.

returns: the vault's value change against the passive position's value change
skill:   each side's value change minus what holding its previous balances would have made
         (fees minus loss-versus-rebalancing), so the ETH price drops out
"""
import glob
import json
import os
import statistics

Q96, Q128, M = 2 ** 96, 2 ** 128, 2 ** 256
WINDOW = 90


def steps(rows):
    out = []
    for a, b in zip(rows, rows[1:]):
        sqa, sqb = a["sqrtX96"] / Q96, b["sqrtX96"] / Q96
        pb = sqb * sqb
        xa, ya = a["a0"] / a["supply"], a["a1"] / a["supply"]
        xb, yb = b["a0"] / b["supply"], b["a1"] / b["supply"]
        va, vb = xa + ya / (sqa * sqa), xb + yb / pb
        fees = ((b["fg0"] - a["fg0"]) % M) / Q128 + ((b["fg1"] - a["fg1"]) % M) / Q128 / pb
        fa, fb = 2 / sqa, 2 / sqb + fees
        rv = (vb - (xa + ya / pb)) / va
        rf = (fb - (1 / sqa + sqa / pb)) / fa
        out.append({"block": b["block"], "eth": 1e12 / pb, "rv": rv, "rf": rf,
                    "vault_ret": vb / va - 1, "passive_ret": fb / fa - 1})
    return out


def cumsum(xs):
    s, out = 0.0, []
    for x in xs:
        s += x
        out.append(s)
    return out


def compound(xs):
    v, out = 1.0, []
    for x in xs:
        v *= 1 + x
        out.append(v)
    return out


def study(path):
    data = json.load(open(path))
    rows = sorted(data["rows"], key=lambda r: r["block"])
    st = steps(rows)
    excess = [s["rv"] - s["rf"] for s in st]
    skill = cumsum(excess)
    vault_idx, passive_idx = compound([s["vault_ret"] for s in st]), compound([s["passive_ret"] for s in st])
    gap = [v / p - 1 for v, p in zip(vault_idx, passive_idx)]
    daily_gap = [(1 + s["vault_ret"]) / (1 + s["passive_ret"]) - 1 for s in st]

    final = skill[-1]
    windows = [skill[i] - skill[i - WINDOW] for i in range(WINDOW, len(skill))]
    agree = sum(1 for w in windows if (w > 0) == (final > 0)) / len(windows) if windows else None

    firing = {}
    for floor in (0.01, 0.02, 0.03):
        hit = next((i for i, w in enumerate(windows) if w < -floor), None)
        if hit is None:
            firing[f"{floor:.2f}"] = None
        else:
            at = WINDOW + hit
            firing[f"{floor:.2f}"] = {"day": at, "skill_then": skill[at], "final": final, "saved": skill[at] - final}

    return {
        "vault": data["meta"]["vault"], "pool": data["meta"]["pool"], "days": len(st),
        "eth_start": st[0]["eth"], "eth_end": st[-1]["eth"],
        "return_vs_passive": gap[-1], "skill_vs_passive": final,
        "vault_skill": cumsum([s["rv"] for s in st])[-1], "passive_skill": cumsum([s["rf"] for s in st])[-1],
        "daily_std_return_gap": statistics.pstdev(daily_gap), "daily_std_skill": statistics.pstdev(excess),
        "return_gap_range": [min(gap), max(gap)], "skill_range": [min(skill), max(skill)],
        "window_days": WINDOW, "windows_agreeing_with_final": agree, "firing": firing,
    }


def main():
    here = os.path.dirname(__file__)
    results = {os.path.basename(p)[:-5]: study(p) for p in sorted(glob.glob(os.path.join(here, "data", "*.json")))}
    with open(os.path.join(here, "results", "study.json"), "w") as f:
        json.dump(results, f, indent=1)

    print(f"{'vault':12s} {'days':>5s} {'ETH':>13s} {'return vs passive':>18s} {'skill vs passive':>17s} {'daily std ret/skill':>20s} {'90d agree':>9s}")
    for name, r in results.items():
        print(f"{name:12s} {r['days']:5d} {r['eth_start']:6.0f}->{r['eth_end']:<6.0f} {100 * r['return_vs_passive']:+17.2f}% "
              f"{100 * r['skill_vs_passive']:+16.2f}% {100 * r['daily_std_return_gap']:9.2f}/{100 * r['daily_std_skill']:.2f} "
              f"{100 * r['windows_agreeing_with_final']:8.0f}%")
    print("\nfire if a 90-day skill score drops below the floor (positive saved = helped depositors):")
    for name, r in results.items():
        cells = []
        for k, v in r["firing"].items():
            cells.append(f"-{float(k) * 100:.0f}pt: " + ("never" if v is None else f"day {v['day']}, saved {100 * v['saved']:+.2f}"))
        print(f"  {name:12s} " + " | ".join(cells))


if __name__ == "__main__":
    main()
