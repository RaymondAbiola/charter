import test from "node:test";
import assert from "node:assert/strict";
import {
  amounts,
  FULL_TICK,
  liquidationBand,
  priceAtTick,
  priceFromSqrtX96,
  spare,
  tickAtPrice,
  unitsForCapital,
  unitsValue,
  type Book,
} from "./math.ts";

// Seeded testnet state: 1e15 units leased at mid ±900 ticks around 3000 USDC per WETH.
const SQRT = 4339505408813697325335318n;
const price = priceFromSqrtX96(SQRT);

test("prices follow the token order and decimals", () => {
  assert.ok(Math.abs(price - 3000) < 0.01);
  assert.equal(tickAtPrice(3000), -196260);
  assert.ok(Math.abs(priceAtTick(-197100) - 2757.3) < 0.1);
  assert.ok(Math.abs(priceAtTick(-195300) - 3301.06) < 0.1);
  for (const p of [500, 2750, 3000, 9000])
    assert.ok(Math.abs(priceAtTick(tickAtPrice(p)) / p - 1) < 0.004);
});

test("units value matches the hook's leaseAccount", () => {
  // owedValue 109,544.651776 less fee debt; the hook rounds the full-range amounts down
  assert.ok(Math.abs(unitsValue(1e15, price) - 109_544.517) < 0.01);
  const units = unitsForCapital(109_544.517, price);
  assert.ok(units > 999_999_000_000_000n && units <= 1_000_000_000_000_000n);
});

test("range amounts are one-sided outside the range", () => {
  const [below0, below1] = amounts(1e16, -197100, -195300, 2000);
  assert.ok(below0 > 0 && below1 === 0);
  const [above0, above1] = amounts(1e16, -197100, -195300, 5000);
  assert.ok(above0 === 0 && above1 > 0);
  const [full0, full1] = amounts(1e15, -FULL_TICK, FULL_TICK, price);
  assert.ok(Math.abs((full0 * price) / full1 - 1) < 1e-6);
});

test("the liquidation band brackets the price and sits on zero spare equity", () => {
  const book: Book = {
    units: 1e15,
    liquidity: 21417905831098274,
    tickLower: -197100,
    tickUpper: -195300,
    bond: 10_954.45,
    rent: 0,
    extraHeld: [0, 0],
    extraOwed: [0, 0],
  };
  const band = liquidationBand(book, price);
  assert.ok(band.lower > 0 && band.lower < price && band.upper > price);
  assert.ok(Math.abs(spare(book, band.lower)) < 1e-3);
  assert.ok(Math.abs(spare(book, band.upper)) < 1e-3);

  // idle tokens held by the lease cushion the downside
  const cushioned = liquidationBand({ ...book, extraHeld: [0, 6319] }, price);
  assert.ok(cushioned.lower < band.lower && cushioned.upper > band.upper);

  const broke = liquidationBand({ ...book, bond: 0, rent: 5000 }, price);
  assert.deepEqual(broke, { lower: price, upper: price });
});
