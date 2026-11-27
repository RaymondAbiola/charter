import { decodeEventLog, type Abi, type Hex } from "viem";

// Public RPCs on Unichain Sepolia prune old logs or cap ranges at 1,000 blocks, so history comes
// from Blockscout's v2 API. Its Etherscan-style /api allows only a few calls per half hour.
export const logsApi =
  process.env.NEXT_PUBLIC_LOGS_API ??
  "https://unichain-sepolia.blockscout.com/api/v2";

export interface DecodedLog {
  eventName: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: Hex;
  /** ms */
  at: number;
}

interface Item {
  block_number: number;
  index: number;
  data: Hex;
  topics: (Hex | null)[];
  transaction_hash: Hex;
  block_timestamp: string;
}

export const logId = (l: { transactionHash: string; logIndex: number }) =>
  `${l.transactionHash}-${l.logIndex}`;

/**
 * Logs from `address`, newest first, until a page reaches one already in `known` or `floor`.
 * `topic` matches any indexed topic. Logs `abi` cannot decode are skipped.
 */
export async function fetchLogs(
  abi: Abi,
  address: string,
  known: Set<string>,
  floor: bigint,
  topic?: Hex,
): Promise<DecodedLog[]> {
  const out: DecodedLog[] = [];
  let page: Record<string, string> = topic ? { topic } : {};
  for (;;) {
    const res = await fetch(
      `${logsApi}/addresses/${address}/logs?${new URLSearchParams(page)}`,
      { cache: "no-store" },
    );
    if (!res.ok) throw new Error(`Log index answered ${res.status}`);
    const body = (await res.json()) as {
      items: Item[];
      next_page_params: Record<string, string | number> | null;
    };
    let reachedKnown = false;
    for (const item of body.items) {
      const id = `${item.transaction_hash}-${item.index}`;
      if (known.has(id) || BigInt(item.block_number) < floor) {
        reachedKnown = true;
        continue;
      }
      try {
        const decoded = decodeEventLog({
          abi,
          data: item.data,
          topics: item.topics.filter((t): t is Hex => t !== null) as [
            Hex,
            ...Hex[],
          ],
        });
        out.push({
          eventName: String(decoded.eventName),
          args: (decoded.args ?? {}) as Record<string, unknown>,
          blockNumber: BigInt(item.block_number),
          logIndex: item.index,
          transactionHash: item.transaction_hash,
          at: Date.parse(item.block_timestamp),
        });
      } catch {
        // not an event in this ABI
      }
    }
    if (reachedKnown || !body.next_page_params) break;
    page = {
      ...(topic ? { topic } : {}),
      ...Object.fromEntries(
        Object.entries(body.next_page_params).map(([k, v]) => [k, String(v)]),
      ),
    };
  }
  return out;
}
