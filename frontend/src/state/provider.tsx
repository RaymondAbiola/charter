"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { createReader } from "@/chain/read";
import {
  connect as connectWallet,
  connected,
  createWriter,
  revoke,
} from "@/chain/wallet";
import type { Address, Snapshot } from "@/chain/types";

type Status = "loading" | "ready" | "error";

interface State {
  reader: ReturnType<typeof createReader>;
  writer: ReturnType<typeof createWriter>;
  data: Snapshot | null;
  status: Status;
  account: Address | null;
  now: number;
  connect: () => Promise<void>;
  disconnect: () => Promise<void>;
  connectError: string;
  refresh: () => Promise<void>;
}

const POLL_MS = 6000;
// set when the visitor disconnects, so a reload does not quietly reconnect them
const LEFT = "charter:disconnected";
const remember = (left: boolean) => {
  try {
    if (left) localStorage.setItem(LEFT, "1");
    else localStorage.removeItem(LEFT);
  } catch {
    // private mode or blocked storage: the choice lasts for this page only
  }
};
const hasLeft = () => {
  try {
    return localStorage.getItem(LEFT) === "1";
  } catch {
    return false;
  }
};
const Context = createContext<State | null>(null);

export function ChainProvider({ children }: { children: ReactNode }) {
  const [reader] = useState(() => createReader());
  const [writer] = useState(() => createWriter(reader.client));
  const [data, setData] = useState<Snapshot | null>(null);
  const [status, setStatus] = useState<Status>("loading");
  const [account, setAccount] = useState<Address | null>(null);
  const [connectError, setConnectError] = useState("");
  // only read once a snapshot has loaded on the client, so server and client markup still agree
  const [now, setNow] = useState(() => Date.now());
  // chain time runs ahead of or behind this machine's clock; countdowns follow the chain
  const skew = useRef(0);
  const accountRef = useRef<Address | null>(null);
  const busy = useRef<Promise<void> | null>(null);

  const refresh = useCallback(() => {
    // one read at a time; callers that arrive mid-read wait for it and then read again
    const run = async () => {
      try {
        const snap = await reader.read(accountRef.current);
        skew.current = snap.at - Date.now();
        setData(snap);
        setStatus("ready");
      } catch {
        setStatus((s) => (s === "ready" ? s : "error"));
      }
    };
    const next = (busy.current ?? Promise.resolve()).then(run);
    busy.current = next;
    return next;
  }, [reader]);

  const select = useCallback(
    (next: Address | null) => {
      accountRef.current = next;
      setAccount(next);
      void refresh();
    },
    [refresh],
  );

  useEffect(() => {
    const clock = setInterval(() => setNow(Date.now() + skew.current), 1000);
    const poll = setInterval(() => void refresh(), POLL_MS);
    void (hasLeft() ? Promise.resolve(null) : connected())
      .then((a) => select(a))
      .catch(() => select(null));
    const eth = window.ethereum;
    const onAccounts = (accounts: unknown) => {
      const next = ((accounts as Address[])[0] ?? null) as Address | null;
      if (next && hasLeft()) return;
      select(next);
    };
    eth?.on?.("accountsChanged", onAccounts);
    return () => {
      clearInterval(clock);
      clearInterval(poll);
      eth?.removeListener?.("accountsChanged", onAccounts);
    };
  }, [refresh, select]);

  const connect = async () => {
    setConnectError("");
    try {
      const next = await connectWallet();
      remember(false);
      select(next);
    } catch (error) {
      setConnectError(
        error instanceof Error ? error.message : "The wallet did not connect.",
      );
    }
  };

  const disconnect = async () => {
    setConnectError("");
    remember(true);
    select(null);
    await revoke();
  };

  return (
    <Context.Provider
      value={{
        reader,
        writer,
        data,
        status,
        account,
        now,
        connect,
        disconnect,
        connectError,
        refresh: () => refresh(),
      }}
    >
      {children}
    </Context.Provider>
  );
}

export function useChain() {
  const state = useContext(Context);
  if (!state) throw new Error("ChainProvider is missing.");
  return state;
}

/** For components that only render once the first snapshot has loaded. */
export function useSnapshot() {
  const state = useChain();
  if (!state.data) throw new Error("No snapshot yet.");
  return { ...state, data: state.data };
}
