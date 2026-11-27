import { charterAbi } from "./abi.ts";
import { deployment } from "./deployment.ts";
import { fetchLogs, type DecodedLog } from "./logs.ts";
import { priceAtTick, unitsValue, usdc, value, weth } from "./math.ts";
import type { ActivityEvent, Address, EventKind } from "./types.ts";

export type RawEvent = DecodedLog;

export const fetchEvents = (known: Set<string>) =>
  fetchLogs(charterAbi, deployment.charter, known, deployment.deployBlock);

const ZERO: Address = "0x0000000000000000000000000000000000000000";
const pct = (pips: number) => `${(pips / 10_000).toFixed(2)}% annual rent`;
const slotName = (slot: unknown) => `Slot ${String(slot).padStart(2, "0")}`;
const priceRange = (lo: unknown, hi: unknown) =>
  `$${Math.round(priceAtTick(Number(lo))).toLocaleString("en-US")} to $${Math.round(priceAtTick(Number(hi))).toLocaleString("en-US")}`;

/**
 * Turns hook logs into logbook entries, newest first. Token amounts are valued at today's price.
 */
export function toActivity(raw: RawEvent[], price: number) {
  const units = new Map<number, bigint>();
  const managers = new Map<number, Address>();
  const out: ActivityEvent[] = [];
  let rentPaid = 0;
  const sorted = [...raw].sort((a, b) =>
    a.blockNumber === b.blockNumber
      ? a.logIndex - b.logIndex
      : a.blockNumber < b.blockNumber
        ? -1
        : 1,
  );
  for (const e of sorted) {
    const a = e.args;
    const slot = Number(a.slot ?? 0);
    const who = () => managers.get(slot) ?? ZERO;
    const leaseValue = () => {
      const u = units.get(slot);
      return u === undefined ? null : unitsValue(Number(u), price);
    };
    let entry: [EventKind, Address, number | null, string, bigint?] | null =
      null;
    switch (e.eventName) {
      case "Deposit":
      case "Withdraw": {
        const v = value(
          [weth(a.amount0 as bigint), usdc(a.amount1 as bigint)],
          price,
        );
        const minted = e.eventName === "Deposit";
        entry = [
          e.eventName,
          (minted ? a.to : a.owner) as Address,
          v,
          minted ? "LP shares minted" : "LP shares burned",
          a.shares as bigint,
        ];
        break;
      }
      case "LeaseOpened":
        units.set(slot, a.units as bigint);
        managers.set(slot, a.manager as Address);
        entry = [
          "LeaseOpened",
          a.manager as Address,
          leaseValue(),
          `${slotName(slot)} · ${pct(Number(a.rentPips))} · ${priceRange(a.tickLower, a.tickUpper)}`,
        ];
        break;
      case "BidPlaced":
        entry = [
          "BidPlaced",
          a.bidder as Address,
          unitsValue(Number(a.units), price),
          `${slotName(slot)} · ${pct(Number(a.rentPips))}`,
        ];
        break;
      case "TakenOver":
        entry = [
          "LeaseTakenOver",
          a.to as Address,
          null,
          `${slotName(slot)} · taken over from ${String(a.from).slice(0, 6)}…${String(a.from).slice(-4)}`,
        ];
        break;
      case "Rebalanced":
        entry = [
          "Rebalanced",
          who(),
          leaseValue(),
          `${slotName(slot)} · ${priceRange(a.tickLower, a.tickUpper)}`,
        ];
        break;
      case "RentPaid": {
        const v = usdc(a.amount as bigint);
        rentPaid += v;
        if (v < 0.01) continue;
        entry = [
          "RentPaid",
          who(),
          v,
          `${slotName(slot)} · rent paid to depositors`,
        ];
        break;
      }
      case "BondToppedUp":
        entry = [
          "BondToppedUp",
          who(),
          usdc(a.amount as bigint),
          `${slotName(slot)} · bond added`,
        ];
        break;
      case "Liquidated":
        units.delete(slot);
        entry = [
          "Liquidated",
          a.manager as Address,
          usdc(a.owedValue as bigint),
          Number(a.uncovered)
            ? `${slotName(slot)} · bond used $${usdc(a.bondUsed as bigint).toFixed(2)}, uncovered $${usdc(a.uncovered as bigint).toFixed(2)}`
            : `${slotName(slot)} · bond covered $${usdc(a.bondUsed as bigint).toFixed(2)}; capital returned to passive`,
        ];
        break;
      case "LeaseRecalled":
        entry = [
          "LeaseRecalled",
          who(),
          usdc(a.owedValue as bigint),
          `${slotName(slot)} · capital recalled for a withdrawal`,
        ];
        if (units.has(slot))
          units.set(slot, units.get(slot)! - (a.units as bigint));
        break;
      case "LeaseEnded":
        units.delete(slot);
        entry = [
          "LeaseEnded",
          a.manager as Address,
          usdc(a.owedValue as bigint),
          Number(a.bondUsed)
            ? `${slotName(slot)} · bond used $${usdc(a.bondUsed as bigint).toFixed(2)}; capital returned to passive`
            : `${slotName(slot)} · debt settled; capital returned to passive`,
        ];
        break;
      case "BidRefunded":
        entry = [
          "BidRefunded",
          a.bidder as Address,
          usdc(a.bond as bigint),
          `${slotName(slot)} · escrowed bond returned`,
        ];
        break;
      case "BidVoided":
        entry = [
          "BidVoided",
          a.bidder as Address,
          null,
          `${slotName(slot)} · bid no longer qualified`,
        ];
        break;
      case "Repassivated":
        entry = [
          "Repassivated",
          ZERO,
          null,
          "Idle capital put back into the passive position",
        ];
        break;
    }
    if (!entry) continue;
    const [kind, address, amount, detail, shares] = entry;
    out.push({
      id: `${e.transactionHash}-${e.logIndex}`,
      kind,
      address,
      amount,
      detail,
      shares,
      at: e.at,
      tx: e.transactionHash,
    });
  }
  return { events: out.reverse(), rentPaid };
}
