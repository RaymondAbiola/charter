import type { Address, Lease } from "../mock/types";

export const money = (value: number, compact = false) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    notation: compact ? "compact" : "standard",
    maximumFractionDigits: 2,
    minimumFractionDigits: compact ? 2 : 2,
  }).format(value);
export const number = (value: number, digits = 2) =>
  new Intl.NumberFormat("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
export const percent = (value: number) => `${number(value)}%`;
export const address = (value: Address) =>
  `${value.slice(0, 6)}…${value.slice(-4)}`;
export const token = (
  value: bigint,
  decimals: number,
  digits = decimals === 6 ? 2 : 6,
) => number(Number(value) / 10 ** decimals, digits);
export const humanTime = (ms: number) =>
  ms < 60000
    ? "Just now"
    : ms < 3600000
      ? `${Math.floor(ms / 60000)}m ago`
      : ms < 86400000
        ? `${Math.floor(ms / 3600000)}h ago`
        : `${Math.floor(ms / 86400000)}d ago`;
export const held = (ms: number) =>
  `${Math.floor(ms / 86400000)}d ${Math.floor(ms / 3600000) % 24}h`;
export const health = (lease: Lease) =>
  lease.equity / lease.debt < 1.01
    ? "At risk"
    : lease.equity / lease.debt < 1.06
      ? "Watch"
      : "Healthy";
export const coverage = (lease: Lease) => (lease.equity / lease.debt) * 100;
export const parseShares = (value: string): bigint => {
  if (!/^\d{1,12}(\.\d{0,18})?$/.test(value))
    throw new Error("Use a positive number with up to 18 decimal places.");
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * 10n ** 18n + BigInt(fraction.padEnd(18, "0"));
};
