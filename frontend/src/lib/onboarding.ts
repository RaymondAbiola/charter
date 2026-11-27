export const gasFaucetsUrl =
  "https://developers.uniswap.org/docs/unichain/tools/faucets";

// A value preset estimates shares; the hook's preview remains the transaction quote.
export function estimateSharesForValue(
  amount: number,
  supply: bigint,
  total: number,
): bigint | null {
  const amountMicros = Math.round(amount * 1e6);
  const totalMicros = Math.round(total * 1e6);
  if (
    !Number.isSafeInteger(amountMicros) ||
    !Number.isSafeInteger(totalMicros) ||
    amountMicros <= 0 ||
    totalMicros <= 0 ||
    supply <= 0n
  )
    return null;
  const shares = (supply * BigInt(amountMicros)) / BigInt(totalMicros);
  return shares > 0n ? shares : null;
}
