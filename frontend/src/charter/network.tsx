"use client";

import { deployment } from "@/chain/deployment";
import { useSnapshot } from "@/state/provider";
import { useFaucet } from "@/state/models";
import { token } from "@/lib/format";

const link = (address: string) => `${deployment.explorer}/address/${address}`;

export function NetworkPanel() {
  const { data, account, connect } = useSnapshot();
  const faucet = useFaucet();
  const w = data.wallet;
  return (
    <details className="c-net-tools">
      <summary>Test tokens</summary>
      <div className="c-net-panel">
        <div className="c-net-status">
          <span>Unichain Sepolia</span>
          <b>Block {data.block.toLocaleString("en-US")}</b>
        </div>
        {!data.historySynced && <p>Log index unreachable, logbook may lag</p>}
        {account && w ? (
          <>
            <dl className="c-net-balances" aria-label="Wallet balances">
              <div>
                <dt>tWETH</dt>
                <dd>{token(w.weth, 18, 4)}</dd>
              </div>
              <div>
                <dt>tUSDC</dt>
                <dd>{token(w.usdc, 6, 2)}</dd>
              </div>
              <div>
                <dt>ETH</dt>
                <dd>{token(w.eth, 18, 4)}</dd>
              </div>
            </dl>
            <button
              className="c-outline"
              disabled={faucet.pending}
              onClick={() => void faucet.mint()}
            >
              {faucet.pending ? "Minting..." : "Mint 10 tWETH + 50,000 tUSDC →"}
            </button>
          </>
        ) : (
          <button className="c-outline" onClick={() => void connect()}>
            Connect wallet →
          </button>
        )}
        {faucet.error && (
          <p className="c-error" role="alert">
            {faucet.error}
          </p>
        )}
        <p role="status" className="c-feedback">
          {faucet.message}
        </p>
        <p>
          Gas is paid in Unichain Sepolia ETH, which this faucet does not
          provide.
        </p>
        <p>
          <a href={link(deployment.charter)} target="_blank" rel="noreferrer">
            Charter hook ↗
          </a>{" "}
          ·{" "}
          <a href={link(deployment.weth)} target="_blank" rel="noreferrer">
            tWETH ↗
          </a>{" "}
          ·{" "}
          <a href={link(deployment.usdc)} target="_blank" rel="noreferrer">
            tUSDC ↗
          </a>
        </p>
      </div>
    </details>
  );
}
