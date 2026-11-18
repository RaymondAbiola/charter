export const screens = ["deposit", "leases", "manager", "activity"] as const;
export type Screen = "overview" | (typeof screens)[number];
