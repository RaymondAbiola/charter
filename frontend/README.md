# Charter frontend

An interactive Next.js App Router prototype for a Uniswap v4 liquidity lease vault. The selected Charter design uses a navy instrument desk with sand type, brass accents and Instrument Sans. Nothing connects to a wallet, RPC, price feed or external API.

## Run

Use Node.js 24 or later.

```bash
npm ci
npm run dev
```

Open `http://localhost:3000` for the overview. The other screens are `/deposit`, `/leases`, `/manager` and `/activity`. Existing `/c` and `/c/...` links redirect to these routes. Ledger, Factsheet and the design comparison have been removed. App Router links preserve local state during navigation; a full reload resets the prototype.

## Design

Charter is a navy instrument desk with sand type, brass accents and Instrument Sans. A persistent side rail holds navigation, bond gauges show equity against the amount owed, and range charts use a chart-paper grid. The overview treats capital allocation and bond coverage as instruments. There are no nautical illustrations or decorative marine symbols. IBM Plex Mono is retained for figures; fonts used only by the discarded directions have been removed.

## Mock personas and states

The wallet button cycles **Visitor → Depositor → Manager → Visitor**. It never opens a real wallet. The footer's **Mock controls** panel also selects a persona directly and exposes seeded, loading, empty and error states. Retry restores the seeded view. Empty means no leases, bids, activity or account shares, with vault capital left passive.

The depositor starts with 20,000 LP shares. Deposit and withdraw update the share balance, token bundle and activity. Slippage limits use integer token arithmetic. In this prototype withdrawals are limited to currently passive capital. The manager persona operates slot 01; it can place a higher rental bid, choose bounds using keyboard-accessible sliders, rebalance, top up a bond and explicitly confirm an exit. The board starts with three leases and one pending bid. Slot 03 is close to its illustrative liquidation bound.

The snapshot is anchored at 12:00 UTC on 17 November 2026 so static HTML and client hydration agree. Countdown time advances locally. A bid reaches "ready" when its delay expires; the prototype does not execute an automatic takeover, run swaps, simulate market prices or trigger liquidations. Rebalancing and bond bands are mock risk illustrations, not contract calculations. Successful local actions use a short simulated pending state.

## Data boundary

All seeds and mock reads and writes live in `src/mock/`. `types.ts` describes the future boundary; `client.ts` implements `previewDeposit`, `previewWithdraw`, `bundle`, `totalSupply`, `balanceOf`, `passiveLiquidity`, `settlementSqrtPrice`, `deposit` and `withdraw`. Shares and WETH use 18 decimals; USDC uses 6. `bundle` returns the contract-shaped `(liquidity, amount0, amount1)` tuple. The values are illustrative units, not live chain state. Future lease method names and signatures are isolated in `leases.ts`.

`src/state/` contains shared nonvisual interaction models. The selected interface and its styles live in `src/charter/`; screen names live in `src/lib/screens.ts`. Formatting lives in `src/lib/format.ts`.

`evidence.ts` contains the four exact observations supplied in the brief. These are separate from the illustrative depth distribution in `charts.ts`. Historical evidence appears only as tables and full-period bars or dots. No historical time series is fabricated, and no study URL or author has been invented.

Google Fonts are installed through Fontsource packages and served locally using `next/font/local`. Installation downloads dependencies; the built app and subsequent builds need no font service, API credentials or environment variables.

## Checks

```bash
npm run lint
npm run typecheck
npm test
npm run build
npm run start -- --hostname 127.0.0.1 --port 3197
```

With the production server running, `npm run verify` checks all five screens at 1440px and 375px, the evidence figures, mock interactions, data states, navigation and legacy redirects. It requires Chrome at `/usr/bin/google-chrome`, uses Puppeteer, and writes ignored screenshots and a report to `verification/`. It also fails on browser errors, hydration mismatches or external browser requests. It is a local smoke test, not a contract integration test.

All source is contained in `frontend/`. No contract integration, real wallet connection or deployment is included.

## Dependency audit

At implementation time, npm reports a high-severity `picomatch` advisory through the ESLint development toolchain. The latest published release is still in the advisory's affected range; there is no available patched release to pin. The application does not accept remote glob patterns. Keep the tooling updated when a fix is released. This does not prevent build or lint from passing.
