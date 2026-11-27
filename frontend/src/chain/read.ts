import { createPublicClient, erc20Abi, http, type PublicClient } from "viem";
import { unichainSepolia } from "viem/chains";
import { charterAbi } from "./abi.ts";
import { deployment, rpcUrl } from "./deployment.ts";
import { fetchEvents, toActivity, type RawEvent } from "./events.ts";
import {
  amounts,
  FULL_TICK,
  liquidationBand,
  priceAtTick,
  priceFromSqrtX96,
  sub,
  unitsValue,
  usdc,
  value,
  weth,
  type Pair,
} from "./math.ts";
import type { Address, Bid, Lease, Snapshot, TokenAmounts } from "./types.ts";

const ZERO = "0x0000000000000000000000000000000000000000";
const hook = { address: deployment.charter, abi: charterAbi } as const;
const slots = Array.from({ length: deployment.maxLeases }, (_, i) => BigInt(i));

export function createReader(client?: PublicClient) {
  const pc =
    client ??
    (createPublicClient({
      chain: unichainSepolia,
      transport: http(rpcUrl, { batch: false, retryCount: 3 }),
    }) as PublicClient);
  const raw: RawEvent[] = [];
  let scanned = deployment.deployBlock - 1n;

  async function read(account: Address | null): Promise<Snapshot> {
    const head = await pc.getBlock({ blockTag: "latest" });
    const blockNumber = head.number;

    const [supply, passive, leased, sqrt, bundle, uncovered] =
      (await pc.multicall({
        allowFailure: false,
        blockNumber,
        contracts: [
          { ...hook, functionName: "totalSupply" },
          { ...hook, functionName: "passiveLiquidity" },
          { ...hook, functionName: "leasedUnits" },
          { ...hook, functionName: "settlementSqrtPrice" },
          { ...hook, functionName: "bundle" },
          { ...hook, functionName: "uncovered" },
        ],
      })) as [
        bigint,
        bigint,
        bigint,
        bigint,
        readonly [bigint, bigint, bigint],
        bigint,
      ];

    const perSlot = (await pc.multicall({
      allowFailure: false,
      blockNumber,
      contracts: slots.flatMap((slot) => [
        { ...hook, functionName: "lease", args: [slot] } as const,
        { ...hook, functionName: "pendingBid", args: [slot] } as const,
        { ...hook, functionName: "leaseAccount", args: [slot] } as const,
      ]),
    })) as unknown[];

    const price = priceFromSqrtX96(sqrt);
    const leases: Lease[] = [];
    const bids: Bid[] = [];
    slots.forEach((s, i) => {
      const slot = Number(s);
      const l = perSlot[i * 3] as LeaseStruct;
      const b = perSlot[i * 3 + 1] as BidStruct;
      const [acct, bondRaw, rentRaw] = perSlot[i * 3 + 2] as AccountResult;
      if (l.manager !== ZERO) {
        const units = Number(l.units);
        const liquidity = Number(l.liquidity);
        const owed: Pair = [weth(acct.owed0), usdc(acct.owed1)];
        const held: Pair = [weth(acct.held0), usdc(acct.held1)];
        const bond = usdc(bondRaw);
        const rent = usdc(rentRaw);
        const debt = usdc(acct.owedValue);
        leases.push({
          slot,
          manager: l.manager,
          rentPips: l.rentPips,
          rentRate: l.rentPips / 10_000,
          units: l.units,
          capital: unitsValue(units, price),
          bond,
          rentDue: rent,
          equity: usdc(acct.heldValue) + bond - rent,
          debt,
          ticks: { lower: l.tickLower, upper: l.tickUpper },
          range: {
            lower: priceAtTick(l.tickLower),
            upper: priceAtTick(l.tickUpper),
          },
          liquidation: liquidationBand(
            {
              units,
              liquidity,
              tickLower: l.tickLower,
              tickUpper: l.tickUpper,
              bond,
              rent,
              extraHeld: sub(
                held,
                amounts(liquidity, l.tickLower, l.tickUpper, price),
              ),
              extraOwed: sub(
                owed,
                amounts(units, -FULL_TICK, FULL_TICK, price),
              ),
            },
            price,
          ),
          openedAt: Number(l.openedAt) * 1000,
        });
      }
      if (b.bidder !== ZERO)
        bids.push({
          slot,
          manager: b.bidder,
          rentRate: b.rentPips / 10_000,
          units: b.units,
          capital: unitsValue(Number(b.units), price),
          bond: usdc(b.bond),
          range: {
            lower: priceAtTick(b.tickLower),
            upper: priceAtTick(b.tickUpper),
          },
          takeoverAt: Number(b.readyAt) * 1000,
        });
    });

    if (blockNumber > scanned) {
      raw.push(...(await fetchEvents(pc, scanned + 1n, blockNumber)));
      scanned = blockNumber;
    }
    const at = Number(head.timestamp) * 1000;
    const { events, rentPaid } = toActivity(raw, price, {
      number: blockNumber,
      at,
    });

    let wallet: Snapshot["wallet"] = null;
    if (account) {
      const [eth, tokens] = await Promise.all([
        pc.getBalance({ address: account, blockNumber }),
        pc.multicall({
          allowFailure: false,
          blockNumber,
          contracts: [
            {
              address: deployment.weth,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [account],
            },
            {
              address: deployment.usdc,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [account],
            },
            {
              address: deployment.weth,
              abi: erc20Abi,
              functionName: "allowance",
              args: [account, deployment.charter],
            },
            {
              address: deployment.usdc,
              abi: erc20Abi,
              functionName: "allowance",
              args: [account, deployment.charter],
            },
            { ...hook, functionName: "balanceOf", args: [account] },
          ],
        }),
      ]);
      const [w, u, aw, au, shares] = tokens as bigint[];
      const redeemable = shares
        ? ((await pc.readContract({
            ...hook,
            functionName: "previewWithdraw",
            args: [shares],
            blockNumber,
          })) as TokenAmounts)
        : ([0n, 0n] as const);
      wallet = {
        address: account,
        eth,
        weth: w,
        usdc: u,
        allowanceWeth: aw,
        allowanceUsdc: au,
        shares,
        redeemable,
      };
    }

    return {
      block: blockNumber,
      at,
      price,
      sqrtPriceX96: sqrt,
      supply,
      passiveUnits: passive,
      leasedUnits: leased,
      total:
        unitsValue(Number(bundle[0]), price) +
        value([weth(bundle[1]), usdc(bundle[2])], price),
      uncovered: usdc(uncovered),
      leases,
      bids,
      events,
      rentPaid,
      wallet,
    };
  }

  async function preview(kind: "deposit" | "withdraw", shares: bigint) {
    return (await pc.readContract({
      ...hook,
      functionName: kind === "deposit" ? "previewDeposit" : "previewWithdraw",
      args: [shares],
    })) as TokenAmounts;
  }

  return { client: pc, read, preview };
}

export type Reader = ReturnType<typeof createReader>;

interface LeaseStruct {
  manager: Address;
  rentPips: number;
  openedAt: bigint;
  liquidity: bigint;
  tickLower: number;
  tickUpper: number;
  units: bigint;
}
interface BidStruct {
  bidder: Address;
  rentPips: number;
  readyAt: bigint;
  units: bigint;
  tickLower: number;
  tickUpper: number;
  bond: bigint;
}
type AccountResult = readonly [
  {
    owed0: bigint;
    owed1: bigint;
    held0: bigint;
    held1: bigint;
    owedValue: bigint;
    heldValue: bigint;
  },
  bigint,
  bigint,
  bigint,
];
