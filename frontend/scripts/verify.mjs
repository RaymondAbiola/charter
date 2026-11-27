// Read-only browser check of a running build against the live contracts on Unichain Sepolia.
// It never sends a transaction: the injected wallet refuses every one.
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import axe from "axe-core";
import { click, injectWallet, launch, loaded, waitText } from "./browser.mjs";

const base = process.env.BASE_URL ?? "http://127.0.0.1:3197";
const rpc =
  process.env.NEXT_PUBLIC_RPC_URL ??
  "https://unichain-sepolia-rpc.publicnode.com";
// the deployer seeded the vault, so it holds shares, tokens and the slot 0 lease
const account =
  process.env.VERIFY_ACCOUNT ?? "0x1Ef0E1De9F0ac2255a42e8987692f89F296dd670";
const allowedHosts = new Set([
  new URL(base).host,
  new URL(rpc).host,
  "sepolia.unichain.org",
  "unichain-sepolia.blockscout.com",
]);
const screens = ["", "deposit", "leases", "manager", "activity"];
const output = join(dirname(fileURLToPath(import.meta.url)), "../verification");
mkdirSync(output, { recursive: true });

const passed = [];
const errors = [];
const strangers = new Set();
const failed = [];
const accessibility = [];

function watch(page) {
  page.on("pageerror", (e) => errors.push(`${page.url()}: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(`${page.url()}: ${m.text()}`);
  });
  page.on("request", (r) => {
    const url = new URL(r.url());
    if (/^https?:$/.test(url.protocol) && !allowedHosts.has(url.host))
      strangers.add(url.host);
  });
  page.on("requestfailed", (r) =>
    failed.push(`${r.url()}: ${r.failure()?.errorText}`),
  );
}

async function fits(page, label) {
  const overflow = await page.evaluate(() => {
    if (document.documentElement.scrollWidth <= innerWidth) return [];
    return [...document.querySelectorAll("main *")]
      .filter(
        (el) =>
          el.getBoundingClientRect().right > innerWidth + 1 &&
          !el.closest('[class*="table-wrap"], .recharts-wrapper'),
      )
      .slice(0, 6)
      .map((el) => `${el.tagName}.${el.className}`);
  });
  assert.deepEqual(overflow, [], `${label}: nothing overflows the page`);
}

/** Catches a collapsed layout, which text and accessibility checks alone let through. */
async function laidOut(page, label, width) {
  const layout = await page.evaluate(() => {
    const side = document.querySelector(".c-sidebar");
    const skip = document.querySelector(".c-skip");
    const links = [
      ...document.querySelectorAll('nav[aria-label="Charter screens"] a'),
    ];
    return {
      pageWidth: document.documentElement.scrollWidth,
      sidebarPosition: side ? getComputedStyle(side).position : null,
      skipBottom: skip ? skip.getBoundingClientRect().bottom : null,
      navRows: new Set(
        links.map((a) => Math.round(a.getBoundingClientRect().top)),
      ).size,
      navCount: links.length,
    };
  });
  assert.ok(
    layout.pageWidth <= width + 1,
    `${label}: the page does not scroll sideways`,
  );
  assert.ok(
    layout.skipBottom !== null && layout.skipBottom <= 0,
    `${label}: the skip link stays hidden until focused`,
  );
  if (width >= 1200) {
    assert.equal(
      layout.sidebarPosition,
      "fixed",
      `${label}: the sidebar is fixed`,
    );
    assert.equal(
      layout.navRows,
      layout.navCount,
      `${label}: one navigation link per row`,
    );
  }
}

const browser = await launch();
try {
  const page = await browser.newPage();
  await page.setCacheEnabled(false);
  watch(page);

  for (const width of [1440, 375]) {
    await page.setViewport({ width, height: 1000, deviceScaleFactor: 1 });
    for (const screen of screens) {
      const route = `/${screen}`;
      const label = `${route} at ${width}px`;
      const response = await page.goto(base + route, {
        waitUntil: "networkidle0",
      });
      assert.equal(response.status(), 200, `${label}: status`);
      assert.ok(
        await page.$eval(".c-get-tokens", (button) => {
          const r = button.getBoundingClientRect();
          return r.top >= 0 && r.bottom <= innerHeight && !button.disabled;
        }),
        `${label}: test tokens are visible above the fold`,
      );
      await loaded(page);
      const main = await page.$eval("main", (m) => m.innerText);
      assert.ok(!/Chain signal unavailable/.test(main), `${label}: chain read`);
      if (width === 1440)
        assert.match(main, /BLOCK [\d,]+/, `${label}: live block number`);
      if (!screen) {
        for (const figure of ["-12.70%", "-14.40%", "-14.10%", "+12.50%"])
          assert.ok(main.includes(figure), `${label}: study figure ${figure}`);
        assert.match(main, /LEASED\s+[\d.]+%/, `${label}: capital split`);
      }
      if (screen === "leases") {
        assert.match(main, /\d+ LEASED \/ \d+ PENDING/, `${label}: register`);
        assert.ok(await page.$(".c-range svg"), `${label}: depth chart`);
      }
      if (screen === "activity")
        await waitText(page, /\d+ ENTRIES \/ LIVE/, { errors: false });
      await fits(page, label);
      await laidOut(page, label, width);
      if (width === 375) {
        await page.addScriptTag({ content: axe.source });
        const result = await page.evaluate(() =>
          window.axe.run(document, {
            runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21aa"] },
          }),
        );
        accessibility.push({
          route,
          violations: result.violations.map((v) => ({
            id: v.id,
            impact: v.impact,
            targets: v.nodes.map((n) => n.target),
          })),
        });
      }
      await page.screenshot({
        path: join(output, `${screen || "overview"}-${width}.png`),
        fullPage: true,
      });
      passed.push(`${label} renders live data`);
    }
  }

  for (const legacy of ["/c", "/c/leases"]) {
    await page.goto(base + legacy, { waitUntil: "networkidle0" });
    assert.equal(new URL(page.url()).pathname, legacy.replace("/c", "") || "/");
  }
  assert.equal(await page.title(), "Charter | Liquidity under contract");
  passed.push("legacy /c routes redirect and the title is set");

  // a second visitor with a wallet that refuses to sign
  const walletPage = await browser.newPage();
  watch(walletPage);
  await walletPage.setViewport({ width: 1440, height: 1000 });
  await injectWallet(walletPage, { account, rpc, send: false });
  await walletPage.goto(`${base}/deposit`, { waitUntil: "networkidle0" });
  await loaded(walletPage);
  const short = `${account.slice(0, 6)}…${account.slice(-4)}`;
  await waitText(walletPage, new RegExp(short.replace("…", "."), "i"), {
    errors: false,
  });
  await walletPage.waitForSelector(".c-wallet-balances");
  passed.push("an existing wallet connection is picked up without a prompt");

  await walletPage.waitForFunction(
    () => !document.querySelector(".c-transfer form > .c-primary")?.disabled,
  );
  await click(walletPage, "Supply capital →");
  await waitText(
    walletPage,
    /You rejected the request in your wallet|Not enough test tokens/,
    { errors: false },
  );
  passed.push("a refused signature surfaces as a plain sentence");

  await walletPage.goto(`${base}/manager`, { waitUntil: "networkidle0" });
  await loaded(walletPage);
  await waitText(walletPage, /Bond coverage|No lease on station/, {
    errors: false,
  });
  passed.push("the manager station follows the connected wallet");

  // a refused signature is the one console error this run causes on purpose
  const unexpected = errors.filter((e) => !/rejected the request/i.test(e));
  writeFileSync(
    join(output, "report.json"),
    JSON.stringify(
      {
        base,
        passed,
        errors: unexpected,
        strangers: [...strangers],
        failed,
        accessibility,
      },
      null,
      2,
    ),
  );
  assert.deepEqual([...strangers], [], "no requests to unexpected hosts");
  assert.deepEqual(unexpected, [], "no browser errors or hydration mismatches");
  assert.deepEqual(
    accessibility.filter((a) => a.violations.length),
    [],
    "no automated WCAG A or AA violations",
  );
  console.log(
    `Passed ${passed.length} live checks. Report and screenshots: ${output}`,
  );
} finally {
  await browser.close();
}
