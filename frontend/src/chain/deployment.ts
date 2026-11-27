// Mirrors deployments/1301.json from the contracts repo.
export const deployment = {
  chainId: 1301,
  charter: "0x47c2652A9AD7704A7eDbe8A276F213b59e51e0C0",
  weth: "0x54A2CbC2947E3Ec15F1B8eDc3A25D61d070ae668",
  usdc: "0xd508662f90226b081E749CB699658A7034721E0c",
  swapRouter: "0xD873f0eb417d26d862963884CC0fC301938Ab2a9",
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  poolId: "0x19bc8b1b1392beb47d523abcd4db7f9e4ee097c862833bd2c8996f3bb9f4ffa7",
  deployBlock: 68892116n,
  tickSpacing: 60,
  maxLeases: 4,
  baseFeePips: 3000,
  maintenanceBps: 100,
  minBondBps: 500,
  minRaiseBps: 500,
  shareCapBps: 500,
  auctionDelay: 300,
  explorer: "https://sepolia.uniscan.xyz",
} as const;

// The public sepolia.unichain.org endpoint often answers "block not found" behind its load balancer.
export const rpcUrl =
  process.env.NEXT_PUBLIC_RPC_URL ??
  "https://unichain-sepolia-rpc.publicnode.com";

// currency0 is tWETH (18 decimals), currency1 is tUSDC (6 decimals). Prices are USDC per WETH.
export const DECIMALS0 = 18;
export const DECIMALS1 = 6;
