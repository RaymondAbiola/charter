"use client";

import { formatUnits } from "viem";
import { useSnapshot } from "@/state/provider";
import { address } from "@/lib/format";
import { gasFaucetsUrl } from "@/lib/onboarding";

export function GasHelp({ eth }: { eth?: bigint }) {
  return (
    <aside className="c-gas-help" aria-label="Gas requirements">
      <p className="c-eyebrow">GAS COMES FIRST</p>
      <h3>ETH pays the fee. tWETH supplies the pool.</h3>
      <p>
        You need native ETH on <b>Unichain Sepolia</b> to mint tokens, approve
        them and deposit. ETH on another network and tWETH cannot pay this fee.
      </p>
      {eth !== undefined && (
        <p className="c-gas-balance">
          Gas balance: <strong>{formatUnits(eth, 18)} ETH</strong>
          {eth === 0n
            ? ". Add gas ETH before minting."
            : ". Your wallet checks the fee before you confirm."}
        </p>
      )}
      <a href={gasFaucetsUrl} target="_blank" rel="noreferrer">
        View gas faucets <span aria-hidden="true">↗</span>
      </a>
    </aside>
  );
}

export function DepositSetup({ onGetTokens }: { onGetTokens: () => void }) {
  const { account, data, connect } = useSnapshot();
  const w =
    data.wallet?.address.toLowerCase() === account?.toLowerCase()
      ? data.wallet
      : null;
  const gas = w ? w.eth > 0n : false;
  const tokens = w ? w.weth > 0n && w.usdc > 0n : false;
  return (
    <section className="c-setup" aria-labelledby="deposit-setup-title">
      <div className="c-panel-heading">
        <div>
          <p className="c-eyebrow">BEFORE YOUR FIRST DEPOSIT</p>
          <h2 id="deposit-setup-title">Four steps. One live position.</h2>
        </div>
        <span>UNICHAIN SEPOLIA / TEST TOKENS</span>
      </div>
      <ol>
        <li>
          <span>01</span>
          <div>
            <h3>Connect your wallet</h3>
            <p>
              {account
                ? `${address(account)} connected`
                : "The wallet switches to Unichain Sepolia."}
            </p>
            {!account && (
              <button
                type="button"
                className="c-text-button"
                onClick={() => void connect()}
              >
                Connect wallet →
              </button>
            )}
            {account && <b className="c-setup-done">Connected</b>}
          </div>
        </li>
        <li>
          <span>02</span>
          <div>
            <h3>Add gas ETH</h3>
            <p>
              Native ETH on this network pays transaction fees. tWETH cannot pay
              gas.
            </p>
            <a href={gasFaucetsUrl} target="_blank" rel="noreferrer">
              View gas faucets ↗
            </a>
            {gas && <b className="c-setup-done">ETH balance detected</b>}
          </div>
        </li>
        <li>
          <span>03</span>
          <div>
            <h3>Mint test tokens</h3>
            <p>Get tWETH and tUSDC for the pool. Minting also needs gas ETH.</p>
            <button
              type="button"
              className="c-text-button"
              onClick={onGetTokens}
            >
              Get test tokens →
            </button>
            {tokens && <b className="c-setup-done">Token balances detected</b>}
          </div>
        </li>
        <li>
          <span>04</span>
          <div>
            <h3>Choose a value</h3>
            <p>
              Pick an approximate value below. Review both token amounts,
              approve them and confirm the deposit.
            </p>
            <a href="#deposit-form">Review your deposit ↓</a>
          </div>
        </li>
      </ol>
    </section>
  );
}
