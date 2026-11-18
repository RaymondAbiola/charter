import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";
import axe from "axe-core";

const base = "http://127.0.0.1:3197";
const output = join(dirname(fileURLToPath(import.meta.url)), "../verification");
mkdirSync(output, { recursive: true });
const report = [];

(async () => {
  const browser = await puppeteer.launch({
    executablePath: "/usr/bin/google-chrome",
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  });
  const errors = [],
    external = [],
    failed = [],
    accessibility = [];
  try {
    const page = await browser.newPage();
    await page.setCacheEnabled(false);
    page.on("pageerror", (error) =>
      errors.push(`${page.url()}: ${error.message}`),
    );
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    page.on("request", (request) => {
      if (/^https?:/.test(request.url()) && !request.url().startsWith(base))
        external.push(request.url());
    });
    page.on("requestfailed", (request) => failed.push(request.url()));
    async function waitText(text) {
      try {
        await page.waitForFunction(
          (text) => document.body.innerText.includes(text),
          { timeout: 15000 },
          text,
        );
      } catch (error) {
        await page.screenshot({
          path: join(output, "failure.png"),
          fullPage: true,
        });
        writeFileSync(
          join(output, "failure.txt"),
          await page.$eval("body", (element) => element.innerText),
        );
        throw error;
      }
    }
    async function click(label) {
      await page.evaluate((label) => {
        const button = [...document.querySelectorAll("button")].find(
          (button) =>
            button.innerText.trim().toLowerCase() === label.toLowerCase(),
        );
        if (!button) throw new Error(`Missing button: ${label}`);
        button.click();
      }, label);
    }
    async function input(selector, value) {
      await page.$eval(
        selector,
        (input, value) => {
          Object.getOwnPropertyDescriptor(
            HTMLInputElement.prototype,
            "value",
          ).set.call(input, value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
        },
        value,
      );
    }
    async function controls() {
      await page.$eval(".c-mock-tools", (details) => {
        details.open = true;
      });
    }
    async function persona(value) {
      await controls();
      await page.select(".mock-controls label:first-child select", value);
      await page.$eval(".c-mock-tools", (details) => {
        details.open = false;
      });
    }
    async function scenario(value) {
      await controls();
      await page.select(".mock-controls label:nth-child(2) select", value);
      await page.$eval(".c-mock-tools", (details) => {
        details.open = false;
      });
    }
    async function fits(label) {
      const overflow = await page.evaluate(() => {
        if (document.documentElement.scrollWidth <= innerWidth) return [];
        return [...document.querySelectorAll("main *")]
          .filter(
            (element) =>
              element.getBoundingClientRect().right > innerWidth + 1 &&
              !element.closest(
                '[class*="scroll"], [class*="table-wrap"], .recharts-wrapper',
              ),
          )
          .slice(0, 6)
          .map((element) => `${element.tagName}.${element.className}`);
      });
      assert.deepEqual(overflow, [], label);
      assert.ok(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        `${label}: no document overflow`,
      );
      assert.ok(
        await page.$$eval(".c-manager-numbers strong", (values) =>
          values.every(
            (value) =>
              value.getBoundingClientRect().right <=
              value.parentElement.getBoundingClientRect().right,
          ),
        ),
        `${label}: figures fit their metric cells`,
      );
    }
    for (const width of [1440, 375]) {
      await page.setViewport({ width, height: 1000, deviceScaleFactor: 1 });
      for (const screen of ["", "deposit", "leases", "manager", "activity"]) {
        const route = screen ? `/${screen}` : "/";
        const response = await page.goto(base + route, {
          waitUntil: "networkidle0",
        });
        assert.equal(response.status(), 200);
        await page.waitForSelector("main h1");
        if (screen === "manager") {
          await persona("manager");
          await page.waitForFunction(() =>
            /Bond|BOND/.test(document.querySelector("main").innerText),
          );
        }
        if (!screen) {
          const text = await page.$eval("main", (element) => element.innerText);
          for (const figure of [
            "-12.70%",
            "-14.40%",
            "-14.10%",
            "+12.50%",
            "-2.50%",
            "-1.20%",
            "-2.40%",
            "-1.60%",
          ])
            assert.ok(
              text.includes(figure),
              `${route}: exact evidence ${figure}`,
            );
        }
        await fits(`${route} at ${width}px`);
        await page.$eval(".c-mock-tools", (details) => {
          details.open = false;
        });
        if (width === 375) {
          await page.addScriptTag({ content: axe.source });
          const result = await page.evaluate(async () =>
            window.axe.run(document, {
              runOnly: {
                type: "tag",
                values: ["wcag2a", "wcag2aa", "wcag21aa"],
              },
            }),
          );
          accessibility.push({
            route,
            violations: result.violations.map((rule) => ({
              id: rule.id,
              impact: rule.impact,
              nodes: rule.nodes.map((node) => ({
                target: node.target,
                summary: node.failureSummary,
              })),
            })),
          });
        }
        await page.screenshot({
          path: join(output, `charter-${screen || "overview"}-${width}.png`),
          fullPage: true,
        });
        report.push(`${route} renders at ${width}px`);
      }
    }
    await page.setViewport({
      width: 1280,
      height: 1000,
      deviceScaleFactor: 1,
    });
    await page.goto(`${base}/deposit`, {
      waitUntil: "networkidle0",
    });
    await persona("depositor");
    await page.click("main form button");
    await waitText("Mock deposit complete.");
    await click("Withdraw");
    await page.click("main form button");
    await waitText("Mock withdrawal complete.");
    await input("input[name=shares]", "999999999");
    await page.click("main form button");
    await waitText("You do not have enough Charter shares.");
    report.push(`deposit, withdraw, insufficient-share error`);

    await page.goto(`${base}/leases`, {
      waitUntil: "networkidle0",
    });
    await persona("manager");
    const sliders = await page.$$("input[type=range]");
    assert.equal(sliders.length, 2);
    await sliders[0].focus();
    await page.keyboard.press("ArrowLeft");
    await page.click("main form button");
    await waitText("Mock bid placed.");
    report.push(`range picker and bid countdown`);

    await page.goto(`${base}/manager`, {
      waitUntil: "networkidle0",
    });
    await persona("manager");
    await click("Rebalance range →");
    await waitText("Mock range updated.");
    await click("Top up bond →");
    await waitText("Mock bond topped up.");
    await click("Review exit →");
    await click("Confirm exit");
    await waitText("Mock lease exited.");
    report.push(`rebalance, bond top-up, confirmed exit`);

    await page.goto(`${base}/activity`, {
      waitUntil: "networkidle0",
    });
    await page.select("main select", "Liquidated");
    const feedSelector = ".c-logbook ol";
    await page.waitForFunction(
      (selector) => {
        const feed = document.querySelector(selector);
        return (
          feed &&
          feed.innerText.includes("Liquidated") &&
          !feed.innerText.includes("BidPlaced")
        );
      },
      {},
      feedSelector,
    );
    await scenario("empty");
    await page.waitForFunction(() =>
      /No matching|Nothing in this view|No entries/.test(
        document.querySelector("main").innerText,
      ),
    );
    await scenario("loading");
    assert.ok(await page.$("main [role=status]"));
    await scenario("error");
    assert.ok(await page.$("main [role=alert]"));
    const retry = await page.$("main button");
    await retry.click();
    await page.waitForFunction(
      () => !document.querySelector("main [role=alert]"),
    );
    report.push(`activity filter, empty, loading and retry states`);
    await scenario("ready");
    await persona("manager");
    await page.click('nav[aria-label="Charter screens"] a[href="/leases"]');
    await page.waitForFunction(() => location.pathname === "/leases");
    assert.equal(
      await page.$eval(
        ".mock-controls label:first-child select",
        (select) => select.value,
      ),
      "manager",
    );
    assert.equal(
      await page.$eval(
        'nav[aria-label="Charter screens"] a[aria-current="page"]',
        (link) => link.getAttribute("href"),
      ),
      "/leases",
    );
    report.push("Navigation uses canonical routes and preserves the persona");
    for (const screen of ["", "deposit", "leases", "manager", "activity"]) {
      await page.goto(`${base}/c${screen ? `/${screen}` : ""}`, {
        waitUntil: "networkidle0",
      });
      assert.equal(new URL(page.url()).pathname, screen ? `/${screen}` : "/");
      assert.ok(await page.$(".nautical"));
    }
    report.push(
      "All five legacy Charter routes redirect to the selected design",
    );
    await page.goto(base, { waitUntil: "networkidle0" });
    assert.equal((await page.$$("iframe")).length, 0);
    assert.equal((await page.$$(".direction-switcher")).length, 0);
    assert.equal(await page.title(), "Charter | Liquidity under contract");
    report.push("Root opens Charter without the design comparison");
    assert.deepEqual(external, [], "no external browser requests");
    assert.deepEqual(failed, [], "no failed requests");
    writeFileSync(
      join(output, "report.json"),
      JSON.stringify(
        { passed: report, errors, external, failed, accessibility },
        null,
        2,
      ),
    );
    assert.deepEqual(errors, [], "no browser errors or hydration mismatches");
    assert.deepEqual(
      accessibility.filter((page) => page.violations.length),
      [],
      "no automated WCAG A or AA violations",
    );
    console.log(
      `Passed ${report.length} browser checks. Screenshots and report: ${output}`,
    );
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
