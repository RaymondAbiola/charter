"use client";

import { useMock } from "@/state/provider";
import type { Persona, Scenario } from "@/mock/types";

export function MockControls() {
  const { scenario, setScenario, persona, setPersona } = useMock();
  return (
    <details className="c-mock-tools">
      <summary>Mock controls</summary>
      <div className="mock-controls">
        <label>
          Persona
          <select
            value={persona}
            onChange={(event) => setPersona(event.target.value as Persona)}
          >
            <option value="visitor">Visitor</option>
            <option value="depositor">Depositor</option>
            <option value="manager">Manager</option>
          </select>
        </label>
        <label>
          Data state
          <select
            value={scenario}
            onChange={(event) => setScenario(event.target.value as Scenario)}
          >
            <option value="ready">Seeded data</option>
            <option value="empty">Empty</option>
            <option value="loading">Loading</option>
            <option value="error">Error</option>
          </select>
        </label>
        <p>All balances and actions are local mocks. Reload to reset.</p>
      </div>
    </details>
  );
}
