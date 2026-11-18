import test from "node:test";
import assert from "node:assert/strict";
import { createMockClient, SHARE_UNIT } from "./client.ts";
import { accounts } from "./seed.ts";
import { evidence } from "./evidence.ts";
import { parseShares } from "../lib/format.ts";

test("share previews use token precision and enforce slippage before changing balances", () => {
  const client = createMockClient(1000000);
  const shares = 1000n * SHARE_UNIT;
  const before = client.snapshot();
  const quote = client.previewDeposit(shares);
  assert.equal(quote[0], 624000000n);
  assert.equal(quote[1], 219199600000000000n);
  assert.throws(
    () => client.deposit(shares, quote[0] - 1n, quote[1], accounts.depositor),
    /slippage/,
  );
  assert.deepEqual(client.snapshot(), before);
  client.deposit(shares, ...quote, accounts.depositor);
  assert.equal(
    client.balanceOf(accounts.depositor),
    before.balances[accounts.depositor] + shares,
  );
  assert.equal(client.totalSupply(), before.supply + shares);
  const withdrawal = client.previewWithdraw(shares);
  client.withdraw(shares, ...withdrawal, accounts.depositor);
  assert.equal(client.totalSupply(), before.supply);
  assert.equal(
    client.balanceOf(accounts.depositor),
    before.balances[accounts.depositor],
  );
  assert.equal(client.snapshot().events[0].kind, "Withdraw");
  assert.equal(client.snapshot().events[1].kind, "Deposit");
  assert.throws(
    () => client.withdraw(100000000n * SHARE_UNIT, 0n, 0n, accounts.depositor),
    /enough/,
  );
});

test("bid rules reject a low rate, inadequate bond, excess capital and invalid bounds", () => {
  const client = createMockClient();
  const input = {
    slot: 2,
    rentRate: 6.25,
    capital: 2750000,
    bond: 350000,
    range: { lower: 2600, upper: 3180 },
    manager: accounts.manager,
  };
  assert.throws(() => client.bid({ ...input, rentRate: 6.1 }), /exceed/);
  assert.throws(() => client.bid({ ...input, bond: 1 }), /5.00%/);
  assert.throws(() => client.bid({ ...input, capital: 3000000 }), /available/);
  assert.throws(
    () => client.bid({ ...input, range: { lower: 3200, upper: 2600 } }),
    /lower price/,
  );
  assert.equal(client.snapshot().bids.length, 1);
  client.bid(input);
  assert.equal(client.snapshot().bids.length, 1);
  assert.equal(client.snapshot().bids[0].rentRate, 6.25);
  assert.ok(
    client.snapshot().bids[0].takeoverAt >=
      client.snapshot().startedAt + 300000,
  );
  assert.equal(client.snapshot().events[0].kind, "BidPlaced");
});

test("manager operations enforce ownership and update range, bond, equity and passive capital", () => {
  const client = createMockClient();
  assert.throws(
    () => client.topUpBond(1, 1000, accounts.depositor),
    /does not manage/,
  );
  assert.throws(() => client.topUpBond(1, -1, accounts.manager), /greater/);
  const before = client.leases(1)!;
  const equity = before.equity;
  client.topUpBond(1, 10000, accounts.manager);
  assert.equal(client.leases(1)!.equity, equity + 10000);
  assert.equal(client.leases(1)!.bond, 348400);
  client.rebalance(1, { lower: 2500, upper: 3200 }, accounts.manager);
  assert.deepEqual(client.leases(1)!.range, { lower: 2500, upper: 3200 });
  const passive = client.passiveLiquidity();
  client.exitLease(1, accounts.manager);
  assert.equal(client.leases(1), null);
  assert.ok(client.passiveLiquidity() > passive);
  assert.equal(client.snapshot().events[0].kind, "LeaseEnded");
});

test("the supplied study is exact and remains separate from simulated depth data", () => {
  assert.deepEqual(
    evidence.map((row) => [
      row.startPrice,
      row.endPrice,
      row.days,
      row.returnVsPassive,
      row.skillVsPassive,
    ]),
    [
      [3309, 1651, 553, -12.7, -2.5],
      [3301, 1652, 554, -14.4, -1.2],
      [1656, 3912, 472, -14.1, -2.4],
      [3301, 1652, 555, 12.5, -1.6],
    ],
  );
});

test("share input preserves 18 decimals and rejects exponent notation and invalid precision", () => {
  assert.equal(parseShares("1.000000000000000001"), SHARE_UNIT + 1n);
  for (const value of ["-1", "1e6", "NaN", "0.0000000000000000001", ""])
    assert.throws(() => parseShares(value));
});
