// Requires Playwright and `playwright install webkit`.
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const { webkit } = require('playwright');

(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage();
    await page.goto(pathToFileURL(path.resolve(__dirname, '../app.html')).href);
    await page.waitForFunction(() => window.App?.editors[0].note);
    for (const tail of ['', '\nTail of note']) {
    for (const prefix of ['- ', '* ', '[] ', '- [ ] ', '[x] ', '1. ']) {
      await page.evaluate(tail => {
        const ed = App.editors[0];
        ed.focus();
        ed.commit(tail, { start: 0, end: 0 });
      }, tail);
      await page.keyboard.type(prefix);
      assert.ok(await page.evaluate(() => {
        const ed = App.editors[0], sel = getSelection();
        const element = sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement;
        const lineEnd = ed.text.includes('\n') ? ed.text.indexOf('\n') : ed.text.length;
        return ed.el.firstElementChild.contains(sel.anchorNode) &&
          !element.closest('[contenteditable="false"]') &&
          ed.getSel()?.start === lineEnd;
      }), `Caret must be editable and immediately after ${JSON.stringify(prefix)}`);
      const placement = await page.evaluate(() => {
        const widget = App.editors[0].el.firstElementChild.querySelector('.wid');
        const caret = getSelection().getRangeAt(0).getBoundingClientRect();
        return { caret: caret.toJSON(), marker: widget?.getBoundingClientRect().toJSON() };
      });
      assert.ok(placement.caret.height > 0 && placement.caret.left >= placement.marker.right - 1,
        `Caret must be visibly after ${JSON.stringify(prefix)}: ${JSON.stringify(placement)}`);
      assert.equal(await page.evaluate(() => App.editors[0].readDOM()), `${prefix}${tail}`,
        'DOM-only caret anchors must not enter the note text');
      if (prefix === '- ' || prefix === '* ') {
        await page.waitForFunction(() => {
          const el = App.editors[0].el.querySelector('.bul');
          return el && getComputedStyle(el, '::before').content === '"•"';
        });
      }
      await page.keyboard.type('first');
      assert.equal(await page.evaluate(() => App.editors[0].text),
        `${prefix}first${tail}`, `Typing after ${JSON.stringify(prefix)} must stay on the list line`);
      await page.keyboard.press('Enter');
      await page.keyboard.type('second');
      const text = await page.evaluate(() => App.editors[0].text);
      assert.ok(text.endsWith(tail), `Continuation must not move to the end: ${text}`);
      assert.ok(text.split('\n')[1].endsWith('second'), text);
      await page.keyboard.press('Enter');
      await page.keyboard.press('Enter');
      await page.keyboard.type('plain');
      assert.equal(await page.evaluate(() => App.editors[0].info.lines[2]), 'plain',
        'Enter on an empty list item must exit the list');
      assert.ok(await page.evaluate(() => {
        const ed = App.editors[0];
        return !ed.text.includes('\u200b') && !ed.copyPayload().includes('\u200b');
      }), 'Caret anchors must not be saved or copied');
    }
    }
    await page.evaluate(() => {
      const ed = App.editors[0];
      ed.commit('', { start: 0, end: 0 });
    });
    await page.keyboard.type('-');
    assert.equal(await page.evaluate(() => App.editors[0].getSel().start), 1,
      'A hyphen alone must leave the caret after the hyphen');
    await page.keyboard.type('5');
    assert.equal(await page.evaluate(() => App.editors[0].text), '-5',
      'Negative numbers must remain ordinary text');
    console.log('PASS: list markers and Enter preserve the caret before later note content');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
