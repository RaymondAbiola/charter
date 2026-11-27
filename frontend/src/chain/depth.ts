import { parseAbi } from "viem";
import { deployment } from "./deployment.ts";
import { fetchLogs, type DecodedLog } from "./logs.ts";
import { tickOf } from "./math.ts";

const poolAbi = parseAbi([
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
]);

export const fetchPoolLogs = (known: Set<string>) =>
  fetchLogs(
    poolAbi,
    deployment.poolManager,
    known,
    deployment.deployBlock,
    deployment.poolId,
  );

export interface Range {
  tickLower: number;
  tickUpper: number;
  liquidity: number;
}

/** Open positions in the pool, netted from every ModifyLiquidity since it was created. */
export function openRanges(logs: DecodedLog[]): Range[] {
  const book = new Map<string, Range>();
  for (const { args } of logs) {
    const key = `${args.sender}-${args.tickLower}-${args.tickUpper}-${args.salt}`;
    const r = book.get(key) ?? {
      tickLower: Number(args.tickLower),
      tickUpper: Number(args.tickUpper),
      liquidity: 0,
    };
    r.liquidity += Number(args.liquidityDelta as bigint);
    book.set(key, r);
  }
  return [...book.values()].filter((r) => r.liquidity > 1);
}

/** Active liquidity at evenly spaced prices, scaled so the deepest point is 100. */
export function depthCurve(
  ranges: Range[],
  lower: number,
  upper: number,
  points = 72,
) {
  const rows = Array.from({ length: points }, (_, i) => {
    const price = lower + ((upper - lower) * i) / (points - 1);
    const tick = tickOf(price);
    const depth = ranges.reduce(
      (sum, r) =>
        tick >= r.tickLower && tick < r.tickUpper ? sum + r.liquidity : sum,
      0,
    );
    return { price: Math.round(price), depth };
  });
  const top = Math.max(...rows.map((r) => r.depth), 1);
  return rows.map((r) => ({ price: r.price, depth: (r.depth / top) * 100 }));
}
