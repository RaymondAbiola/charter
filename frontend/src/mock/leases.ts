import type {
  Address,
  BidInput,
  Lease,
  PriceRange,
  Snapshot,
} from "./types.ts";

export function validateRange(range: PriceRange) {
  if (
    !Number.isFinite(range.lower) ||
    !Number.isFinite(range.upper) ||
    range.lower <= 0 ||
    range.lower >= range.upper
  )
    throw new Error(
      "The lower price must be positive and below the upper price.",
    );
}
function positive(value: number, label: string) {
  if (!Number.isFinite(value) || value <= 0)
    throw new Error(`${label} must be greater than zero.`);
}
export function leaseMethods(
  get: () => Snapshot,
  notify: (
    kind: "BidPlaced" | "Rebalanced" | "LeaseEnded",
    address: Address,
    amount: number,
    detail: string,
  ) => void,
  now: () => number,
) {
  const own = (slot: number, manager: Address): Lease => {
    const lease = get().leases.find((lease) => lease.slot === slot);
    if (!lease || lease.manager !== manager)
      throw new Error("This persona does not manage that lease.");
    return lease;
  };
  return {
    leases(slot: number) {
      return get().leases.find((lease) => lease.slot === slot) ?? null;
    },
    bid(input: BidInput) {
      const state = get();
      const lease = state.leases.find((lease) => lease.slot === input.slot);
      if (!lease) throw new Error("Choose an active slot.");
      positive(input.rentRate, "Rent");
      positive(input.capital, "Capital");
      positive(input.bond, "Bond");
      validateRange(input.range);
      const highest = Math.max(
        lease.rentRate,
        ...state.bids
          .filter((bid) => bid.slot === input.slot)
          .map((bid) => bid.rentRate),
      );
      if (input.rentRate <= highest)
        throw new Error(`Annual rent must exceed ${highest.toFixed(2)}%.`);
      if (input.capital > lease.capital)
        throw new Error("Capital cannot exceed the slot's available capital.");
      if (input.bond < input.capital * 0.05)
        throw new Error(
          "This mock requires a bond of at least 5.00% of capital.",
        );
      state.bids = state.bids.filter((bid) => bid.slot !== input.slot);
      state.bids.push({
        ...structuredClone(input),
        id: `bid-${state.events.length}`,
        takeoverAt: now() + 300000,
      });
      notify(
        "BidPlaced",
        input.manager,
        input.capital,
        `Slot ${input.slot} · ${input.rentRate.toFixed(2)}% annual rent`,
      );
    },
    rebalance(slot: number, range: PriceRange, manager: Address) {
      validateRange(range);
      const lease = own(slot, manager);
      lease.range = { ...range };
      notify(
        "Rebalanced",
        manager,
        lease.capital,
        `Slot ${slot} · $${range.lower} to $${range.upper}`,
      );
    },
    topUpBond(slot: number, amount: number, manager: Address) {
      positive(amount, "Bond top-up");
      const lease = own(slot, manager);
      lease.bond += amount;
      lease.equity += amount;
      // This preview expands the band linearly; it is not the hook's risk calculation.
      lease.liquidation.lower = Math.max(
        1,
        lease.liquidation.lower - (amount / lease.capital) * 1000,
      );
      lease.liquidation.upper += (amount / lease.capital) * 1000;
    },
    exitLease(slot: number, manager: Address) {
      const lease = own(slot, manager);
      get().leases = get().leases.filter((item) => item.slot !== slot);
      get().bids = get().bids.filter((item) => item.slot !== slot);
      notify(
        "LeaseEnded",
        manager,
        lease.capital,
        `Slot ${slot} · capital returned to passive`,
      );
    },
  };
}
