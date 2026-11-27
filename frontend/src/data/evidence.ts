export interface EvidenceRow {
  vault: string;
  startPrice: number;
  endPrice: number;
  days: number;
  returnVsPassive: number;
  skillVsPassive: number;
}

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
  "Source: analysis/ in the Charter repo, four mainnet Uniswap v3 USDC/WETH vaults sampled daily. Skill differences between vaults are within measurement noise. Historical observations, not Charter results.";

export interface ReplayRow {
  vault: string;
  /** depositors against passive as the vault actually ran, on Charter's benchmark */
  actualVsPassive: number;
  /** depositors against passive as a Charter lease, minimum 5% bond, 0% rent */
  charterVsPassive: number;
  /** with 5% rent, same bond */
  charterWithRent: number;
  closedDay: number;
  managerLoss: number;
  uncovered: number;
}

// analysis/results/backtest.json, bond 0.05
export const replay: readonly ReplayRow[] = [
  {
    vault: "Charm Alpha Vault",
    actualVsPassive: -12.3,
    charterVsPassive: 0,
    charterWithRent: 1.3,
    closedDay: 103,
    managerLoss: 3.9,
    uncovered: 0,
  },
  {
    vault: "G-UNI (Arrakis V1)",
    actualVsPassive: -14.1,
    charterVsPassive: 0,
    charterWithRent: 1.3,
    closedDay: 118,
    managerLoss: 3.7,
    uncovered: 0,
  },
  {
    vault: "Vault 0x381e",
    actualVsPassive: -14.1,
    charterVsPassive: 0,
    charterWithRent: 2.1,
    closedDay: 169,
    managerLoss: 4.2,
    uncovered: 0,
  },
  {
    vault: "Vault 0x5763",
    actualVsPassive: 12.9,
    charterVsPassive: 0,
    charterWithRent: 0.6,
    closedDay: 41,
    managerLoss: 4.0,
    uncovered: 0,
  },
];
export const replayTitle = "The same vaults, as Charter leases.";
export const replayNote =
  "Each vault's real holdings, replayed block by block under the hook's settlement rules with the minimum 5% bond. Depositors end at passive. The manager's bond covers every shortfall.";
export const replayFindings: readonly string[] = [
  "Nothing left uncovered in any of the 24 cases tested. Checked once a day instead of every block, up to 2.65% would have been.",
  "To keep running through the whole period, Charm's manager would have needed a 36% bond and G-UNI's 63%.",
  "Depositors give up the lucky upside too: with a 20% bond, 0x5763's manager keeps +19.8% and depositors get passive.",
];
export const replaySource =
  "Source: analysis/backtest.py. A model of the hook run on the vaults' historical holdings, not a live result. Returns against passive at 0% rent; at 5% rent depositors end 0.6 to 2.1 points ahead.";
