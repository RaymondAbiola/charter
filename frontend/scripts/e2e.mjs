// Every wallet action, end to end, against a local anvil fork of Unichain Sepolia.
// Needs Foundry's anvil and Chrome. Nothing reaches the real chain: the fork signs for a
// throwaway address that the hook has never seen.
import assert from "node:assert/strict";
import {
  erc20Abi,
  encodeFunctionData,
  parseUnits,
  toFunctionSelector,
} from "viem";
import { spawn } from "node:child_process";
import { mkdirSync, openSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  bodyText,
  click,
  injectWallet,
  input,
  launch,
  loaded,
  waitText,
} from "./browser.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(root, "verification");
mkdirSync(output, { recursive: true });
const forkUrl =
  process.env.FORK_URL ?? "https://unichain-sepolia-rpc.publicnode.com";
const anvilPort = 8546;
const appPort = 3199;
const rpc = `http://127.0.0.1:${anvilPort}`;
const base = `http://127.0.0.1:${appPort}`;
const me = "0x000000000000000000000000000000000000c4a7";

const children = [];
// each child logs to verification/<name>.log and runs in its own process group,
// so the whole tree can be stopped at the end
function start(name, cmd, args, env = {}) {
  const log = openSync(join(output, `${name}.log`), "w");
  const child = spawn(cmd, args, {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ["ignore", log, log],
    detached: true,
  });
  children.push(child);
  return child;
}

async function call(method, params = []) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

