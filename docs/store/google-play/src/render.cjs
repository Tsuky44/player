// Rend les visuels de store.html en PNG avec Edge (ou Chrome) sans tête.
//
//   npm i puppeteer-core            (une fois, dans n'importe quel dossier listé par NODE_PATH)
//   node render.cjs                 tous les visuels
//   node render.cjs phone-1 icon    seulement ceux-là
//
// Chaque visuel est une ancre de store.html (#phone-1, #feature…) : la page
// lit l'ancre, compose la scène et se met à la taille exacte attendue par
// Google Play.
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const BROWSERS = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
];

async function main() {
  const executablePath = process.env.BROWSER || BROWSERS.find((b) => fs.existsSync(b));
  const out = path.join(__dirname, '..', 'out');
  fs.mkdirSync(out, { recursive: true });
  const page_url = 'file:///' + path.join(__dirname, 'store.html').replace(/\\/g, '/');

  const browser = await puppeteer.launch({ executablePath, headless: true });
  const page = await browser.newPage();
  await page.goto(page_url);
  const shots = await page.evaluate(() => window.SHOTS);
  const wanted = process.argv.slice(2);

  for (const [id, shot] of Object.entries(shots)) {
    if (wanted.length && !wanted.includes(id)) continue;
    await page.setViewport({ width: shot.w, height: shot.h, deviceScaleFactor: 1 });
    await page.goto(`${page_url}#${id}`);
    await page.reload();
    await page.evaluate(() => document.fonts.ready);
    const file = path.join(out, `${shot.file}.png`);
    await page.screenshot({ path: file, omitBackground: false });
    console.log(`${shot.file}.png  ${shot.w}x${shot.h}`);
  }
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
