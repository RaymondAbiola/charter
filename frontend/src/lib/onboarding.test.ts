import test from "node:test";
import assert from "node:assert/strict";
import { estimateSharesForValue } from "./onboarding.ts";

test("value presets preserve native share precision even above safe integer supply", () => {
  const supply = 100_000_000_000_000_000_001n;
  assert.equal(
    estimateSharesForValue(100, supply, 1000),
    10_000_000_000_000_000_000n,
  );
  assert.equal(
    estimateSharesForValue(0.01, supply, 1000),
    1_000_000_000_000_000n,
  );
});
test("unavailable prices, empty vaults and amounts that round to zero offer no estimate", () => {
  for (const total of [0, -1, NaN, Infinity, 1e20])
    assert.equal(estimateSharesForValue(100, 1000n, total), null);
  assert.equal(estimateSharesForValue(100, 0n, 1000), null);
  assert.equal(estimateSharesForValue(0, 1000n, 1000), null);
  assert.equal(estimateSharesForValue(1, 1n, 1000), null);
});
