# Vault study

Do managed liquidity vaults beat a passive full-range LP in the same pool, and where does the difference come from?

## Data

Daily archive samples of four managed vaults on mainnet Uniswap v3 USDC/WETH, about 1.3 to 1.5 years each: per-share token balances, pool price and fee growth.

| Vault | Pool | Period (ETH) | Days |
|---|---|---|---|
| Charm Alpha Vault `0x9bf7b46c7ad5ab62034e9349ab912c0345164322` | 0.3% | 2022 to 2023 ($3,309 to $1,651) | 553 |
| G-UNI `0xa6c49fd13e50a30c65e6c8480aada132011d0613` | 0.05% | 2022 to 2023 ($3,301 to $1,652) | 554 |
| `0x381e7287eb6df7c74b52661f91b1b02269144198` | 0.05% | 2023 to 2024 ($1,656 to $3,912) | 472 |
| `0x5763bf13a2ce7a76784b36aadf2f9098325d4038` | 0.05% | 2022 to 2023 ($3,301 to $1,652) | 555 |

## Two measures

- **Return vs passive:** the vault's per-share value against a passive full-range position in the same pool, fees included.
- **Skill vs passive:** each side's value change minus what holding its previous balances would have made, summed. This is fees minus loss-versus-rebalancing, with the ETH price taken out.

## Results

| Vault | Return vs passive | Skill vs passive |
|---|---|---|
| Charm | -12.7% | -2.5% |
| G-UNI | -14.4% | -1.2% |
| 0x381e | -14.1% | -2.4% |
| 0x5763 | +12.5% | -1.6% |

- Depositors in three of the four vaults ended 12.7 to 14.4 points behind a passive LP, in a falling market and in a rising one.
- The skill gaps are small next to the return gaps. Nearly all of the difference is price exposure from the shape of the range, not market making.
- Charm charged a 5% protocol fee on all fees earned (`protocolFee` = 50,000 per million) throughout.

## How reliable the skill numbers are

Skill depends on how often it is sampled. `sampling.py` fetched 60 days hourly for two vaults and scored the same data at four rates:

| Vault | 1h | 6h | 1d | 1w |
|---|---|---|---|---|
| G-UNI | +0.23% | +0.07% | +0.72% | -0.47% |
| 0x5763 | +0.21% | +0.33% | +0.18% | -0.07% |

At hourly sampling both vaults are about +0.2% over 60 days, so effectively equal to passive. Weekly sampling can flip the sign. Read the skill column as "close to passive for all four"; the differences between vaults are inside the measurement noise. A hook scoring every swap does not have this problem.

90-day skill scores agreed in sign with the full-period result only 36% to 67% of the time, and a rule that fired a manager after a bad quarter would have saved or cost depositors less than about one point either way.

## The same vaults as Charter leases

`backtest.py` replays each vault's real per-share holdings as one Charter lease, following the hook's settlement code:

- **Owed** is the capital as full-range units plus the pool's full-range fees since the lease opened (`LeaseMath.owed`).
- **Rent** accrues on the units' full-range value and is paid from the bond.
- **Liquidation** happens when held value plus bond, less rent, falls below owed plus the 1% margin (`RiskLogic._assess`).
- **Closing** works as in `LeaseLogic._close`: the bond fills any gap, and anything beyond it is uncovered.

Values are in WETH, the pools' token1 and so the bond's currency. Each failure found in the daily samples is narrowed to the hour, then to 25 blocks, then to the exact block, from archive state. Those samples are cached in `data/intraday-*.json`, so the replay runs offline.

At the minimum 5% bond and 0% rent:

| Vault | Vault vs passive | Lease closed | Depositors vs passive | Uncovered | Manager |
|---|---|---|---|---|---|
| Charm | -12.34% | Day 102.8 | 0.00% | 0.00% | -3.89% |
| G-UNI | -14.10% | Day 117.6 | 0.00% | 0.00% | -3.72% |
| 0x381e | -14.11% | Day 168.7 | 0.00% | 0.00% | -4.21% |
| 0x5763 | +12.86% | Day 41.3 | 0.00% | 0.00% | -3.97% |

"Vault vs passive" uses Charter's benchmark, which leaves fees uninvested, so it differs slightly from the study above. Manager results are a share of the leased capital.

- **Nothing was uncovered in any of the 24 cases** (bonds of 5, 10 and 20%, rent of 0 and 5%). Checked only once a day, the same leases leave up to 2.65% uncovered, and a bigger bond can leave more because the lease survives into a larger daily move.
- **Bond needed to stay open for the whole period:** Charm 36.2%, G-UNI 62.8%, 0x381e 15.0%, 0x5763 16.9% (0% rent).
- **0x5763 with a 20% bond** is never liquidated: the manager ends +19.82% of the capital ahead and depositors get passive.
- **At 5% rent**, depositors end 0.56 to 2.11 points ahead of passive at the minimum bond.

Limits: passive fees come from the pool's fee growth, not Charter's in-pool estimator. The manager follows the vault's real strategy and never tops up. Only the failing days are searched block by block, so a breach that recovered within a day is missed. The hook checks every swap, so the block a lease fails in is still a little late.

## Reproduce

```
export MAINNET_RPC_URL=...        # needs historical state
python3 fetch.py                  # data/*.json
python3 score.py                  # results/study.json
python3 sampling.py 15000000 60   # results/sampling.json
python3 discover.py <pool>        # find more vaults
python3 backtest.py               # results/backtest.json, from the cached samples
python3 backtest.py --fetch       # refetch block-level samples (needs archive state)
```
