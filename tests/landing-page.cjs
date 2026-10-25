// Requires Playwright and `playwright install chromium`.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch(process.env.CHROME_PATH
    ? { executablePath: process.env.CHROME_PATH } : {});
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    for (const width of [320, 375, 414, 768, 1280, 1920]) {
      await page.setViewportSize({ width, height: 800 });
      await page.goto(pathToFileURL(path.resolve(__dirname, '../site/index.html')).href);
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
        `Horizontal overflow at ${width}px`);
      assert.ok(await page.locator('img').evaluateAll(images =>
        images.every(image => image.complete && image.naturalWidth > 0)), 'Images must load');
      assert.ok(await page.locator('a').evaluateAll(links => links.every(link => {
        // Check text nodes independently so an aligned arrow/icon isn't a second line.
        const walker = document.createTreeWalker(link, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          if (!node.textContent.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          if (range.getClientRects().length > 1) return false;
        }
        return true;
      })), `Wrapped link at ${width}px`);
      if (process.env.DELTA_SCRATCH_DIR) {
        await page.screenshot({
          path: path.join(process.env.DELTA_SCRATCH_DIR, `landing-${width}.png`), fullPage: true,
        });
      }
      console.log(`PASS: landing page layout, images, and links at ${width}px`);
    }
    await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => document.activeElement.className), 'skip');
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(() => location.hash), '#main');
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
