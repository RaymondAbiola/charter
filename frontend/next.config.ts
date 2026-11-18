import type { NextConfig } from "next";

const config: NextConfig = {
  async redirects() {
    return [
      { source: "/c", destination: "/", permanent: true },
      {
        source: "/c/:screen(deposit|leases|manager|activity)",
        destination: "/:screen",
        permanent: true,
      },
    ];
  },
  reactStrictMode: true,
  devIndicators: false,
  agentRules: false,
  experimental: { useTypeScriptCli: false },
};
export default config;
