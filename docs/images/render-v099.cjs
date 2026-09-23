// Render only the v0.9.9 diagrams; historical PNG files are never overwritten.
// Requires Playwright, Mermaid 11.17.2, Chrome, and the Japanese font below.
// Example (dependencies installed separately):
// node docs/images/render-v099.cjs --mermaid /path/to/mermaid.min.js --browser /path/to/chrome
// NODE_PATH may point to an existing node_modules directory for Playwright.
// All rendering is local; browser network requests are blocked.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const args = process.argv.slice(2);
const options = {};
for (let i = 0; i < args.length; i += 2) {
  if (!['--mermaid', '--browser'].includes(args[i]) || !args[i + 1]) {
    throw new Error('Usage: node render-v099.cjs --mermaid FILE [--browser FILE]');
  }
  options[args[i]] = path.resolve(args[i + 1]);
}
if (!options['--mermaid']) throw new Error('--mermaid is required');

(async () => {
  const names = ['dns-tcp-with-script-v099', 'dns-tcp-without-script-v099'];
  const diagrams = names.map(name => fs.readFileSync(path.join(__dirname, name + '.mmd'), 'utf8'));
  const launch = { headless: true };
  if (options['--browser']) launch.executablePath = options['--browser'];
  const browser = await chromium.launch(launch);
  try {
    const page = await browser.newPage({
      viewport: { width: 1080, height: 1000 }, deviceScaleFactor: 1.5,
    });
    await page.route('**/*', route => route.abort());
    await page.setContent('<!doctype html><html lang="ja"><meta charset="utf-8">'
      + '<style>body{margin:0;padding:28px;color:#1f2328;background:white;'
      + 'font-family:"Hiragino Kaku Gothic ProN",sans-serif}'
      + 'section{max-width:960px;margin:0 auto 36px}svg{max-width:100%;height:auto}</style>'
      + '<body><section id="with"></section><section id="without"></section></body></html>');
    await page.addScriptTag({ path: options['--mermaid'] });
    const rendered = await page.evaluate(async diagrams => {
      mermaid.initialize({ startOnLoad: false, theme: 'default', securityLevel: 'strict',
        fontFamily: '"Hiragino Kaku Gothic ProN", sans-serif' });
      const ids = ['with', 'without'];
      const result = [];
      for (let i = 0; i < diagrams.length; i++) {
        await mermaid.parse(diagrams[i]);
        const { svg } = await mermaid.render('comparison' + i, diagrams[i]);
        document.getElementById(ids[i]).insertAdjacentHTML('beforeend', svg);
        const el = document.querySelector('#' + ids[i] + ' svg');
        result.push({ id: ids[i], svg, viewBox: el.getAttribute('viewBox') });
      }
      await document.fonts.ready;
      return result;
    }, diagrams);
    for (let i = 0; i < rendered.length; i++) {
      fs.writeFileSync(path.join(__dirname, names[i] + '.svg'), rendered[i].svg + '\n');
      await page.locator('#' + rendered[i].id + ' svg').screenshot({
        path: path.join(__dirname, names[i] + '.png'),
      });
    }
    console.log(JSON.stringify(rendered.map((item, i) => ({
      name: names[i], viewBox: item.viewBox, parsed: true, rendered: true,
    })), null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exit(1); });
