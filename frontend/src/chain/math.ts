import { DECIMALS0, DECIMALS1, deployment } from "./deployment.ts";

// Display math in floating point. Anything sent to the chain is checked by the hook itself.

const SCALE = 10 ** (DECIMALS1 - DECIMALS0);
const LOG_BASE = Math.log(1.0001);
export const FULL_TICK =
  Math.floor(887272 / deployment.tickSpacing) * deployment.tickSpacing;

export type Pair = readonly [weth: number, usdc: number];

export const weth = (raw: bigint) => Number(raw) / 10 ** DECIMALS0;
export const usdc = (raw: bigint) => Number(raw) / 10 ** DECIMALS1;
export const usdcRaw = (value: number) =>
  BigInt(Math.round(value * 10 ** DECIMALS1));

export const priceFromSqrtX96 = (sqrtX96: bigint) =>
  (Number(sqrtX96) / 2 ** 96) ** 2 / SCALE;
export const priceAtTick = (tick: number) => 1.0001 ** tick / SCALE;

export function tickAtPrice(
  price: number,
  spacing: number = deployment.tickSpacing,
) {
  const raw = Math.log(price * SCALE) / LOG_BASE;
  const tick = Math.round(raw / spacing) * spacing;
  return Math.max(-FULL_TICK, Math.min(FULL_TICK, tick));
}

export const value = ([a0, a1]: Pair, price: number) => a0 * price + a1;

/** Token amounts for `liquidity` between two ticks at `price`, in whole tokens. */
export function amounts(
  liquidity: number,
  tickLower: number,
  tickUpper: number,
  price: number,
): Pair {
  const sa = Math.sqrt(1.0001 ** tickLower);
  const sb = Math.sqrt(1.0001 ** tickUpper);
  const sp = Math.min(sb, Math.max(sa, Math.sqrt(price * SCALE)));
  const raw0 = liquidity * (1 / sp - 1 / sb);
  const raw1 = liquidity * (sp - sa);
  return [raw0 / 10 ** DECIMALS0, raw1 / 10 ** DECIMALS1];
}

/** What `units` of leased capital are worth at full range, in USDC. */
export const unitsValue = (units: number, price: number) =>
  value(amounts(units, -FULL_TICK, FULL_TICK, price), price);

export const unitsForCapital = (capital: number, price: number) =>
  BigInt(Math.floor(capital / unitsValue(1, price)));

export const sub = (a: Pair, b: Pair): Pair => [a[0] - b[0], a[1] - b[1]];
export const add = (a: Pair, b: Pair): Pair => [a[0] + b[0], a[1] + b[1]];

export interface Book {
  units: number;
  liquidity: number;
  tickLower: number;
  tickUpper: number;
  bond: number;
  rent: number;
  /** Held beyond the range position: idle claims and uncollected fees. */
  extraHeld: Pair;
  /** Owed beyond the full-range units: passive fee debt. */
  extraOwed: Pair;
}

/** The hook's liquidation test: equity less rent, minus the maintenance margin on what is owed. */
export function spare(
  book: Book,
  price: number,
  maintenanceBps: number = deployment.maintenanceBps,
) {
  const held = value(
    add(
      amounts(book.liquidity, book.tickLower, book.tickUpper, price),
      book.extraHeld,
    ),
    price,
  );
  const owed = value(
    add(amounts(book.units, -FULL_TICK, FULL_TICK, price), book.extraOwed),
    price,
  );
  return book.bond - book.rent + held - owed * (1 + maintenanceBps / 10_000);
}

function root(f: (p: number) => number, good: number, bad: number) {
  for (let i = 0; i < 80; i++) {
    const mid = Math.sqrt(good * bad);
    if (f(mid) >= 0) good = mid;
    else bad = mid;
  }
  return Math.sqrt(good * bad);
}

/**
 * Prices at which the lease would be liquidated if fees and rent stood still. A side with no
 * crossing within a 50x move is returned as 0 or Infinity.
 */
export function liquidationBand(book: Book, price: number) {
  const f = (p: number) => spare(book, p);
  if (f(price) < 0) return { lower: price, upper: price };
  const lo = price / 50;
  const hi = price * 50;
  return {
    lower: f(lo) >= 0 ? 0 : root(f, price, lo),
    upper: f(hi) >= 0 ? Infinity : root(f, price, hi),
  };
}
