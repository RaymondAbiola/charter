import assert from "node:assert/strict";
import puppeteer from "puppeteer-core";

export const chrome = process.env.CHROME_PATH ?? "/usr/bin/google-chrome";

export const launch = () =>
  puppeteer.launch({
    executablePath: chrome,
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });

/**
 * Stands in for a browser wallet. Reads and sends go to `rpc`. With `send: false` every
 * transaction is refused, so a check against the live chain can never spend anything.
 */
export async function injectWallet(page, { account, rpc, send }) {
  await page.evaluateOnNewDocument(
    (account, rpc, send) => {
      const call = async (method, params) => {
        const res = await fetch(rpc, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        });
        const body = await res.json();
        if (body.error) {
          const error = new Error(body.error.message);
          error.code = body.error.code;
          error.data = body.error.data;
          throw error;
        }
        return body.result;
      };
      window.ethereum = {
        async request({ method, params }) {
          if (method === "eth_requestAccounts" || method === "eth_accounts")
            return [account];
          if (method === "eth_chainId") return "0x515";
          if (
            method === "wallet_switchEthereumChain" ||
            method === "wallet_addEthereumChain"
          )
            return null;
          if (method === "eth_sendTransaction" && !send) {
            const error = new Error("User rejected the request.");
            error.code = 4001;
            throw error;
          }
          return call(method, params);
        },
        on() {},
        removeListener() {},
      };
    },
    account,
    rpc,
    send,
  );
}

export const bodyText = (page) => page.evaluate(() => document.body.innerText);

/** Waits for `pattern` in the page, failing early if the UI shows an error line. */
export async function waitText(
  page,
  pattern,
  { timeout = 90000, errors = true } = {},
) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (pattern.test(await bodyText(page))) return;
    if (errors) {
      const shown = await page.$$eval(".c-error", (els) =>
        els.map((e) => e.innerText).join(" | "),
      );
      if (shown)
        throw new Error(`UI error while waiting for ${pattern}: ${shown}`);
    }
    await new Promise((r) => setTimeout(r, 400));
  }
  throw new Error(`Timed out waiting for ${pattern}`);
}

export async function click(page, label) {
  const found = await page.evaluate((label) => {
    const button = [...document.querySelectorAll("button")].find((b) =>
      b.innerText.trim().startsWith(label),
    );
    if (!button || button.disabled) return false;
    button.click();
    return true;
  }, label);
  assert.ok(found, `button "${label}" is present and enabled`);
}

export async function input(page, selector, value) {
  await page.$eval(
    selector,
    (el, value) => {
      const proto = Object.getPrototypeOf(el);
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    },
    value,
  );
}

/** Waits until the first chain snapshot has replaced the loading state. */
export const loaded = (page) =>
  page.waitForFunction(
    () =>
      document.querySelector("main h1") &&
      !document.body.innerText.includes("Reading the instruments"),
    { timeout: 90000 },
  );
