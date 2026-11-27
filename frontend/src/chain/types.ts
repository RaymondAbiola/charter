export type Address = `0x${string}`;
export type TokenAmounts = readonly [amount0: bigint, amount1: bigint];

export type EventKind =
  | "Deposit"
  | "Withdraw"
  | "LeaseOpened"
  | "BidPlaced"
  | "LeaseTakenOver"
  | "Rebalanced"
  | "RentPaid"
  | "BondToppedUp"
  | "Liquidated"
  | "LeaseRecalled"
  | "LeaseEnded"
  | "BidRefunded"
  | "BidVoided"
  | "Repassivated";

export interface PriceRange {
  lower: number;
  upper: number;
}

/** Values are in USDC at the settlement price. */
export interface Lease {
  slot: number;
  manager: Address;
  rentRate: number;
  rentPips: number;
  units: bigint;
  capital: number;
  bond: number;
  rentDue: number;
  /** Held value plus bond, less unpaid rent. */
  equity: number;
  /** What the lease owes depositors: its units at full range plus fee debt. */
  debt: number;
  ticks: { lower: number; upper: number };
  range: PriceRange;
  liquidation: PriceRange;
  openedAt: number;
}

export interface Bid {
  slot: number;
  manager: Address;
  rentRate: number;
  units: bigint;
  capital: number;
  bond: number;
  range: PriceRange;
  takeoverAt: number;
}

export interface ActivityEvent {
  id: string;
  kind: EventKind;
  address: Address;
  amount: number | null;
  shares?: bigint;
  at: number;
  detail: string;
  tx: `0x${string}`;
}

export interface Wallet {
  address: Address;
  eth: bigint;
  weth: bigint;
  usdc: bigint;
  allowanceWeth: bigint;
  allowanceUsdc: bigint;
  shares: bigint;
  redeemable: TokenAmounts;
}

export interface Snapshot {
  block: bigint;
  /** Block time in ms. */
  at: number;
  price: number;
  sqrtPriceX96: bigint;
  supply: bigint;
  passiveUnits: bigint;
  leasedUnits: bigint;
  /** Everything depositors own, in USDC. */
  total: number;
  uncovered: number;
  leases: Lease[];
  bids: Bid[];
  events: ActivityEvent[];
  rentPaid: number;
  /** Pool liquidity by price, scaled to 100 at the deepest point. */
  depth: { price: number; depth: number }[];
  /** False when the log index could not be reached on the last refresh. */
  historySynced: boolean;
  wallet: Wallet | null;
}
