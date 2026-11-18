"use client";

import { useState, type FormEvent } from "react";
import { useMock } from "./provider";
import { accounts } from "@/mock/seed";
import { mockInputs } from "@/mock/inputs";
import { parseShares } from "@/lib/format";
import type { EventKind, PriceRange, TokenAmounts } from "@/mock/types";

const defaults = mockInputs();

export function useMetrics() {
  const { data, persona } = useMock();
  const total =
    Number(data.amount0) / 1e6 + (Number(data.amount1) / 1e18) * data.price;
  const leased = data.leases.reduce((sum, lease) => sum + lease.capital, 0);
  const rent = leased
    ? data.leases.reduce(
        (sum, lease) => sum + lease.capital * lease.rentRate,
        0,
      ) / leased
    : 0;
  const shares =
    persona === "visitor" ? 0n : (data.balances[accounts[persona]] ?? 0n);
  const worth = (Number(shares) / Number(data.supply)) * total;
  const earned = shares ? data.rentEarned : 0;
  return {
    total,
    leased,
    rent,
    leasedPercent: (leased / total) * 100,
    passive: total - leased,
    shares,
    worth,
    earned,
    owed: worth,
    baseline: worth - earned,
  };
}
function useAction() {
  const { refresh } = useMock();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const run = async (action: () => void, success: string) => {
    setError("");
    setMessage("");
    setPending(true);
    try {
      await new Promise((resolve) => setTimeout(resolve, 300));
      action();
      refresh();
      setMessage(success);
    } catch (error) {
      setError(
        error instanceof Error
          ? error.message
          : "The mock action could not complete.",
      );
    } finally {
      setPending(false);
    }
  };
  return { pending, error, message, run };
}
export function useDepositForm() {
  const { client, persona, scenario } = useMock();
  const action = useAction();
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [input, setInput] = useState(defaults.shares);
  const [slippage, setSlippage] = useState(defaults.slippage);
  let shares = 0n,
    quote: TokenAmounts = [0n, 0n],
    validation = "";
  try {
    shares = parseShares(input);
    quote =
      mode === "deposit"
        ? client.previewDeposit(shares)
        : client.previewWithdraw(shares);
  } catch (error) {
    validation = error instanceof Error ? error.message : "Invalid amount.";
  }
  const submit = (event: FormEvent) => {
    event.preventDefault();
    void action.run(
      () => {
        if (persona === "visitor")
          throw new Error("Connect a mock persona first.");
        if (scenario !== "ready")
          throw new Error("Return to seeded data to try an action.");
        if (validation) throw new Error(validation);
        const slip = Number(slippage);
        if (!Number.isFinite(slip) || slip < 0.1 || slip > 5)
          throw new Error("Set slippage between 0.10% and 5.00%.");
        const bps = BigInt(Math.round(slip * 100));
        if (mode === "deposit")
          client.deposit(
            shares,
            (quote[0] * (10000n + bps) + 9999n) / 10000n,
            (quote[1] * (10000n + bps) + 9999n) / 10000n,
            accounts[persona],
          );
        else
          client.withdraw(
            shares,
            (quote[0] * (10000n - bps)) / 10000n,
            (quote[1] * (10000n - bps)) / 10000n,
            accounts[persona],
          );
      },
      mode === "deposit"
        ? "Mock deposit complete. Your shares and activity are updated."
        : "Mock withdrawal complete. Your shares and activity are updated.",
    );
  };
  return {
    ...action,
    mode,
    setMode,
    input,
    setInput,
    slippage,
    setSlippage,
    shares,
    quote,
    validation,
    submit,
  };
}
export function useBidForm() {
  const { client, persona, scenario } = useMock();
  const action = useAction();
  const [slot, setSlot] = useState(defaults.bid.slot);
  const [rent, setRent] = useState(defaults.bid.rent);
  const [capital, setCapital] = useState(defaults.bid.capital);
  const [bond, setBond] = useState(defaults.bid.bond);
  const [range, setRange] = useState<PriceRange>(defaults.bid.range);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    void action.run(() => {
      if (persona !== "manager")
        throw new Error("Switch the mock wallet to Manager to bid.");
      if (scenario !== "ready")
        throw new Error("Return to seeded data to try an action.");
      client.bid({
        slot: Number(slot),
        rentRate: Number(rent),
        capital: Number(capital),
        bond: Number(bond),
        range,
        manager: accounts.manager,
      });
    }, "Mock bid placed. The five-minute takeover countdown has started.");
  };
  return {
    ...action,
    slot,
    setSlot,
    rent,
    setRent,
    capital,
    setCapital,
    bond,
    setBond,
    range,
    setRange,
    submit,
  };
}
export function useManagerForm() {
  const { client, data, persona, scenario } = useMock();
  const action = useAction();
  const lease = data.leases.find((item) => item.manager === accounts.manager);
  const [range, setRange] = useState<PriceRange>(
    lease?.range ?? defaults.manager.range,
  );
  const [topUp, setTopUp] = useState(defaults.manager.topUp);
  const [confirmExit, setConfirmExit] = useState(false);
  const act = (kind: "rebalance" | "bond" | "exit") => {
    void action.run(
      () => {
        if (persona !== "manager" || !lease)
          throw new Error("Switch to Manager to operate this lease.");
        if (scenario !== "ready")
          throw new Error("Return to seeded data to try an action.");
        if (kind === "rebalance")
          client.rebalance(lease.slot, range, accounts.manager);
        if (kind === "bond")
          client.topUpBond(lease.slot, Number(topUp), accounts.manager);
        if (kind === "exit") {
          client.exitLease(lease.slot, accounts.manager);
          setConfirmExit(false);
        }
      },
      kind === "rebalance"
        ? "Mock range updated."
        : kind === "bond"
          ? "Mock bond topped up. Equity and the illustrative liquidation band are updated."
          : "Mock lease exited. Capital is passive and the activity feed is updated.",
    );
  };
  return {
    ...action,
    lease,
    range,
    setRange,
    topUp,
    setTopUp,
    confirmExit,
    setConfirmExit,
    act,
  };
}
export function useActivity() {
  const { data, persona } = useMock();
  const [kind, setKind] = useState<EventKind | "All">("All");
  const [mine, setMine] = useState(false);
  const events = data.events.filter(
    (event) =>
      (kind === "All" || event.kind === kind) &&
      (!mine || (persona !== "visitor" && event.address === accounts[persona])),
  );
  return { events, kind, setKind, mine, setMine };
}
