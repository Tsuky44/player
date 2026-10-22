// Rend les écrans de screens.html en PNG (1080 x 2400, ou 2400 x 1080 pour
// les écrans en paysage) dans ../screens : ce sont les textures de l'écran du
// téléphone 3D.
const path = require('path');
const fs = require('fs');
const puppeteer = require('puppeteer-core');

const BROWSERS = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
];
const LANDSCAPE = new Set(['player', 'party']);

async function main() {
  const out = path.join(__dirname, '..', 'screens');
  fs.mkdirSync(out, { recursive: true });
  const executablePath = process.env.BROWSER || BROWSERS.find((b) => fs.existsSync(b));
  const browser = await puppeteer.launch({ executablePath, headless: true });
  const page = await browser.newPage();
  const url = 'file:///' + path.join(__dirname, 'screens.html').split(path.sep).join('/');
  await page.goto(url);
  const names = await page.evaluate(() => window.SCREENS);
  for (const name of names) {
    const land = LANDSCAPE.has(name);
    await page.setViewport({ width: land ? 800 : 360, height: land ? 360 : 800, deviceScaleFactor: 3 });
    await page.goto(`${url}#${name}`);
    await page.reload({ waitUntil: 'networkidle0' });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(out, `${name}.png`) });
    console.log(name);
  }
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
