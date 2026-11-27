"use client";

import { useEffect, useState, type FormEvent } from "react";
import { formatUnits } from "viem";
import { useSnapshot } from "./provider";
import { deployment } from "@/chain/deployment";
import {
  tickAtPrice,
  unitsForCapital,
  usdc,
  usdcRaw,
  value,
  weth,
} from "@/chain/math";
import { explain } from "@/chain/wallet";
import { parseShares } from "@/lib/format";
import type { EventKind, PriceRange, TokenAmounts } from "@/chain/types";

const round = (n: number, step = 10) => Math.round(n / step) * step;

export function useMetrics() {
  const { data } = useSnapshot();
  const leased = data.leases.reduce((sum, lease) => sum + lease.capital, 0);
  const rent = leased
    ? data.leases.reduce(
        (sum, lease) => sum + lease.capital * lease.rentRate,
        0,
      ) / leased
    : 0;
  const units = Number(data.passiveUnits + data.leasedUnits);
  const shares = data.wallet?.shares ?? 0n;
  const [r0, r1] = data.wallet?.redeemable ?? [0n, 0n];
  const worth = value([weth(r0), usdc(r1)], data.price);
  // rent is paid into the vault for everyone, so this is a pro-rata estimate at today's holding
  const earned = data.supply
    ? (data.rentPaid * Number(shares)) / Number(data.supply)
    : 0;
  return {
    total: data.total,
    leased,
    rent,
    leasedPercent: units ? (Number(data.leasedUnits) / units) * 100 : 0,
    shares,
    worth,
    earned,
    owed: worth,
    baseline: worth - earned,
  };
}

function useAction() {
  const { refresh } = useSnapshot();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const run = async (action: () => Promise<void>, success: string) => {
    setError("");
    setMessage("");
    setPending(true);
    try {
      await action();
      await refresh();
      setMessage(success);
    } catch (e) {
      setError(explain(e));
    } finally {
      setPending(false);
    }
  };
  return { pending, error, message, run };
}

function need(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}

