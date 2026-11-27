import type { Metadata } from "next";
import localFont from "next/font/local";
import { ChainProvider } from "@/state/provider";
import "./globals.css";
import "@/charter/styles.css";

const mono = localFont({
  src: "../../node_modules/@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2",
  variable: "--font-mono",
  display: "swap",
});

const instrument = localFont({
  src: "../../node_modules/@fontsource-variable/instrument-sans/files/instrument-sans-latin-wght-normal.woff2",
  variable: "--font-instrument",
  weight: "400 700",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Charter | Liquidity under contract",
  description:
    "Managers pay rent to run your liquidity. You are owed what passive would have earned. Live on Unichain Sepolia with test tokens.",
};
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${mono.variable} ${instrument.variable}`}>
        <ChainProvider>{children}</ChainProvider>
      </body>
    </html>
  );
}
