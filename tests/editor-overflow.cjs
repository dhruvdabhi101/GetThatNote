// Run with Node and Playwright available: node tests/editor-overflow.cjs
// The WebKit browser must be installed with `playwright install webkit`.
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const { webkit } = require('playwright');

(async () => {
  const browser = await webkit.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 640, height: 360 } });
    await page.goto(pathToFileURL(path.resolve(__dirname, '../app.html')).href);
    await page.waitForFunction(() => window.App?.editors[0].note);
    await page.evaluate(() => {
      S.paper = 'lines';
      App.applyAppearance();
      const ed = App.editors[0];
      ed.commit('', { start: 0, end: 0 });
      ed.focus();
    });
    assert.ok(await page.evaluate(() => {
      const ed = App.editors[0];
      return ed.el.getBoundingClientRect().height >= ed.scroll.clientHeight;
    }), 'An empty editor must fill the viewport so clicking below text still works');
    for (let i = 1; i <= 30; i++) {
      await page.keyboard.insertText(`Visible line ${i}`);
      const geometry = await page.evaluate(() => {
        const ed = App.editors[0];
        const line = ed.el.lastElementChild;
        const r = line.getBoundingClientRect();
        const sc = ed.scroll.getBoundingClientRect();
        const paper = ed.paper.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + 10, r.top + r.height / 2);
        return {
          text: line.textContent,
          top: r.top, bottom: r.bottom,
          viewportTop: sc.top, viewportBottom: sc.bottom,
          paperTop: paper.top, paperBottom: paper.bottom,
          scrollTop: ed.scroll.scrollTop,
          hit: hit?.className,
          visible: r.top >= sc.top && r.bottom <= sc.bottom && line.contains(hit),
          paperVisible: paper.top <= sc.top + 1 && paper.bottom >= sc.bottom - 1,
        };
      });
      assert.equal(geometry.text, `Visible line ${i}`);
      assert.ok(geometry.visible, `Line ${i} is not visible: ${JSON.stringify(geometry)}`);
      assert.ok(geometry.paperVisible, `Paper ends before line ${i}: ${JSON.stringify(geometry)}`);
      await page.keyboard.press('Enter');
    }
    console.log('PASS: typing and Enter keep text and ruled paper visible beyond the window');
    for (const viewport of [{ width: 420, height: 240 }, { width: 800, height: 600 }]) {
      await page.setViewportSize(viewport);
      for (const paper of ['lines', 'dots', 'sgrid', 'lgrid', 'blank']) {
        await page.evaluate(paper => {
          S.paper = paper;
          App.applyAppearance();
          // Exercise wrapped content as well as explicit newlines, in both panes.
          document.querySelector('#pane1').style.display = '';
          for (const ed of App.editors) {
            ed.focus();
            ed.commit('Long wrapped content '.repeat(200), { start: 0, end: 0 });
          }
          window.getSelection().removeAllRanges();
          document.activeElement.blur();
        }, paper);
        for (const layout of ['', 'split', 'split h']) {
          await page.evaluate(layout => {
            document.querySelector('#main').className = layout;
          }, layout);
          for (const position of [0, 0.5, 1]) {
            await page.evaluate(async position => {
              for (const ed of App.editors) {
                ed.scroll.scrollTop = position * (ed.scroll.scrollHeight - ed.scroll.clientHeight);
              }
              await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            }, position);
            const geometry = await page.evaluate(() => App.editors.map(ed => {
              const sc = ed.scroll.getBoundingClientRect();
              const paper = ed.paper.getBoundingClientRect();
              const text = ed.el.getBoundingClientRect();
              return { sc: sc.toJSON(), paper: paper.toJSON(), text: text.toJSON(),
                covered: paper.top <= sc.top + 1 && paper.bottom >= sc.bottom - 1 &&
                  paper.top <= text.top + 1 && paper.bottom >= text.bottom - 1 };
            }));
            assert.ok(geometry.every(g => g.covered),
              `Paper must cover both panes: ${paper}, ${layout}, scroll=${position}: ${JSON.stringify(geometry)}`);
          }
        }
      }
    }
    console.log('PASS: all paper types cover wrapped notes, both split layouts, scrolling and resizing');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
