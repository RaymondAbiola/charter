# Charter frontend

The operating desk for Charter, live on Unichain Sepolia. Depositors supply capital and watch what they are owed. Managers lease that capital, run their own ranges and keep their bond healthy. Anyone can follow every lease, bid and liquidation as it happens.

Live at [charter-lease.vercel.app](https://charter-lease.vercel.app).

Every vault figure is read from the hook's own view functions at a single block. Nothing is mocked, cached on a server or computed from an off-chain model of the vault. The three figures that are estimates are listed below.

## Try it

1. Add a browser wallet such as MetaMask or Rabby. The app switches it to Unichain Sepolia (chain 1301) and adds the network if it is missing.
2. Get a little Unichain Sepolia ETH for gas from any public faucet.
3. Click **Get test tokens** in the header and mint 10 tWETH and 50,000 tUSDC. The tokens are open-mint test tokens deployed for this pool.

Without a wallet, every screen still loads and reads the live vault.

**Your first deposit.** The capital screen walks through four steps: connect, add gas, mint, deposit. Gas is native Unichain Sepolia ETH, available from the faucets in the [Uniswap faucet guide](https://developers.uniswap.org/docs/unichain/tools/faucets); tWETH is a pool token and cannot pay it. The **About $100 / $500 / $1,000** buttons fill in an estimated number of LP shares. The token amounts and value shown are the hook's own preview of that exact number, and the form will not submit until the preview matches what you entered.

| Screen          | What it does                                                                                                                                                                                                     |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Overview        | Vault size, the leased and passive split, average rent, and a bond gauge per lease. The study figures from `analysis/` sit beside them.                                                                          |
| Your capital    | Deposit or withdraw Charter LP shares, with token amounts quoted by the hook's `previewDeposit` and `previewWithdraw`.                                                                                           |
| Lease board     | Every lease with its rent, capital, bond, equity against what it owes, and range. Open an empty slot, or bid on a leased one. Once a bid's five-minute delay has passed, anyone can press **Activate takeover**. |
| Manager station | For the connected wallet's lease: bond coverage, rent burn, the estimated liquidation band, rebalance, bond top-up and exit.                                                                                     |
| Logbook         | Every hook event since deployment, filterable, each linked to its transaction on the explorer.                                                                                                                   |

The overview states the problem and the agreement before the live instruments, and its **Follow the capital** links walk through the other four screens. That explanation and the study stay readable while the snapshot loads or if the RPC is down; the live figures stay empty rather than show invented values. **Get test tokens** in the header works on every screen.

## Deployment

| Contract                                | Address                                                                                                                        |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Charter hook (and the Charter LP token) | [`0x47c2652A9AD7704A7eDbe8A276F213b59e51e0C0`](https://sepolia.uniscan.xyz/address/0x47c2652A9AD7704A7eDbe8A276F213b59e51e0C0) |
| tWETH, currency0, 18 decimals           | [`0x54A2CbC2947E3Ec15F1B8eDc3A25D61d070ae668`](https://sepolia.uniscan.xyz/address/0x54A2CbC2947E3Ec15F1B8eDc3A25D61d070ae668) |
| tUSDC, currency1, 6 decimals            | [`0xd508662f90226b081E749CB699658A7034721E0c`](https://sepolia.uniscan.xyz/address/0xd508662f90226b081E749CB699658A7034721E0c) |
| Uniswap v4 PoolManager                  | [`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

The pool is tWETH / tUSDC with a 0.30% fee and 60-tick spacing. Addresses and the pool's parameters live in `src/chain/deployment.ts`, which mirrors `deployments/1301.json` at the repo root.

## How it reads the chain

**State** comes from the RPC. Each refresh pins one block, then reads the vault, all four lease slots, their pending bids and the connected wallet in multicalls at that block, so the figures on a screen always agree with each other. It refreshes every six seconds and after every transaction.

**History** comes from Blockscout's v2 API. The public Unichain Sepolia RPCs either cap log queries at 1,000 blocks or prune older logs, and one of them returns an empty result for pruned ranges instead of an error. Rebuilding history from them would silently drop events. Blockscout has the full record, needs no key, and is fetched incrementally. If it cannot be reached, the logbook keeps its last copy and says it is lagging. The vault's live state does not depend on it.

**Pool depth** on the range chart is rebuilt from the pool's own `ModifyLiquidity` events: every open position, netted, at every price on the axis. It includes Charter's positions and everyone else's.

**Values** are in tUSDC, taken as one dollar, at the hook's settlement price. That is the spot price clamped so its square root stays within 1% of the block's opening value, about 2% in price. It is the price the hook itself settles rent, withdrawals and liquidations at.

Three figures are estimates, and the interface says so where they appear:

- **Liquidation band.** The app solves for the prices at which the lease would fail the hook's own test, the same inequality the hook checks after each swap: held value plus bond, less unpaid rent, against what the lease owes plus a 1% margin. It holds fees and rent at today's values, so it is a guide rather than a promise. A side with no crossing within a 50x move reads "None in reach".
- **Rent earned to date.** Rent is paid into the vault for every depositor at once. The app shows your pro-rata share of all rent paid, at your current holding.
- **Logbook amounts.** Token amounts are valued at today's price, not the price at the time of the event.

## How it writes

Every action is simulated against the chain before your wallet is asked to sign, so a call that would fail is stopped before you sign it. When the hook would revert, the custom error is decoded and shown as a plain sentence. For example, `BidTooLow` reads: "Rent must beat the current lease and any pending bid by at least 5% of their rate". Token approvals are requested only when the current allowance is short.

| Action                             | Contract call                                                |
| ---------------------------------- | ------------------------------------------------------------ |
| Supply capital, Withdraw           | `deposit`, `withdraw`, with slippage limits from the preview |
| Open lease (empty slot)            | `openLease`                                                  |
| Place bid (leased slot)            | `bid`, which escrows the bond                                |
| Activate takeover                  | `activate`, open to anyone once the delay has passed         |
| Cancel bid                         | `cancelBid`, for the bidder after the delay                  |
| Rebalance range, Top up bond, Exit | `rebalance`, `topUpBond`, `exitLease`                        |
| Mint test tokens                   | `mint` on each test token                                    |

Price ranges are entered in USDC per WETH and snapped to the pool's 60-tick spacing on submit. Capital is entered in USDC and converted to the hook's units at the settlement price.

## Run it locally

Requires Node.js 24 or later.

```bash
npm ci
npm run dev
```

Open `http://localhost:3000`. No environment variables are needed. Two optional overrides:

| Variable               | Default                                          |
| ---------------------- | ------------------------------------------------ |
| `NEXT_PUBLIC_RPC_URL`  | `https://unichain-sepolia-rpc.publicnode.com`    |
| `NEXT_PUBLIC_LOGS_API` | `https://unichain-sepolia.blockscout.com/api/v2` |

The public endpoint `sepolia.unichain.org` stays as a fallback for reads. It is not the default because its load balancer often answers "block not found" for a block another of its nodes has just reported.

## Checks

```bash
npm run lint        # ESLint, zero warnings allowed
npm run typecheck   # TypeScript, strict
npm test            # price, range, liquidation and value-preset precision tests
npm run build
```

Three browser checks drive Chrome through Puppeteer. They expect Chrome at `/usr/bin/google-chrome`; set `CHROME_PATH` to use another. Screenshots and a report land in `verification/`, which git ignores.

**`npm run verify`** is read-only and runs against the live contracts. Start a production server first (`npm run build && npm run start -- --hostname 127.0.0.1 --port 3197`). It checks:

- every screen at 1440px and 375px loads live chain data, with no layout overflow and no browser errors or hydration mismatches
- the axe-core WCAG 2.1 A and AA rules pass on every screen
- the page talks only to the app, the RPC and the log index
- a wallet that refuses to sign surfaces as a plain sentence

Its wallet refuses every transaction, so it cannot spend anything.

**`npm run test:presentation`** uses the same running production server. It checks the first-deposit setup and value presets at mobile and desktop widths, guided navigation, the connected manager console at 375, 768, 1024 and 1440px, and automated accessibility rules. It also stalls and rejects RPC requests to confirm that the agreement, exact study figures and retry action stay available without inventing vault data. Its injected wallet refuses transaction requests.

**`npm run e2e`** exercises every write. It starts its own anvil fork of Unichain Sepolia and a dev server pointed at it, and signs as a throwaway address the hook has never seen. It runs these steps, in order:

1. connect
2. remove gas ETH and verify the explanation and disabled mint/deposit actions, then restore gas
3. mint test tokens and continue to the deposit form
4. choose a $100 estimate, approve both tokens and verify the exact shares minted on the hook
5. hold a changed amount's quote request and verify submission stays disabled until it resolves
6. a refused over-withdrawal
7. a full withdrawal
8. open a lease
9. a bid below the required raise, refused by the hook with its reason
10. a qualifying bid
11. skip the five-minute delay on the fork, then activate the takeover
12. rebalance
13. top up the bond
14. exit
15. disconnect, reload to confirm it stays disconnected, then reconnect

It needs Foundry's `anvil` on the path. Nothing it does reaches the real chain.

## Known limits

- **No swap screen.** The pool uses a dynamic fee set by the hook, so Uniswap's own interface does not route through it. To move the price, call the deployed `PoolSwapTest` router; the root README shows how.
- **Injected wallets only.** The app talks to `window.ethereum`. WalletConnect and other connectors are not wired in.
- **Charter LP shares are small numbers.** The first deposit minted shares one-to-one with liquidity units and the token has 18 decimals, so 0.00001 shares was worth about $1,100 at launch. Wallets show the same figure, so the app shows it unscaled to 8 decimals rather than inventing a display unit.
- **Testnet only.** Test tokens have no value and the tUSDC price is taken as one dollar.

## Source layout

| Path                   | Contents                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| `src/chain/`           | Deployment, ABI, reads, log index, price and liquidation math, wallet and writes. No React. |
| `src/state/`           | The provider that polls the chain, and one model per form.                                  |
| `src/charter/`         | The interface and its styles.                                                               |
| `src/data/evidence.ts` | The four vault observations from `analysis/`.                                               |
| `scripts/`             | The browser checks and their shared helpers.                                                |
