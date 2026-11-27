import test from "node:test";
import assert from "node:assert/strict";
import { bound, parseShares } from "./format.ts";

test("share input parses to 18 decimals and rejects junk", () => {
  assert.equal(parseShares("0.00001"), 10_000_000_000_000n);
  assert.equal(parseShares("2"), 2n * 10n ** 18n);
  assert.throws(() => parseShares("-1"));
  assert.throws(() => parseShares("1.2.3"));
});

test("liquidation bounds out of reach read as none", () => {
  assert.equal(bound(0), "None in reach");
  assert.equal(bound(Infinity), "None in reach");
  assert.equal(bound(3718.6), "$3,718.60");
});
