"use client";

import Link from "next/link";
import {
  Area,
  ComposedChart,
  CartesianGrid,
  ReferenceArea,
  ReferenceLine,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { Screen } from "@/lib/screens";
import { NetworkPanel } from "./network";
import { useChain, useSnapshot } from "@/state/provider";
import {
  useActivity,
  useBidForm,
  useDepositForm,
  useManagerForm,
  useMetrics,
  useTakeover,
} from "@/state/models";
import { deployment } from "@/chain/deployment";
import { evidence, evidenceNote, evidenceSource } from "@/data/evidence";
import {
  address,
  bound,
  coverage,
  health,
  held,
  humanTime,
  LIQUIDATION,
  money,
  percent,
  token,
} from "@/lib/format";
import type { PriceRange } from "@/chain/types";

const WAITING = "Waiting for wallet and block...";

const pages: [Screen, string, string][] = [
  ["overview", "Overview", "01"],
  ["deposit", "Your capital", "02"],
  ["leases", "Lease board", "03"],
  ["manager", "Manager station", "04"],
  ["activity", "Logbook", "05"],
];
export function Charter({ screen }: { screen: Screen }) {
  const { status, account, connect, connectError, data, refresh } = useChain();
  return (
    <div className="nautical">
      <a className="c-skip" href="#charter-main">
        Skip to content
      </a>
      <aside className="c-sidebar">
        <Link href="/" className="c-brand">
          <span className="c-monogram" aria-hidden="true">
            C
          </span>
          Charter<span className="c-brand-sub">Capital, under contract.</span>
        </Link>
        <div className="c-pool">
          <p>POOL / 001</p>
          <strong>
            tWETH
            <br />
            <span>/ tUSDC</span>
          </strong>
          <small>UNISWAP V4 · 0.30% · UNICHAIN SEPOLIA</small>
        </div>
        <nav aria-label="Charter screens">
          {pages.map(([key, label, index]) => (
            <Link
              key={key}
              href={key === "overview" ? "/" : `/${key}`}
              aria-current={key === screen ? "page" : undefined}
            >
              <span>{index}</span>
              {label}
              <b aria-hidden="true">↗</b>
            </Link>
          ))}
        </nav>
        <div className="c-sidebar-foot">
          <span className="c-dot" />
          UNICHAIN SEPOLIA
          <p>
            Test tokens only.
            <br />
            No real capital at risk.
          </p>
        </div>
      </aside>
      <div className="c-body">
        <header className="c-header">
          <span>CHARTER / OPERATIONS</span>
          <p>
            tWETH / tUSDC <b>● LIVE</b>
          </p>
          <button
            onClick={() => void connect()}
            title={connectError || account || "Connect a browser wallet"}
          >
            {account ? address(account) : "Connect wallet"}{" "}
            <span aria-hidden="true">↗</span>
          </button>
        </header>
        <main id="charter-main" className="c-main">
          <div className="c-heading">
            <div>
              <p className="c-eyebrow">
                {pages.find(([key]) => key === screen)?.[2]} / THE CAPITAL DESK
              </p>
              <h1>{pages.find(([key]) => key === screen)?.[1]}</h1>
            </div>
            <span>
              USDC DENOMINATED
              <br />
              {data ? `BLOCK ${data.block.toLocaleString("en-US")}` : "LIVE"}
            </span>
          </div>
          {connectError && (
            <p className="c-error" role="alert">
              {connectError}
            </p>
          )}
          {status === "loading" || (!data && status !== "error") ? (
            <section className="c-state" role="status">
              <div className="c-state-instrument" />
              <h2>Reading the instruments.</h2>
              <p>Waiting for the vault on Unichain Sepolia.</p>
            </section>
          ) : !data ? (
            <section className="c-state" role="alert">
              <h2>Chain signal unavailable.</h2>
              <p>The RPC did not answer. Retry to read the vault again.</p>
              <button className="c-primary" onClick={() => void refresh()}>
                Retry read →
              </button>
            </section>
          ) : screen === "overview" ? (
            <Overview />
          ) : screen === "deposit" ? (
            <Deposit />
          ) : screen === "leases" ? (
            <Leases />
          ) : screen === "manager" ? (
            <Manager />
          ) : (
            <Activity />
          )}
          <footer className="c-footer">
            <span>UHI-11 / UNISWAP V4</span>
            <p>
              Live on Unichain Sepolia with test tokens. The study figures are
              historical observations.
            </p>
            {data && <NetworkPanel />}
          </footer>
        </main>
      </div>
    </div>
  );
}
function Gauge({ ratio, label }: { ratio: number; label: string }) {
  const p = Math.max(0, Math.min(1, (ratio - 100) / 15));
  const color =
    ratio < LIQUIDATION + 2
      ? "#eda58b"
      : ratio < LIQUIDATION + 5
        ? "#d8b878"
        : "#9bc4b3";
  return (
    <figure
      className="c-gauge"
      aria-label={`${label}: ${percent(ratio)} equity versus amount owed. Liquidation threshold ${LIQUIDATION} percent.`}
    >
      <svg viewBox="0 0 240 150" role="img">
        <title>{`${label} ${percent(ratio)}`}</title>
        <path
          d="M30 120 A90 90 0 0 1 210 120"
          fill="none"
          stroke="#3a5262"
          strokeWidth="8"
        />
        <path
          d="M30 120 A90 90 0 0 1 210 120"
          fill="none"
          stroke={color}
          strokeWidth="8"
          pathLength="100"
          strokeDasharray={`${p * 100} 100`}
        />
        {[0, 1, 2, 3, 4, 5].map((i) => {
          const angle = Math.PI - (i * Math.PI) / 5;
          return (
            <line
              key={i}
              x1={120 + 104 * Math.cos(angle)}
              x2={120 + 110 * Math.cos(angle)}
              y1={120 - 104 * Math.sin(angle)}
              y2={120 - 110 * Math.sin(angle)}
              stroke="#a1acb3"
            />
          );
        })}
        <text
          x="120"
          y="103"
          textAnchor="middle"
          fill="#ede4d1"
          fontSize="29"
          fontFamily="var(--font-mono),monospace"
        >
          {percent(ratio)}
        </text>
        <text
          x="120"
          y="128"
          textAnchor="middle"
          fill="#a8b6bf"
          fontSize="9"
          letterSpacing="1"
        >
          EQUITY / OWED
        </text>
      </svg>
      <figcaption>
        <span>{LIQUIDATION}% / LIQUIDATION</span>
        <span>115%</span>
      </figcaption>
    </figure>
  );
}
function Overview() {
  const { data } = useSnapshot();
  const m = useMetrics();
  return (
    <>
      <section className="c-overview-instruments">
        <div className="c-capital">
          <p className="c-eyebrow">TOTAL DEPOSITED / USDC + WETH</p>
          <strong title={money(m.total)}>{money(m.total, true)}</strong>
          <p>
            Managers pay rent to run your liquidity.
            <br />
            You are owed what passive would have earned.
          </p>
          <div className="c-capital-split">
            <span style={{ width: `${m.leasedPercent}%` }} />
            <i />
          </div>
          <div className="c-split-labels">
            <span>
              LEASED <b>{percent(m.leasedPercent)}</b>
            </span>
            <span>
              PASSIVE <b>{percent(100 - m.leasedPercent)}</b>
            </span>
          </div>
          <div className="c-small-stats">
            <div>
              <p>AVG. ANNUAL RENT</p>
              <b>{percent(m.rent)}</b>
            </div>
            <div>
              <p>ACTIVE LEASES</p>
              <b>0{data.leases.length}</b>
            </div>
          </div>
        </div>
        <section className="c-surveillance">
          <div className="c-panel-heading">
            <h2>Bond watch</h2>
            <span>AFTER EVERY SWAP</span>
          </div>
          {data.leases.length ? (
            <div className="c-gauge-row">
              {data.leases.map((lease) => (
                <div key={lease.slot}>
                  <p>
                    SLOT 0{lease.slot}{" "}
                    <span
                      className={health(lease) === "At risk" ? "c-risk" : ""}
                    >
                      {health(lease)}
                    </span>
                  </p>
                  <Gauge
                    ratio={coverage(lease)}
                    label={`Slot ${lease.slot} bond coverage`}
                  />
                  <span className="c-bond-label" title={money(lease.bond)}>
                    {money(lease.bond, true)} bond left
                  </span>
                </div>
              ))}
            </div>
          ) : (
            <div className="c-empty">No active leases. Capital is passive.</div>
          )}
          <Link href="/leases">
            Inspect the lease board <span aria-hidden="true">↗</span>
          </Link>
        </section>
      </section>
      <section className="c-contract">
        <p className="c-eyebrow">THE CONTRACT, IN PRACTICE</p>
        <ol>
          <li>
            <span>01</span>
            <p>
              <b>Supply the capital.</b> Deposit for LP shares. Unleased capital
              stays in a real passive full-range position.
            </p>
          </li>
          <li>
            <span>02</span>
            <p>
              <b>Rent out the range.</b> Managers bid rent and post a bond. They
              keep returns above the passive result and rent owed.
            </p>
          </li>
          <li>
            <span>03</span>
            <p>
              <b>Return it whole.</b> The hook checks each swap. A low bond
              liquidates the manager in that swap and returns capital to
              passive.
            </p>
          </li>
        </ol>
      </section>
      <section className="c-research">
        <div className="c-panel-heading">
          <div>
            <p className="c-eyebrow">REFERENCE OBSERVATIONS / V3</p>
            <h2>Know what you are measuring.</h2>
          </div>
          <span>04 VAULTS / MAINNET</span>
        </div>
        <div className="c-research-body">
          <figure>
            <div className="c-evidence-chart">
              <ResponsiveContainer width="100%" height={276}>
                <ScatterChart
                  margin={{ top: 20, left: 0, right: 20, bottom: 0 }}
                >
                  <CartesianGrid stroke="#304b5b" horizontal={false} />
                  <XAxis
                    dataKey="x"
                    type="number"
                    domain={[-16, 16]}
                    ticks={[-15, -10, -5, 0, 5, 10, 15]}
                    tickFormatter={(v) => `${v}%`}
                    tick={{ fill: "#b6c2c8", fontSize: 10 }}
                    axisLine={false}
                    tickLine={false}
                  />
                  <YAxis
                    dataKey="y"
                    type="number"
                    domain={[0.5, 4.5]}
                    ticks={[1, 2, 3, 4]}
                    reversed
                    tickFormatter={(n) =>
                      ["Charm Alpha", "G-UNI", "0x381e", "0x5763"][n - 1]
                    }
                    tick={{ fill: "#c8d2d5", fontSize: 10 }}
                    width={78}
                    axisLine={false}
                    tickLine={false}
                  />
                  <ReferenceLine x={0} stroke="#82909c" />
                  <Tooltip
                    contentStyle={{
                      background: "#183244",
                      border: "1px solid #6e8390",
                      color: "#ede4d1",
                    }}
                    formatter={(value, name) =>
                      name === "x"
                        ? [`${value}%`, "vs passive"]
                        : [value, "Vault row"]
                    }
                  />
                  <Scatter
                    name="Return vs passive"
                    data={evidence.map((row, i) => ({
                      x: row.returnVsPassive,
                      y: i + 1,
                    }))}
                    fill="#d8b878"
                    shape="diamond"
                    isAnimationActive={false}
                  />
                  <Scatter
                    name="Market-making skill"
                    data={evidence.map((row, i) => ({
                      x: row.skillVsPassive,
                      y: i + 1,
                    }))}
                    fill="#9eb4bf"
                    isAnimationActive={false}
                  />
                </ScatterChart>
              </ResponsiveContainer>
            </div>
            <figcaption>
              <span>◆ Return vs passive</span>
              <span>● Market-making skill</span>
              <p>
                Full-period observations. No historical time series is implied.
              </p>
            </figcaption>
          </figure>
          <div>
            <p className="c-research-note">{evidenceNote}</p>
            <div
              className="c-table-wrap"
              tabIndex={0}
              role="region"
              aria-label="Scrollable vault data table"
            >
              <table>
                <thead>
                  <tr>
                    <th>Vault / ETH period</th>
                    <th>Days</th>
                    <th>Return</th>
                    <th>Skill</th>
                  </tr>
                </thead>
                <tbody>
                  {evidence.map((row) => (
                    <tr key={row.vault}>
                      <td>
                        {row.vault}
                        <small>
                          {money(row.startPrice)} to {money(row.endPrice)}
                        </small>
                      </td>
                      <td>{row.days}</td>
                      <td>
                        {row.returnVsPassive > 0 ? "+" : ""}
                        {percent(row.returnVsPassive)}
                      </td>
                      <td>{percent(row.skillVsPassive)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
        <p className="c-source">{evidenceSource}</p>
      </section>
    </>
  );
}
function Range({
  range,
  onChange,
  liquidation,
}: {
  range: PriceRange;
  onChange?: (range: PriceRange) => void;
  liquidation?: PriceRange;
}) {
  const { data } = useSnapshot();
  const lo = Math.round((data.price * 0.7) / 10) * 10;
  const hi = Math.round((data.price * 1.3) / 10) * 10;
  const marks = liquidation
    ? [liquidation.lower, liquidation.upper].filter(
        (p) => p > 0 && Number.isFinite(p),
      )
    : [];
  return (
    <div className="c-range">
      <div className="c-panel-heading">
        <h2>Range chart</h2>
        <span>{money(data.price)} / SPOT</span>
      </div>
      <div
        className="c-chart-paper"
        role="img"
        aria-label={`Selected price range ${range.lower} to ${range.upper}. Current price ${Math.round(data.price)}.${liquidation ? ` Liquidation bounds ${bound(liquidation.lower)} and ${bound(liquidation.upper)}.` : ""}`}
      >
        <ResponsiveContainer width="100%" height={240}>
          <ComposedChart
            data={data.depth}
            margin={{ top: 24, right: 16, left: 0, bottom: 8 }}
          >
            <CartesianGrid stroke="#49616c" strokeOpacity={0.6} />
            <XAxis
              dataKey="price"
              type="number"
              domain={[lo, hi]}
              tickFormatter={(v) => Math.round(v).toLocaleString("en-US")}
              tick={{ fill: "#c8d2d5", fontSize: 10 }}
              tickLine={false}
              axisLine={false}
            />
            <YAxis hide />
            <ReferenceArea
              x1={range.lower}
              x2={range.upper}
              fill="#d8b878"
              fillOpacity={0.1}
              stroke="#d8b878"
            />
            <Area
              type="linear"
              dataKey="depth"
              fill="#7a9cac"
              fillOpacity={0.15}
              stroke="#93b3c1"
              strokeWidth={1}
              isAnimationActive={false}
            />
            <ReferenceLine
              x={data.price}
              stroke="#f2e6d0"
              strokeDasharray="5 3"
              label={{
                value: "SPOT",
                fill: "#f2e6d0",
                fontSize: 9,
                position: "insideTopRight",
              }}
            />
            {marks.map((p) => (
              <ReferenceLine
                key={p}
                x={p}
                stroke="#eda58b"
                strokeDasharray="2 3"
              />
            ))}
          </ComposedChart>
        </ResponsiveContainer>
      </div>
      {onChange && (
        <div className="c-range-bounds">
          <label>
            LOWER / USDC<b>{money(range.lower)}</b>
            <input
              type="range"
              aria-label="Lower price"
              min={lo}
              max={hi - 10}
              step="10"
              value={range.lower}
              onChange={(e) =>
                onChange({
                  ...range,
                  lower: Math.min(Number(e.target.value), range.upper - 10),
                })
              }
            />
          </label>
          <label>
            UPPER / USDC<b>{money(range.upper)}</b>
            <input
              type="range"
              aria-label="Upper price"
              min={lo + 10}
              max={hi}
              step="10"
              value={range.upper}
              onChange={(e) =>
                onChange({
                  ...range,
                  upper: Math.max(Number(e.target.value), range.lower + 10),
                })
              }
            />
          </label>
        </div>
      )}
      <p className="c-source">
        Pool liquidity by price, from the pool&apos;s own events. Prices in USDC
        per WETH, snapped to 60-tick spacing on submit.{" "}
        {liquidation && "Coral lines mark estimated liquidation prices."}
      </p>
    </div>
  );
}
function Deposit() {
  const form = useDepositForm();
  const m = useMetrics();
  const { account, data } = useSnapshot();
  const w = data.wallet;
  return (
    <div className="c-capital-layout">
      <section className="c-position">
        <p className="c-eyebrow">YOUR SHARE OF THE VAULT</p>
        <h2>{money(m.worth)}</h2>
        <p>Position value / USD</p>
        <dl>
          <div>
            <dt>Charter LP shares</dt>
            <dd>{token(m.shares, 18, 8)}</dd>
          </div>
          <div>
            <dt>Owed: passive + rent</dt>
            <dd>{money(m.owed)}</dd>
          </div>
          <div>
            <dt>Passive component</dt>
            <dd>{money(m.baseline)}</dd>
          </div>
          <div title="Your pro-rata share of all rent paid into the vault, at your current holding">
            <dt>Rent earned to date</dt>
            <dd className="c-brass">{money(m.earned)}</dd>
          </div>
        </dl>
        <div className="c-contract-note">
          <span>01 / CAPITAL OBLIGATION</span>
          <p>
            Managers must return the passive result plus rent. Their bond covers
            any shortfall. Your LP shares represent a proportional vault
            interest.
          </p>
        </div>
      </section>
      <section className="c-transfer">
        <div className="c-segment">
          {(["deposit", "withdraw"] as const).map((mode) => (
            <button
              key={mode}
              aria-pressed={form.mode === mode}
              onClick={() => form.setMode(mode)}
            >
              {mode === "deposit" ? "Supply capital" : "Withdraw"}
            </button>
          ))}
        </div>
        <form onSubmit={form.submit}>
          <label>
            CHARTER LP SHARES
            <input
              name="shares"
              inputMode="decimal"
              value={form.input}
              onChange={(e) => form.setInput(e.target.value)}
            />
          </label>
          <div className="c-token-preview">
            <p>
              {form.mode === "deposit" ? "TOKENS REQUIRED" : "TOKENS RETURNED"}{" "}
              <span>LIVE PREVIEW</span>
            </p>
            <div>
              <span className="c-token-symbol">E</span>
              <span>
                tWETH<small>Token 0</small>
              </span>
              <strong>{token(form.quote[0], 18)}</strong>
            </div>
            <div>
              <span className="c-token-symbol">U</span>
              <span>
                tUSDC<small>Token 1</small>
              </span>
              <strong>{token(form.quote[1], 6)}</strong>
            </div>
          </div>
          <label>
            SLIPPAGE TOLERANCE (%)
            <input
              name="slippage"
              type="number"
              min="0.1"
              max="5"
              step="0.1"
              value={form.slippage}
              onChange={(e) => form.setSlippage(e.target.value)}
            />
          </label>
          <p className="c-small">
            {account && w
              ? `Wallet: ${token(w.weth, 18, 4)} tWETH · ${token(w.usdc, 6, 2)} tUSDC. Slippage sets maximum token inputs or minimum token outputs.`
              : "Connect a wallet to deposit. Reading works without one."}
          </p>
          {(form.error || form.validation) && (
            <p className="c-error" role="alert">
              {form.error || form.validation}
            </p>
          )}
          <p role="status" className="c-feedback">
            {form.message}
          </p>
          <button className="c-primary" disabled={form.pending || !account}>
            {form.pending
              ? WAITING
              : form.mode === "deposit"
                ? "Supply capital →"
                : "Withdraw shares →"}
          </button>
        </form>
      </section>
    </div>
  );
}
function Leases() {
  const { data, now, account } = useSnapshot();
  const form = useBidForm();
  const takeover = useTakeover();
  return (
    <>
      <section className="c-lease-register">
        <div className="c-panel-heading">
          <h2>Under active charter</h2>
          <span>
            {data.leases.length} LEASED / {data.bids.length} PENDING
          </span>
        </div>
        {data.leases.length ? (
          <div
            className="c-table-wrap"
            tabIndex={0}
            role="region"
            aria-label="Scrollable vault data table"
          >
            <table>
              <thead>
                <tr>
                  {[
                    "Slot / Manager",
                    "Annual rent",
                    "Capital",
                    "Bond left",
                    "Equity / owed",
                    "Price range",
                    "Held",
                  ].map((label) => (
                    <th key={label}>{label}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {data.leases.map((lease) => (
                  <tr key={lease.slot}>
                    <td>
                      <span className="c-slot">0{lease.slot}</span>
                      <b title={lease.manager}>{address(lease.manager)}</b>
                    </td>
                    <td>{percent(lease.rentRate)}</td>
                    <td title={money(lease.capital)}>
                      {money(lease.capital, true)}
                    </td>
                    <td>{money(lease.bond)}</td>
                    <td>
                      <span
                        className={
                          health(lease) === "At risk" ? "c-risk" : "c-brass"
                        }
                      >
                        {percent(coverage(lease))} / {health(lease)}
                      </span>
                      <div className="c-coverage-track">
                        <span
                          style={{
                            width: `${Math.min(100, ((coverage(lease) - 100) / 15) * 100)}%`,
                          }}
                        />
                      </div>
                      <small>
                        {money(lease.equity)} / {money(lease.debt)}
                      </small>
                    </td>
                    <td>
                      {money(lease.range.lower)}
                      <small>to {money(lease.range.upper)}</small>
                    </td>
                    <td>{held(now - lease.openedAt)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="c-empty">
            <h3>No capital is leased.</h3>
            <p>It remains in the passive full-range position.</p>
          </div>
        )}
      </section>
      {data.bids.map((bid) => (
        <div className="c-takeover" key={bid.slot}>
          <div>
            <span className="c-eyebrow">
              TAKEOVER NOTICE / SLOT 0{bid.slot}
            </span>
            <p>
              <b title={bid.manager}>{address(bid.manager)}</b> offers{" "}
              <b>{percent(bid.rentRate)}</b> annual rent on{" "}
              {money(bid.capital, true)} with a {money(bid.bond, true)} bond.
            </p>
            {bid.takeoverAt <= now && (
              <>
                <button
                  className="c-outline"
                  disabled={takeover.pending || !account}
                  onClick={() => void takeover.activate(bid.slot)}
                >
                  {takeover.pending ? WAITING : "Activate takeover →"}
                </button>{" "}
                {account?.toLowerCase() === bid.manager.toLowerCase() && (
                  <button
                    className="c-text-button"
                    disabled={takeover.pending}
                    onClick={() => void takeover.cancel(bid.slot)}
                  >
                    Cancel bid
                  </button>
                )}
              </>
            )}
          </div>
          <strong>
            {bid.takeoverAt > now
              ? `${String(Math.floor((bid.takeoverAt - now) / 60000)).padStart(2, "0")}:${String(Math.floor((bid.takeoverAt - now) / 1000) % 60).padStart(2, "0")}`
              : "READY"}
            <small>UNTIL TAKEOVER</small>
          </strong>
        </div>
      ))}
      {takeover.error && (
        <p role="alert" className="c-error">
          {takeover.error}
        </p>
      )}
      {takeover.message && (
        <p role="status" className="c-feedback">
          {takeover.message}
        </p>
      )}
      <div className="c-auction-layout">
        <section className="c-bid-form">
          <div className="c-panel-heading">
            <h2>Make a rental offer</h2>
            <span>FIVE-MINUTE DELAY</span>
          </div>
          <form onSubmit={form.submit}>
            <div className="c-form-grid">
              <label>
                SLOT
                <select
                  value={form.slot}
                  onChange={(e) => form.setSlot(e.target.value)}
                >
                  {Array.from({ length: deployment.maxLeases }, (_, i) => {
                    const lease = data.leases.find((l) => l.slot === i);
                    return (
                      <option key={i} value={i}>
                        Slot 0{i} ·{" "}
                        {lease
                          ? `leased at ${percent(lease.rentRate)}`
                          : "open"}
                      </option>
                    );
                  })}
                </select>
              </label>
              <label>
                ANNUAL RENT (%)
                <input
                  type="number"
                  min="0.01"
                  step="0.01"
                  value={form.rent}
                  onChange={(e) => form.setRent(e.target.value)}
                />
              </label>
              <label>
                CAPITAL (USDC)
                <input
                  type="number"
                  min="1"
                  value={form.capital}
                  onChange={(e) => form.setCapital(e.target.value)}
                />
              </label>
              <label>
                BOND (tUSDC)
                <input
                  type="number"
                  min="1"
                  value={form.bond}
                  onChange={(e) => form.setBond(e.target.value)}
                />
              </label>
            </div>
            <p className="c-small">
              {form.occupied
                ? `This slot is leased. Offer at least ${percent(form.minRent)} to qualify; the takeover can run five minutes after the bid and settles the current manager first.`
                : "This slot is open. The lease starts in this transaction."}{" "}
              Minimum bond {money(form.minBond)}, 5% of capital.
            </p>
            {form.error && (
              <p role="alert" className="c-error">
                {form.error}
              </p>
            )}
            <p role="status" className="c-feedback">
              {form.message}
            </p>
            <button className="c-primary" disabled={form.pending || !account}>
              {form.pending
                ? WAITING
                : !account
                  ? "Connect a wallet to lease"
                  : form.occupied
                    ? "Place bid →"
                    : "Open lease →"}
            </button>
          </form>
        </section>
        <Range range={form.range} onChange={form.setRange} />
      </div>
    </>
  );
}
function Manager() {
  const { account, connect } = useSnapshot();
  const form = useManagerForm();
  if (!account)
    return (
      <section className="c-state">
        <p className="c-eyebrow">MANAGER STATION</p>
        <h2>Your lease, on the instruments.</h2>
        <p>
          Connect the wallet that manages a lease to inspect and operate it.
        </p>
        <button className="c-primary" onClick={() => void connect()}>
          Connect wallet →
        </button>
      </section>
    );
  if (!form.lease)
    return (
      <section className="c-state">
        <h2>No lease on station.</h2>
        <p>
          {form.message ||
            "This wallet has no lease. Open a slot or bid on one from the lease board."}
        </p>
        <Link href="/leases">Open lease board →</Link>
      </section>
    );
  const lease = form.lease;
  return (
    <>
      <div className="c-manager-instruments">
        <section className="c-coverage">
          <div className="c-panel-heading">
            <h2>Bond coverage</h2>
            <span>SLOT 0{lease.slot}</span>
          </div>
          <Gauge ratio={coverage(lease)} label="Manager bond coverage" />
          <p>Liquidation below {percent(LIQUIDATION)} equity / owed.</p>
        </section>
        <section className="c-manager-numbers">
          <div>
            <p>EQUITY</p>
            <strong title={money(lease.equity)}>
              {money(lease.equity, true)}
            </strong>
          </div>
          <div>
            <p>AMOUNT OWED</p>
            <strong title={money(lease.debt)}>{money(lease.debt, true)}</strong>
          </div>
          <div>
            <p>BOND REMAINING</p>
            <strong title={money(lease.bond)}>{money(lease.bond, true)}</strong>
          </div>
          <div>
            <p>RENT BURN / DAY</p>
            <strong>{money((lease.capital * lease.rentRate) / 36500)}</strong>
          </div>
        </section>
      </div>
      <div className="c-manager-work">
        <section>
          <Range
            range={form.range}
            onChange={form.setRange}
            liquidation={lease.liquidation}
          />
          <div className="c-danger-band">
            <span>LIQUIDATION BAND</span>
            <b>
              {bound(lease.liquidation.lower)} to{" "}
              {bound(lease.liquidation.upper)}
            </b>
          </div>
          <p className="c-small">
            Estimated from the hook&apos;s own liquidation test, holding fees
            and rent at today&apos;s values. A swap past either bound would
            liquidate the lease inside that swap.
          </p>
          <button
            className="c-primary"
            disabled={form.pending}
            onClick={() => form.act("rebalance")}
          >
            {form.pending ? WAITING : "Rebalance range →"}
          </button>
        </section>
        <aside className="c-bond-ops">
          <p className="c-eyebrow">BOND MAINTENANCE</p>
          <h2>Add a margin of safety.</h2>
          <label>
            TOP-UP AMOUNT (tUSDC)
            <input
              type="number"
              min="1"
              value={form.topUp}
              onChange={(e) => form.setTopUp(e.target.value)}
            />
          </label>
          <button
            className="c-outline"
            disabled={form.pending}
            onClick={() => form.act("bond")}
          >
            Top up bond →
          </button>
          <div className="c-exit">
            <h3>Return the capital</h3>
            <p>
              Settle the obligation. End the lease and move the capital back to
              passive.
            </p>
            {form.confirmExit ? (
              <>
                <button
                  className="c-outline"
                  onClick={() => form.act("exit")}
                  disabled={form.pending}
                >
                  Confirm exit
                </button>{" "}
                <button
                  className="c-text-button"
                  onClick={() => form.setConfirmExit(false)}
                >
                  Cancel
                </button>
              </>
            ) : (
              <button
                className="c-text-button"
                onClick={() => form.setConfirmExit(true)}
              >
                Review exit →
              </button>
            )}
          </div>
        </aside>
      </div>
      {form.error && (
        <p role="alert" className="c-error">
          {form.error}
        </p>
      )}
      <p role="status" className="c-feedback">
        {form.message}
      </p>
    </>
  );
}
function Activity() {
  const { now, data } = useSnapshot();
  const filter = useActivity();
  return (
    <section className="c-logbook">
      <div className="c-panel-heading">
        <h2>The capital record</h2>
        <span>
          {filter.events.length} ENTRIES /{" "}
          {data.historySynced ? "LIVE" : "INDEX LAGGING"}
        </span>
      </div>
      <div className="c-log-filters">
        <label>
          EVENT TYPE
          <select
            value={filter.kind}
            onChange={(e) =>
              filter.setKind(e.target.value as typeof filter.kind)
            }
          >
            {[
              "All",
              "Deposit",
              "Withdraw",
              "LeaseOpened",
              "BidPlaced",
              "LeaseTakenOver",
              "Rebalanced",
              "RentPaid",
              "BondToppedUp",
              "Liquidated",
              "LeaseRecalled",
              "LeaseEnded",
              "BidRefunded",
              "BidVoided",
              "Repassivated",
            ].map((kind) => (
              <option key={kind}>{kind}</option>
            ))}
          </select>
        </label>
        <label className="c-check">
          <input
            type="checkbox"
            checked={filter.mine}
            onChange={(e) => filter.setMine(e.target.checked)}
          />
          My activity only
        </label>
      </div>
      {filter.events.length ? (
        <ol>
          {filter.events.map((event, i) => (
            <li key={event.id}>
              <span className="c-log-number">
                {String(filter.events.length - i).padStart(3, "0")}
              </span>
              <div>
                <h3 className={event.kind === "Liquidated" ? "c-risk" : ""}>
                  {event.kind}
                </h3>
                <p>{event.detail}</p>
                <span title={event.address}>{address(event.address)}</span>
              </div>
              <div className="c-log-value">
                <strong>
                  {event.amount === null ? "" : money(event.amount)}
                </strong>
                <a
                  href={`${deployment.explorer}/tx/${event.tx}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  <time title={new Date(event.at).toISOString()}>
                    {humanTime(Math.max(0, now - event.at))} ↗
                  </time>
                </a>
              </div>
            </li>
          ))}
        </ol>
      ) : (
        <div className="c-empty">
          <h3>No entries on this bearing.</h3>
          <p>Change the event filter or make the first move.</p>
        </div>
      )}
    </section>
  );
}
