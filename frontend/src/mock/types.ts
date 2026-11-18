export type Address = `0x${string}`;
export type TokenAmounts = readonly [amount0: bigint, amount1: bigint];
export type Bundle = readonly [
  liquidity: bigint,
  amount0: bigint,
  amount1: bigint,
];
export type Persona = "visitor" | "depositor" | "manager";
export type Scenario = "ready" | "loading" | "empty" | "error";
export type EventKind =
  | "Deposit"
  | "Withdraw"
  | "LeaseOpened"
  | "BidPlaced"
  | "LeaseTakenOver"
  | "Rebalanced"
  | "Liquidated"
  | "LeaseEnded";
export interface PriceRange {
  lower: number;
  upper: number;
}
export interface Lease {
  slot: number;
  manager: Address;
  rentRate: number;
  capital: number;
  bond: number;
  equity: number;
  debt: number;
  range: PriceRange;
  liquidation: PriceRange;
  openedAt: number;
}
export interface Bid {
  id: string;
  slot: number;
  manager: Address;
  rentRate: number;
  capital: number;
  bond: number;
  range: PriceRange;
  takeoverAt: number;
}
export interface ActivityEvent {
  id: string;
  kind: EventKind;
  address: Address;
  amount: number;
  shares?: bigint;
  at: number;
  detail: string;
}
export interface EvidenceRow {
  vault: string;
  startPrice: number;
  endPrice: number;
  days: number;
  returnVsPassive: number;
  skillVsPassive: number;
}
export interface Snapshot {
  startedAt: number;
  price: number;
  supply: bigint;
  balances: Record<Address, bigint>;
  amount0: bigint;
  amount1: bigint;
  leases: Lease[];
  bids: Bid[];
  events: ActivityEvent[];
  rentEarned: number;
}
export interface BidInput {
  slot: number;
  rentRate: number;
  capital: number;
  bond: number;
  range: PriceRange;
  manager: Address;
}
export interface VaultReads {
  previewDeposit(shares: bigint): TokenAmounts;
  previewWithdraw(shares: bigint): TokenAmounts;
  bundle(): Bundle;
  totalSupply(): bigint;
  balanceOf(address: Address): bigint;
  passiveLiquidity(): bigint;
  settlementSqrtPrice(): bigint;
}
export interface VaultWrites {
  deposit(
    shares: bigint,
    max0: bigint,
    max1: bigint,
    to: Address,
  ): TokenAmounts;
  withdraw(
    shares: bigint,
    min0: bigint,
    min1: bigint,
    to: Address,
  ): TokenAmounts;
}
