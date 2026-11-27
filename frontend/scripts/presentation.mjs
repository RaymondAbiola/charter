import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import axe from "axe-core";
import { injectWallet, launch, loaded } from "./browser.mjs";

const base = process.env.BASE_URL ?? "http://127.0.0.1:3197";
const rpc =
  process.env.NEXT_PUBLIC_RPC_URL ??
  "https://unichain-sepolia-rpc.publicnode.com";
const account =
  process.env.VERIFY_ACCOUNT ?? "0x1Ef0E1De9F0ac2255a42e8987692f89F296dd670";
const output = join(dirname(fileURLToPath(import.meta.url)), "../verification");
mkdirSync(output, { recursive: true });
const passed = [];
const errors = [];
const browser = await launch();
try {
  const page = await browser.newPage();
  page.on("pageerror", (e) => errors.push(e.message));
  await page.setViewport({ width: 1440, height: 1000 });
  for (const screen of ["deposit", "leases", "manager", "activity"]) {
    await page.goto(base, { waitUntil: "networkidle0" });
    await loaded(page);
    await page.click(`.c-journey a[href="/${screen}"]`);
    await page.waitForFunction(
      (path) => location.pathname === path,
      {},
      `/${screen}`,
    );
    assert.equal(
      await page.$eval(
        'nav[aria-label="Charter screens"] a[aria-current]',
        (a) => a.getAttribute("href"),
      ),
      `/${screen}`,
    );
    passed.push(
      `Guided navigation opens /${screen} with the matching active tab`,
    );
  }

  await page.goto(base, { waitUntil: "networkidle0" });
  await loaded(page);
  assert.match(
    await page.$eval(".c-intro-copy", (e) => e.innerText),
    /THE PROBLEM WITH MANAGED LIQUIDITY[\s\S]*price exposure[\s\S]*HOW CHARTER SOLVES IT[\s\S]*passive \+ rent/i,
  );
  await page.click('a[href="#vault-study"]');
  await page.waitForFunction(() => location.hash === "#vault-study");
  assert.ok(
    await page.$eval(
      "#vault-study",
      (e) => e.getBoundingClientRect().top < innerHeight,
    ),
  );
  passed.push(
    "The overview connects manager-chosen exposure to Charter's obligation and links to the study",
  );
  for (const width of [375, 1440]) {
    await page.setViewport({ width, height: 1000 });
    await page.goto(`${base}/deposit`, { waitUntil: "networkidle0" });
    await loaded(page);
    assert.ok(
      await page.$eval(".c-get-tokens", (button) => {
        const r = button.getBoundingClientRect();
        return r.top >= 0 && r.bottom <= innerHeight && !button.disabled;
      }),
    );
    assert.equal(await page.$$eval(".c-setup li", (items) => items.length), 4);
    await page.click(".c-value-presets button");
    await page.waitForFunction(() =>
      document
        .querySelector(".c-deposit-value strong")
        ?.textContent.includes("$"),
    );
    const quoted = await page.$eval(".c-deposit-value strong", (el) =>
      Number(el.textContent.replace(/[^0-9.]/g, "")),
    );
    assert.ok(
      quoted > 95 && quoted < 105,
      `The $100 estimate quotes ${quoted}`,
    );
    assert.ok(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    );
    await page.addScriptTag({ content: axe.source });
    const depositA11y = await page.evaluate(() =>
      window.axe.run(document, {
        runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] },
      }),
    );
    assert.deepEqual(
      depositA11y.violations.map((v) => ({
        id: v.id,
        targets: v.nodes.map((n) => n.target),
      })),
      [],
    );
    await page.screenshot({
      path: join(output, `deposit-setup-${width}.png`),
      fullPage: true,
    });
    passed.push(
      `Deposit setup, a live value preset and token quote fit at ${width}px with no automated A/AA violations`,
    );
    await page.evaluate(() => scrollTo(0, 0));
    await page.focus(".c-get-tokens");
    await page.keyboard.press("Enter");
    await page.waitForSelector("dialog[open]");
    assert.match(
      await page.$eval("dialog", (e) => e.innerText),
      /Connect wallet/,
    );
    assert.ok(
      await page.$eval("dialog", (e) => {
        const r = e.getBoundingClientRect();
        return (
          r.left >= 0 &&
          r.right <= innerWidth &&
          r.top >= 0 &&
          r.bottom <= innerHeight
        );
      }),
    );
    await page.addScriptTag({ content: axe.source });
    const { violations } = await page.evaluate(() =>
      window.axe.run(document, {
        runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] },
      }),
    );
    assert.deepEqual(
      violations.map((v) => ({
        id: v.id,
        targets: v.nodes.map((n) => n.target),
      })),
      [],
      `Faucet dialog at ${width}px meets automated A/AA checks`,
    );
    await page.screenshot({
      path: join(output, `test-tokens-${width}.png`),
      fullPage: false,
    });
    await page.keyboard.press("Escape");
    assert.ok(await page.$eval("dialog", (e) => !e.open));
    assert.ok(
      await page.$eval(".c-get-tokens", (e) => document.activeElement === e),
    );
    passed.push(
      `The visible faucet button opens a keyboard-accessible dialog at ${width}px and Escape restores focus`,
    );
  }

  const walletPage = await browser.newPage();
  walletPage.on("pageerror", (e) => errors.push(e.message));
  await injectWallet(walletPage, { account, rpc, send: false });
  await walletPage.goto(`${base}/manager`, { waitUntil: "networkidle0" });
  await loaded(walletPage);
  await walletPage.waitForSelector(".c-manager-numbers strong");
  for (const width of [375, 768, 1024, 1440]) {
    await walletPage.setViewport({ width, height: 1000 });
    assert.ok(
      await walletPage.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      `Manager at ${width}px fits`,
    );
    assert.ok(
      await walletPage.$$eval(".c-manager-numbers strong", (values) =>
        values.every(
          (el) =>
            el.getBoundingClientRect().right <=
            el.parentElement.getBoundingClientRect().right,
        ),
      ),
      `Manager figures at ${width}px fit`,
    );
    await walletPage.addScriptTag({ content: axe.source });
    const { violations } = await walletPage.evaluate(() =>
      window.axe.run(document, {
        runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] },
      }),
    );
    assert.deepEqual(
      violations.map((v) => ({
        id: v.id,
        targets: v.nodes.map((n) => n.target),
      })),
      [],
      `Manager at ${width}px meets automated A/AA checks`,
    );
    await walletPage.screenshot({
      path: join(output, `manager-connected-${width}.png`),
      fullPage: true,
    });
    passed.push(
      `Connected manager fits at ${width}px with no automated A/AA violations`,
    );
  }

  await walletPage.click(".c-get-tokens");
  await walletPage.waitForSelector("dialog[open]");
  await walletPage.waitForSelector(".c-net-balances");
  assert.match(
    await walletPage.$eval("dialog", (e) => e.innerText),
    /Mint 10 tWETH \+ 50,000 tUSDC/,
  );
  await walletPage.click(".c-net-close");
  passed.push(
    "The connected wallet can reach balances and the unchanged mint action from the header",
  );

  const offline = await browser.newPage();
  await offline.setViewport({ width: 375, height: 1000 });
  let hold = true;
  const waiting = [];
  await offline.setRequestInterception(true);
  offline.on("request", (request) => {
    if (
      !/^https?:/.test(request.url()) ||
      new URL(request.url()).host === new URL(base).host
    )
      void request.continue();
    else if (hold) waiting.push(request);
    else void request.abort("internetdisconnected");
  });
  await offline.goto(base, { waitUntil: "domcontentloaded" });
  await offline.waitForSelector(".c-loading");
  await offline.click(".c-get-tokens");
  await offline.waitForSelector("dialog[open]");
  assert.match(
    await offline.$eval("dialog", (e) => e.innerText),
    /Waiting for a verified vault snapshot/,
  );
  await offline.keyboard.press("Escape");
  passed.push(
    "Faucet access remains visible while the vault is loading and explains snapshot availability",
  );
  assert.ok(await offline.$("#agreement-title"));
  assert.ok(await offline.$(".c-research"));
  assert.equal(await offline.$(".c-capital"), null);
  const evidence = await offline.$eval(".c-research", (e) => e.innerText);
  for (const number of [
    "-12.70%",
    "-14.40%",
    "-14.10%",
    "+12.50%",
    "-2.50%",
    "-1.20%",
    "-2.40%",
    "-1.60%",
  ])
    assert.ok(evidence.includes(number), number);
  await offline.waitForFunction(
    () => document.body.innerText.includes("The network is taking longer"),
    { timeout: 16000 },
  );
  await offline.screenshot({
    path: join(output, "loading-375.png"),
    fullPage: true,
  });
  passed.push(
    "A stalled RPC keeps the agreement and exact evidence visible without invented vault figures",
  );
  hold = false;
  await Promise.all(
    waiting.map((request) => request.abort("internetdisconnected")),
  );
  await offline.waitForSelector('main section[role="alert"]', {
    timeout: 45000,
  });
  assert.ok(await offline.$("#agreement-title"));
  assert.ok(await offline.$(".c-research"));
  assert.ok(await offline.$('main section[role="alert"] button'));
  await offline.screenshot({
    path: join(output, "error-375.png"),
    fullPage: true,
  });
  passed.push(
    "An unavailable RPC keeps the explanation, evidence and retry action visible",
  );
  assert.deepEqual(errors, [], "No browser exceptions");
  writeFileSync(
    join(output, "presentation.json"),
    JSON.stringify({ passed, errors }, null, 2),
  );
  console.log(`Passed ${passed.length} presentation checks.`);
} finally {
  await browser.close();
}
