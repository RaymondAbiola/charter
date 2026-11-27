"use client";

import { useEffect, useState } from "react";

export function SnapshotLoading() {
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    const timer = setTimeout(() => setSlow(true), 12000);
    return () => clearTimeout(timer);
  }, []);
  return (
    <section
      className="c-loading"
      aria-label="Live vault snapshot"
      aria-busy="true"
    >
      <div className="c-loading-message" role="status">
        <span className="c-state-instrument" aria-hidden="true" />
        <div>
          <h2>Reading the instruments.</h2>
          <p>
            {slow
              ? "The network is taking longer than usual. Figures appear only after the live snapshot is verified."
              : "Fetching the vault, leases and bond coverage at one block."}
          </p>
        </div>
      </div>
      <div className="c-loading-fields" aria-hidden="true">
        {["TOTAL DEPOSITED", "CAPITAL LEASED", "BOND COVERAGE"].map((label) => (
          <div key={label}>
            <span>{label}</span>
            <b>Awaiting block</b>
            <i />
          </div>
        ))}
      </div>
    </section>
  );
}