export function useDepositForm() {
  const { data, account, reader, writer } = useSnapshot();
  const action = useAction();
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [input, setInput] = useState("0.00001");
  const [slippage, setSlippage] = useState("0.50");
  const [priced, setPriced] = useState<{
    mode: "deposit" | "withdraw";
    shares: bigint;
    amounts: TokenAmounts;
    error: string;
  } | null>(null);

  let shares = 0n,
    validation = "";
  try {
    shares = parseShares(input);
  } catch (e) {
    validation = e instanceof Error ? e.message : "Invalid amount.";
  }

  const current =
    priced?.mode === mode && priced.shares === shares ? priced : null;
  const quoteReady = Boolean(shares > 0n && current && !current.error);
  const quoting = Boolean(shares > 0n && !validation && !current);
  const quote: TokenAmounts = quoteReady ? current!.amounts : [0n, 0n];

  useEffect(() => {
    if (!shares) return;
    let live = true;
    const timer = setTimeout(() => {
      reader
        .preview(mode, shares)
        .then((amounts) => {
          if (live) setPriced({ mode, shares, amounts, error: "" });
        })
        .catch(() => {
          if (live)
            setPriced({
              mode,
              shares,
              amounts: [0n, 0n],
              error:
                "Could not price that amount. Try a smaller value or enter LP shares.",
            });
        });
    }, 250);
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [reader, mode, shares, data.block]);

  const switchMode = (next: "deposit" | "withdraw") => {
    setMode(next);
    if (next === "withdraw" && data.wallet?.shares)
      setInput(formatUnits(data.wallet.shares, 18));
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    void action.run(
      async () => {
        need(account && data.wallet, "Connect a wallet first.");
        need(
          !validation && shares > 0n,
          validation || "Enter an amount above zero.",
        );
        const slip = Number(slippage);
        need(
          Number.isFinite(slip) && slip >= 0.1 && slip <= 5,
          "Set slippage between 0.10% and 5.00%.",
        );
        const bps = BigInt(Math.round(slip * 100));
        const wallet = data.wallet;
        if (mode === "deposit") {
          need(
            quoteReady,
            current?.error || "Wait for the token quote before depositing.",
          );
          const max0 = (quote[0] * (10000n + bps) + 9999n) / 10000n;
          const max1 = (quote[1] * (10000n + bps) + 9999n) / 10000n;
          need(
            wallet.weth >= max0 && wallet.usdc >= max1,
            "Not enough test tokens. Use Get test tokens in the header.",
          );
          await writer.approve(
            account,
            deployment.weth,
            max0,
            wallet.allowanceWeth,
          );
          await writer.approve(
            account,
            deployment.usdc,
            max1,
            wallet.allowanceUsdc,
          );
          await writer.deposit(account, shares, max0, max1);
        } else {
          need(shares <= wallet.shares, "You do not hold that many shares.");
          need(
            quoteReady,
            current?.error || "Wait for the token quote before withdrawing.",
          );
          await writer.withdraw(
            account,
            shares,
            (quote[0] * (10000n - bps)) / 10000n,
            (quote[1] * (10000n - bps)) / 10000n,
          );
        }
      },
      mode === "deposit"
        ? "Deposit confirmed. Your shares are minted."
        : "Withdrawal confirmed. The tokens are in your wallet.",
    );
  };
  return {
    ...action,
    mode,
    setMode: switchMode,
    input,
    setInput,
    slippage,
    setSlippage,
    shares,
    quote: shares ? quote : ([0n, 0n] as const),
    quoteReady,
    quoting,
    validation: validation || current?.error || "",
    submit,
  };
}

export function useBidForm() {
  const { data, account, writer } = useSnapshot();
  const action = useAction();
  const open = Array.from({ length: deployment.maxLeases }, (_, i) => i).find(
    (i) => !data.leases.some((l) => l.slot === i),
  );
  const [slotInput, setSlot] = useState<string>("");
  const [rent, setRent] = useState("5.00");
  const [capital, setCapital] = useState("20000");
  const [bond, setBond] = useState("2000");
  const [range, setRange] = useState<PriceRange>(() => ({
    lower: round(data.price * 0.92),
    upper: round(data.price * 1.08),
  }));
  const slot = slotInput === "" ? String(open ?? 0) : slotInput;
  const occupied = data.leases.find((l) => l.slot === Number(slot));
  const pending = data.bids.find((b) => b.slot === Number(slot));
  const beat = Math.max(occupied?.rentRate ?? 0, pending?.rentRate ?? 0);
  const minRent = beat ? beat * (1 + deployment.minRaiseBps / 10_000) : 0;
  const minBond = (Number(capital) || 0) * (deployment.minBondBps / 10_000);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    void action.run(
      async () => {
        need(account && data.wallet, "Connect a wallet to lease capital.");
        const r = Number(rent);
        const c = Number(capital);
        const b = Number(bond);
        need(r > 0 && r <= 100, "Set an annual rent between 0 and 100%.");
        need(c > 0, "Capital must be greater than zero.");
        need(b > 0, "Bond must be greater than zero.");
        const lower = tickAtPrice(range.lower);
        const upper = tickAtPrice(range.upper);
        need(lower < upper, "The lower price must be below the upper price.");
        const bondRaw = usdcRaw(b);
        need(
          data.wallet.usdc >= bondRaw,
          "Not enough tUSDC for the bond. Use Get test tokens in the header.",
        );
        await writer.approve(
          account,
          deployment.usdc,
          bondRaw,
          data.wallet.allowanceUsdc,
        );
        const units = unitsForCapital(c, data.price);
        const pips = Math.round(r * 10_000);
        if (occupied)
          await writer.bid(
            account,
            Number(slot),
            units,
            pips,
            bondRaw,
            lower,
            upper,
          );
        else
          await writer.openLease(
            account,
            Number(slot),
            units,
            pips,
            bondRaw,
            lower,
            upper,
          );
      },
      occupied
        ? "Bid placed. It can take over the slot after the five-minute delay."
        : "Lease opened. Your range is live in the pool.",
    );
  };
  return {
    ...action,
    slot,
    setSlot,
    occupied,
    minRent,
    minBond,
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

export function useTakeover() {
  const { account, writer } = useSnapshot();
  const action = useAction();
  return {
    ...action,
    activate: (slot: number) =>
      action.run(async () => {
        need(account, "Connect a wallet to send the takeover.");
        await writer.activate(account, slot);
      }, "Takeover settled. Check the board for the slot's new terms."),
    cancel: (slot: number) =>
      action.run(async () => {
        need(account, "Connect a wallet first.");
        await writer.cancelBid(account, slot);
      }, "Bid cancelled. The bond is back as claims in the PoolManager."),
  };
}

export function useManagerForm() {
  const { data, account, writer } = useSnapshot();
  const action = useAction();
  const lease = data.leases.find(
    (item) => account && item.manager.toLowerCase() === account.toLowerCase(),
  );
  const [picked, setRange] = useState<PriceRange | null>(null);
  const range =
    picked ??
    (lease
      ? { lower: round(lease.range.lower), upper: round(lease.range.upper) }
      : { lower: round(data.price * 0.92), upper: round(data.price * 1.08) });
  const [topUp, setTopUp] = useState("1000");
  const [confirmExit, setConfirmExit] = useState(false);
  const act = (kind: "rebalance" | "bond" | "exit") => {
    void action.run(
      async () => {
        need(
          account && lease && data.wallet,
          "Connect the wallet that manages this lease.",
        );
        if (kind === "rebalance") {
          const lower = tickAtPrice(range.lower);
          const upper = tickAtPrice(range.upper);
          need(lower < upper, "The lower price must be below the upper price.");
          await writer.rebalance(account, lease.slot, lower, upper);
        }
        if (kind === "bond") {
          const amount = usdcRaw(Number(topUp));
          need(amount > 0n, "Enter a top-up above zero.");
          need(
            data.wallet.usdc >= amount,
            "Not enough tUSDC. Use Get test tokens in the header.",
          );
          await writer.approve(
            account,
            deployment.usdc,
            amount,
            data.wallet.allowanceUsdc,
          );
          await writer.topUpBond(account, lease.slot, amount);
        }
        if (kind === "exit") {
          await writer.exitLease(account, lease.slot);
          setConfirmExit(false);
        }
      },
      kind === "rebalance"
        ? "Range moved. The new position is live."
        : kind === "bond"
          ? "Bond topped up. Equity and the liquidation band are updated."
          : "Lease ended. The capital is back in the passive position.",
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

export function useFaucet() {
  const { account, writer } = useSnapshot();
  const action = useAction();
  return {
    ...action,
    mint: () =>
      action.run(async () => {
        need(account, "Connect a wallet first.");
        await writer.faucet(account);
      }, "Minted 10 tWETH and 50,000 tUSDC to your wallet."),
  };
}

export function useActivity() {
  const { data, account } = useSnapshot();
  const [kind, setKind] = useState<EventKind | "All">("All");
  const [mine, setMine] = useState(false);
  const events = data.events.filter(
    (event) =>
      (kind === "All" || event.kind === kind) &&
      (!mine ||
        (account !== null &&
          event.address.toLowerCase() === account.toLowerCase())),
  );
  return { events, kind, setKind, mine, setMine };
}
