"use client";

import {
  createContext,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { createMockClient, type MockClient } from "@/mock/client";
import { accounts } from "@/mock/seed";
import type { Persona, Scenario, Snapshot } from "@/mock/types";

interface State {
  client: MockClient;
  data: Snapshot;
  persona: Persona;
  scenario: Scenario;
  now: number;
  setPersona: (persona: Persona) => void;
  cyclePersona: () => void;
  setScenario: (scenario: Scenario) => void;
  refresh: () => void;
}
const Context = createContext<State | null>(null);
export function MockProvider({ children }: { children: ReactNode }) {
  const [client] = useState(() => createMockClient());
  const [raw, setRaw] = useState(() => client.snapshot());
  const [persona, setPersona] = useState<Persona>("visitor");
  const [scenario, setScenario] = useState<Scenario>("ready");
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => setElapsed((value) => value + 1000), 1000);
    return () => clearInterval(timer);
  }, []);
  const data =
    scenario === "empty"
      ? {
          ...raw,
          leases: [],
          bids: [],
          events: [],
          balances: { [accounts.depositor]: 0n, [accounts.manager]: 0n },
        }
      : raw;
  return (
    <Context.Provider
      value={{
        client,
        data,
        persona,
        scenario,
        now: raw.startedAt + elapsed,
        setPersona,
        setScenario,
        cyclePersona: () =>
          setPersona((value) =>
            value === "visitor"
              ? "depositor"
              : value === "depositor"
                ? "manager"
                : "visitor",
          ),
        refresh: () => setRaw(client.snapshot()),
      }}
    >
      {children}
    </Context.Provider>
  );
}
export function useMock() {
  const state = useContext(Context);
  if (!state) throw new Error("MockProvider is missing.");
  return state;
}
