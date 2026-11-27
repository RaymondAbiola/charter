"use client";

import type { RefObject } from "react";
import Link from "next/link";
import { GasHelp } from "./onboarding";
import { deployment } from "@/chain/deployment";
import { useChain, useSnapshot } from "@/state/provider";
import { useFaucet } from "@/state/models";
import { token } from "@/lib/format";

const link = (address: string) => `${deployment.explorer}/address/${address}`;

export function NetworkPanel({
  dialogRef: dialog,
}: {
  dialogRef: RefObject<HTMLDialogElement | null>;
}) {
  const { data, account, connect, connectError } = useChain();
  return (
    <>
      <button
        type="button"
        className="c-outline c-get-tokens"
        aria-haspopup="dialog"
        aria-controls="test-tokens-dialog"
        onClick={() => dialog.current?.showModal()}
      >
        Get test tokens
      </button>
      <dialog
        ref={dialog}
        id="test-tokens-dialog"
        className="c-net-dialog"
        aria-labelledby="test-tokens-title"
        aria-describedby="test-tokens-description"
      >
        <div className="c-net-panel">
          <div className="c-net-title">
            <h2 id="test-tokens-title">Get test tokens</h2>
            <button
              type="button"
              className="c-text-button c-net-close"
              aria-label="Close test token dialog"
              onClick={() => dialog.current?.close()}
            >
              Close
            </button>
          </div>
          <p id="test-tokens-description">
            Mint tWETH and tUSDC to try Charter on Unichain Sepolia. These are
            test tokens with no real value.
          </p>
          {data ? (
            <FaucetContent onContinue={() => dialog.current?.close()} />
          ) : (
            <div className="c-net-waiting">
              <GasHelp />
              <p role="status">
                Waiting for a verified vault snapshot before token minting is
                available.
              </p>
              {!account && (
                <button className="c-outline" onClick={() => void connect()}>
                  Connect wallet →
                </button>
              )}
            </div>
          )}
          {connectError && (
            <p className="c-error" role="alert">
              {connectError}
            </p>
          )}
        </div>
      </dialog>
    </>
  );
}

function FaucetContent({ onContinue }: { onContinue: () => void }) {
  const { data, account, connect } = useSnapshot();
  const faucet = useFaucet();
  const w = data.wallet;
  return (
    <div className="c-net-content">
      <div className="c-net-status">
        <span>Unichain Sepolia</span>
        <b>Block {data.block.toLocaleString("en-US")}</b>
      </div>
      <GasHelp eth={w?.eth} />
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
            disabled={faucet.pending || w.eth === 0n}
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
      {account && w && w.weth > 0n && w.usdc > 0n && (
        <Link
          className="c-continue c-primary"
          href="/deposit#deposit-form"
          onClick={onContinue}
        >
          Continue to deposit →
        </Link>
      )}
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
  );
}
