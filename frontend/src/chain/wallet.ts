import {
  BaseError,
  ContractFunctionRevertedError,
  createWalletClient,
  custom,
  erc20Abi,
  maxUint256,
  UserRejectedRequestError,
  type EIP1193Provider,
  type Hex,
  type PublicClient,
} from "viem";
import { unichainSepolia } from "viem/chains";
import { charterAbi, libraryErrors, tokenAbi } from "./abi.ts";
import { deployment, rpcUrl } from "./deployment.ts";
import type { Address } from "./types.ts";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

const abi = [...charterAbi, ...libraryErrors] as const;
const chain = {
  ...unichainSepolia,
  rpcUrls: { default: { http: [rpcUrl] } },
} as const;

export const hasWallet = () =>
  typeof window !== "undefined" && Boolean(window.ethereum);

function wallet() {
  if (!window.ethereum)
    throw new Error(
      "No browser wallet found. Install MetaMask or Rabby to make changes. Reading works without one.",
    );
  return createWalletClient({ chain, transport: custom(window.ethereum) });
}

async function onChain(w: ReturnType<typeof wallet>) {
  if ((await w.getChainId()) === deployment.chainId) return;
  try {
    await w.switchChain({ id: deployment.chainId });
  } catch (error) {
    const code = (error as { code?: number }).code;
    const inner = (error as { cause?: { code?: number } }).cause?.code;
    if (code !== 4902 && inner !== 4902) throw error;
    await w.addChain({ chain });
  }
}

export async function connect(): Promise<Address> {
  const w = wallet();
  const [account] = await w.requestAddresses();
  await onChain(w);
  return account;
}

/** Accounts the wallet already shares with this site, without a prompt. */
export async function connected(): Promise<Address | null> {
  if (!hasWallet()) return null;
  const [account] = await wallet().getAddresses();
  return account ?? null;
}

/** Asks the wallet to drop this site's access. Wallets without the method just ignore it. */
export async function revoke() {
  try {
    await window.ethereum?.request({
      method: "wallet_revokePermissions",
      params: [{ eth_accounts: {} }],
    } as never);
  } catch {
    // older wallets: the app forgets the account anyway
  }
}

const messages: Record<string, string> = {
  Slippage: "The price moved past your slippage limit. Try again or raise it.",
  ZeroShares: "Enter an amount above zero.",
  ZeroAmount: "Enter an amount above zero.",
  BadSlot: "That slot does not exist.",
  SlotTaken: "That slot is already leased. Bid on it to take it over.",
  NotManager: "Only the slot's manager can do that.",
  BadRange: "The lower price must be below the upper price.",
  RangeTooThin: "That range is too narrow to hold the capital. Widen it.",
  NotEnoughCapital: "There is not enough passive capital to lease that much.",
  BondTooSmall: "The bond is below the 5% minimum for that much capital.",
  NoLease: "That slot has no lease.",
  Healthy: "That lease is healthy, so it cannot be liquidated.",
  NotReady:
    "Not yet. Either the five-minute delay is still running or the price moved this block. Try again in a few seconds.",
  BidTooLow:
    "Rent must beat the current lease and any pending bid by at least 5% of their rate.",
  NoBid: "There is no bid on that slot.",
  ShareCapExceeded:
    "This would make Charter more than 5% of the pool's active liquidity. Lease less or widen the range.",
  NotEnoughPassive:
    "The vault cannot pay out that much right now. Try a smaller withdrawal.",
};

/** A plain sentence for a failed write. */
export function explain(error: unknown): string {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError))
      return "You rejected the request in your wallet.";
    const revert = error.walk(
      (e) => e instanceof ContractFunctionRevertedError,
    ) as ContractFunctionRevertedError | null;
    const name = revert?.data?.errorName;
    if (name && messages[name]) return messages[name];
    if (name === "Panic" || /underflow|overflow/i.test(error.message))
      return "Not enough test tokens for that. Use the faucet first.";
    if (/insufficient funds/i.test(error.message))
      return "Your wallet needs Unichain Sepolia ETH to pay for gas.";
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : "The transaction failed.";
}

type Call = {
  address: Address;
  abi: typeof abi | typeof erc20Abi | typeof tokenAbi;
  functionName: string;
  args: readonly unknown[];
};

export function createWriter(pc: PublicClient) {
  async function send(account: Address, call: Call): Promise<Hex> {
    const w = wallet();
    await onChain(w);
    const { request } = await pc.simulateContract({
      ...(call as Parameters<PublicClient["simulateContract"]>[0]),
      account,
    });
    const hash = await w.writeContract(
      request as Parameters<typeof w.writeContract>[0],
    );
    const receipt = await pc.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success")
      throw new Error("The transaction was mined but reverted.");
    return hash;
  }

  const hook = (functionName: string, ...args: unknown[]): Call => ({
    address: deployment.charter,
    abi,
    functionName,
    args,
  });

  async function approve(
    account: Address,
    token: Address,
    needed: bigint,
    current: bigint,
  ) {
    if (current >= needed) return;
    await send(account, {
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [deployment.charter, maxUint256],
    });
  }

  return {
    send,
    approve,
    faucet: async (account: Address) => {
      await send(account, {
        address: deployment.weth,
        abi: tokenAbi,
        functionName: "mint",
        args: [account, 10n * 10n ** 18n],
      });
      await send(account, {
        address: deployment.usdc,
        abi: tokenAbi,
        functionName: "mint",
        args: [account, 50_000n * 10n ** 6n],
      });
    },
    deposit: (a: Address, shares: bigint, max0: bigint, max1: bigint) =>
      send(a, hook("deposit", shares, max0, max1, a)),
    withdraw: (a: Address, shares: bigint, min0: bigint, min1: bigint) =>
      send(a, hook("withdraw", shares, min0, min1, a)),
    openLease: (
      a: Address,
      slot: number,
      units: bigint,
      rentPips: number,
      bond: bigint,
      lower: number,
      upper: number,
    ) =>
      send(
        a,
        hook("openLease", BigInt(slot), units, rentPips, bond, lower, upper),
      ),
    bid: (
      a: Address,
      slot: number,
      units: bigint,
      rentPips: number,
      bond: bigint,
      lower: number,
      upper: number,
    ) =>
      send(a, hook("bid", BigInt(slot), units, rentPips, bond, lower, upper)),
    activate: (a: Address, slot: number) =>
      send(a, hook("activate", BigInt(slot))),
    cancelBid: (a: Address, slot: number) =>
      send(a, hook("cancelBid", BigInt(slot))),
    rebalance: (a: Address, slot: number, lower: number, upper: number) =>
      send(a, hook("rebalance", BigInt(slot), lower, upper)),
    topUpBond: (a: Address, slot: number, amount: bigint) =>
      send(a, hook("topUpBond", BigInt(slot), amount)),
    exitLease: (a: Address, slot: number) =>
      send(a, hook("exitLease", BigInt(slot))),
  };
}

export type Writer = ReturnType<typeof createWriter>;
