import { seed, SHARE_UNIT } from "./seed.ts";
import { leaseMethods } from "./leases.ts";
import type {
  ActivityEvent,
  Address,
  Bundle,
  Snapshot,
  TokenAmounts,
  VaultReads,
  VaultWrites,
} from "./types.ts";

export function createMockClient(now?: number) {
  const state = seed(now);
  const initializedAt = performance.now();
  const clock = () =>
    state.startedAt + Math.floor(performance.now() - initializedAt);
  const addEvent = (
    kind: ActivityEvent["kind"],
    address: Address,
    amount: number,
    detail: string,
    shares?: bigint,
  ) => {
    state.events.unshift({
      id: `event-${state.events.length + 1}`,
      kind,
      address,
      amount,
      detail,
      shares,
      at: clock(),
    });
  };
  const quote = (shares: bigint, roundUp: boolean): TokenAmounts => {
    if (shares < 0n) throw new Error("Shares cannot be negative.");
    if (!state.supply) return [0n, 0n];
    const portion = (amount: bigint) =>
      (amount * shares + (roundUp ? state.supply - 1n : 0n)) / state.supply;
    return [portion(state.amount0), portion(state.amount1)];
  };
  const reads: VaultReads = {
    previewDeposit: (shares) => quote(shares, true),
    previewWithdraw: (shares) => quote(shares, false),
    bundle: (): Bundle => [state.supply, state.amount0, state.amount1],
    totalSupply: () => state.supply,
    balanceOf: (address) => state.balances[address] ?? 0n,
    passiveLiquidity: () => {
      const total =
        Number(state.amount0) / 1e6 +
        (Number(state.amount1) / 1e18) * state.price;
      const leased = state.leases.reduce(
        (sum, lease) => sum + lease.capital,
        0,
      );
      return (
        (state.supply * BigInt(Math.round(((total - leased) / total) * 1e6))) /
        1000000n
      );
    },
    settlementSqrtPrice: () =>
      BigInt(Math.floor(Math.sqrt(1e12 / state.price) * 2 ** 96)),
  };
  const writes: VaultWrites = {
    deposit(shares, max0, max1, to) {
      if (shares <= 0n) throw new Error("Enter a share amount above zero.");
      const [a0, a1] = quote(shares, true);
      if (a0 > max0 || a1 > max1)
        throw new Error("The deposit exceeds your slippage limits.");
      state.amount0 += a0;
      state.amount1 += a1;
      state.supply += shares;
      state.balances[to] = (state.balances[to] ?? 0n) + shares;
      addEvent(
        "Deposit",
        to,
        Number(a0) / 1e6 + (Number(a1) / 1e18) * state.price,
        "LP shares minted",
        shares,
      );
      return [a0, a1];
    },
    withdraw(shares, min0, min1, to) {
      if (shares <= 0n) throw new Error("Enter a share amount above zero.");
      if (shares > (state.balances[to] ?? 0n))
        throw new Error("You do not have enough Charter shares.");
      const [a0, a1] = quote(shares, false);
      if (a0 < min0 || a1 < min1)
        throw new Error("The withdrawal is below your slippage limits.");
      const total =
        Number(state.amount0) / 1e6 +
        (Number(state.amount1) / 1e18) * state.price;
      const passive =
        total - state.leases.reduce((sum, lease) => sum + lease.capital, 0);
      if (Number(a0) / 1e6 + (Number(a1) / 1e18) * state.price > passive)
        throw new Error(
          "This mock can only withdraw capital currently in the passive position.",
        );
      state.amount0 -= a0;
      state.amount1 -= a1;
      state.supply -= shares;
      state.balances[to] -= shares;
      addEvent(
        "Withdraw",
        to,
        Number(a0) / 1e6 + (Number(a1) / 1e18) * state.price,
        "LP shares burned",
        shares,
      );
      return [a0, a1];
    },
  };
  return {
    ...reads,
    ...writes,
    ...leaseMethods(() => state, addEvent, clock),
    snapshot: (): Snapshot => structuredClone(state),
  };
}
export type MockClient = ReturnType<typeof createMockClient>;
export { SHARE_UNIT };
