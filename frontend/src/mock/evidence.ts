import type { EvidenceRow } from "./types.ts";

export const evidence: readonly EvidenceRow[] = [
  {
    vault: "Charm Alpha Vault",
    startPrice: 3309,
    endPrice: 1651,
    days: 553,
    returnVsPassive: -12.7,
    skillVsPassive: -2.5,
  },
  {
    vault: "G-UNI (Arrakis V1)",
    startPrice: 3301,
    endPrice: 1652,
    days: 554,
    returnVsPassive: -14.4,
    skillVsPassive: -1.2,
  },
  {
    vault: "Vault 0x381e",
    startPrice: 1656,
    endPrice: 3912,
    days: 472,
    returnVsPassive: -14.1,
    skillVsPassive: -2.4,
  },
  {
    vault: "Vault 0x5763",
    startPrice: 3301,
    endPrice: 1652,
    days: 555,
    returnVsPassive: 12.5,
    skillVsPassive: -1.6,
  },
];
export const evidenceNote =
  "Depositors in three of four vaults ended about 13 to 14 percentage points behind a passive LP. Actual market making was close to passive. The gap was price exposure depositors never chose.";
export const evidenceSource =
  "Source: supplied study of four mainnet Uniswap v3 USDC/WETH vaults, sampled daily. Skill differences between vaults are within measurement noise. Historical observations, not Charter results.";
