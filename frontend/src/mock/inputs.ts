import type { PriceRange } from "./types.ts";

export function mockInputs(): {
  shares: string;
  slippage: string;
  bid: {
    slot: string;
    rent: string;
    capital: string;
    bond: string;
    range: PriceRange;
  };
  manager: { range: PriceRange; topUp: string };
} {
  return {
    shares: "1000",
    slippage: "0.50",
    bid: {
      slot: "2",
      rent: "6.25",
      capital: "2750000",
      bond: "350000",
      range: { lower: 2600, upper: 3180 },
    },
    manager: { range: { lower: 2580, upper: 3160 }, topUp: "10000" },
  };
}