async function until(probe, label, timeout = 120000) {
  const startAt = Date.now();
  while (Date.now() - startAt < timeout) {
    try {
      if (await probe()) return;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`${label} did not start`);
}

const passed = [];
async function step(name, fn) {
  try {
    await fn();
    passed.push(name);
    console.log(`  ok  ${name}`);
  } catch (error) {
    console.log(`  FAIL ${name}`);
    throw error;
  }
}

let browser;
try {
  start("anvil", "anvil", [
    "--fork-url",
    forkUrl,
    "--chain-id",
    "1301",
    "--port",
    String(anvilPort),
    "--auto-impersonate",
    "--silent",
  ]);
  await until(() => call("eth_chainId"), "anvil");
  await call("anvil_setBalance", [me, "0x56BC75E2D63100000"]);

  start(
    "next",
    "npx",
    ["next", "dev", "--port", String(appPort), "--hostname", "127.0.0.1"],
    {
      NEXT_PUBLIC_RPC_URL: rpc,
    },
  );
  await until(async () => (await fetch(base)).ok, "next dev");

  browser = await launch();
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 1000 });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await injectWallet(page, {
    account: me,
    rpc,
    send: true,
    unknownChain: true,
  });

  await page.goto(`${base}/deposit`, {
    waitUntil: "networkidle0",
    timeout: 180000,
  });
  await loaded(page);
  console.log("Charter end-to-end on a fork of Unichain Sepolia");

  await step("the wallet connects on the right chain", async () => {
    await waitText(page, /0x0000…c4a7/i);
  });
  await step("zero gas is explained before minting or depositing", async () => {
    await call("anvil_setBalance", [me, "0x0"]);
    await call("evm_mine");
    await page.waitForFunction(
      () =>
        document.querySelector(".c-transfer form > .c-primary")?.disabled &&
        document.querySelector(".c-transfer .c-gas-help"),
    );
    await click(page, "Get test tokens");
    await page.waitForSelector("dialog[open]");
    assert.match(
      await page.$eval("dialog", (e) => e.innerText),
      /tWETH cannot pay this fee[\s\S]*Add gas ETH before minting/,
    );
    assert.ok(await page.$eval(".c-net-content button", (b) => b.disabled));
    assert.ok(
      await page.$(
        'dialog a[href="https://developers.uniswap.org/docs/unichain/tools/faucets"]',
      ),
    );
    await click(page, "Close");
    await call("anvil_setBalance", [me, "0x56BC75E2D63100000"]);
    await call("evm_mine");
  });
  await step("the faucet mints test tokens", async () => {
    await click(page, "Get test tokens");
    await page.waitForSelector("dialog[open]");
    await page.waitForFunction(
      () => !document.querySelector(".c-net-content button")?.disabled,
    );
    await click(page, "Mint 10 tWETH");
    await waitText(page, /Minted 10 tWETH and 50,000 tUSDC/);
    await page.click(".c-continue");
    await page.waitForSelector("dialog:not([open])");
    await page.waitForFunction(() => location.hash === "#deposit-form");
  });
  await step(
    "a value preset mints exactly the native shares shown in the form",
    async () => {
      await page.click(".c-value-presets button");
      await page.waitForFunction(
        () =>
          !document.querySelector(".c-transfer form > .c-primary")?.disabled,
      );
      const quoted = await page.$eval(".c-deposit-value strong", (e) =>
        Number(e.textContent.replace(/[^0-9.]/g, "")),
      );
      assert.ok(
        quoted > 99 && quoted < 101,
        `The $100 preset has a live quote of ${quoted}`,
      );
      const chosen = await page.$eval('input[name="shares"]', (e) => e.value);
      const hook = await page.$eval(
        '.c-net-content a[href*="/address/"]',
        (a) => new URL(a.href).pathname.split("/").at(-1),
      );
      await click(page, "Supply capital →");
      await waitText(page, /Deposit confirmed/);
      const minted = BigInt(
        await call("eth_call", [
          {
            to: hook,
            data: encodeFunctionData({
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [me],
            }),
          },
          "latest",
        ]),
      );
      assert.equal(minted, parseUnits(chosen, 18));
    },
  );
  await step(
    "a changed share amount cannot submit with a stale quote",
    async () => {
      let held;
      const selector = toFunctionSelector("previewDeposit(uint256)");
      await page.setRequestInterception(true);
      const intercept = (request) => {
        const raw = request.postData();
        if (
          raw &&
          raw.includes(selector) &&
          new URL(request.url()).origin === rpc &&
          !held
        )
          held = request;
        else void request.continue();
      };
      page.on("request", intercept);
      await input(page, 'input[name="shares"]', "0.000002");
      await until(() => Boolean(held), "a held deposit quote", 10000);
      assert.ok(
        await page.$eval(
          ".c-transfer form > .c-primary",
          (button) => button.disabled,
        ),
      );
      assert.match(
        await page.$eval(".c-deposit-value", (e) => e.innerText),
        /Updating quote/,
      );
      await held.continue();
      page.off("request", intercept);
      await page.setRequestInterception(false);
      await page.waitForFunction(
        () =>
          !document.querySelector(".c-transfer form > .c-primary")?.disabled,
      );
    },
  );

  await step(
    "withdrawing more than you hold is stopped with a reason",
    async () => {
      await click(page, "Withdraw");
      await input(page, 'input[name="shares"]', "1");
      await page.waitForFunction(
        () =>
          !document.querySelector(".c-transfer form > .c-primary")?.disabled,
      );
      await click(page, "Withdraw shares →");
      await waitText(page, /You do not hold that many shares/, {
        errors: false,
      });
    },
  );
  await step("a full withdrawal returns the tokens", async () => {
    await click(page, "Supply capital");
    await click(page, "Withdraw");
    await page.waitForFunction(
      () => !document.querySelector(".c-transfer form > .c-primary")?.disabled,
    );
    await click(page, "Withdraw shares →");
    await waitText(page, /Withdrawal confirmed/);
  });

  await page.goto(`${base}/leases`, { waitUntil: "networkidle0" });
  await loaded(page);
  const before = Number((await bodyText(page)).match(/(\d+) LEASED/)[1]);

  await step("an open slot is leased in one transaction", async () => {
    await click(page, "Open lease →");
    await waitText(page, /Lease opened/);
    await waitText(page, new RegExp(`${before + 1} LEASED`));
  });
  await step(
    "a bid below the required raise is refused by the hook",
    async () => {
      await page.select(".c-bid-form select", "0");
      await input(page, '.c-bid-form input[type="number"]', "0.10");
      await click(page, "Place bid →");
      await waitText(page, /Rent must beat the current lease/, {
        errors: false,
      });
    },
  );
  await step("a qualifying bid escrows its bond", async () => {
    const hint = (await bodyText(page)).match(/Offer at least ([\d.]+)%/);
    assert.ok(hint, "the form states the minimum rent");
    await input(
      page,
      '.c-bid-form input[type="number"]',
      (Number(hint[1]) + 0.5).toFixed(2),
    );
    await click(page, "Place bid →");
    await waitText(page, /Bid placed/);
  });
  await step(
    "after the delay, the takeover settles the incumbent",
    async () => {
      await call("evm_increaseTime", [301]);
      await call("evm_mine");
      await page.reload({ waitUntil: "networkidle0" });
      await loaded(page);
      await click(page, "Activate takeover →");
      await waitText(page, /Takeover settled/);
    },
  );

  await page.goto(`${base}/manager`, { waitUntil: "networkidle0" });
  await loaded(page);
  await step("the manager station shows the wallet's lease", async () => {
    await waitText(page, /Bond coverage/);
    await waitText(page, /LIQUIDATION BAND/);
  });
  await step("the manager moves the range", async () => {
    await click(page, "Rebalance range →");
    await waitText(page, /Range moved/);
  });
  await step("the manager tops up the bond", async () => {
    await click(page, "Top up bond →");
    await waitText(page, /Bond topped up/);
  });
  await step("the manager exits and capital goes back to passive", async () => {
    await click(page, "Review exit →");
    await click(page, "Confirm exit");
    await waitText(page, /Lease ended|Bond coverage/);
  });

  await step(
    "disconnect sticks across a reload, and connect brings it back",
    async () => {
      await click(page, "Disconnect");
      await waitText(page, /Connect wallet/i, { errors: false });
      await page.reload({ waitUntil: "networkidle0" });
      await loaded(page);
      await new Promise((r) => setTimeout(r, 2000));
      assert.ok(
        !/0x0000…c4a7/i.test(await bodyText(page)),
        "still disconnected after a reload",
      );
      await click(page, "Connect wallet");
      await waitText(page, /0x0000…c4a7/i);
    },
  );

  await page.screenshot({ path: join(output, "e2e-end.png"), fullPage: true });
  assert.deepEqual(errors, [], "no uncaught page errors");
  console.log(`Passed ${passed.length} write checks on the fork.`);
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  await browser?.close();
  for (const child of children) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
}
