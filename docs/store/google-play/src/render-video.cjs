// Monte la vidéo de présentation (1920 x 1080, 30 i/s) :
//   1. ouverture sur des plans de Meridian et Tears of Steel (CC BY) avec le logo,
//   2. les vraies captures de l'app, en fondus et léger zoom,
//   3. carton de fin.
//
//   python music.py 31
//   MEDIA_DIR=<dossier contenant "Meridian (2016)/" et "Tears of Steel (2012)/"> \
//   FFMPEG=/chemin/ffmpeg node render-video.cjs
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const puppeteer = require('puppeteer-core');

const BROWSERS = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
];

const SCENE_LEN = 3.8;
const OUTRO_LEN = 4.5;
const FADE = 0.5;
// [film, début en secondes, durée]
const OPENING = [
  ['Meridian (2016)', 294, 1.7],
  ['Tears of Steel (2012)', 516, 1.7],
  ['Meridian (2016)', 200, 1.7],
  ['Tears of Steel (2012)', 348, 1.7],
];
const SCENES = ['home', 'detail', 'player', 'tracks', 'party', 'offline'];

async function renderStills(dir) {
  const executablePath = process.env.BROWSER || BROWSERS.find((b) => fs.existsSync(b));
  const browser = await puppeteer.launch({ executablePath, headless: true });
  const page = await browser.newPage();
  await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
  const url = 'file:///' + path.join(__dirname, 'video.html').replace(/\\/g, '/');
  for (const name of ['intro', ...SCENES, 'outro']) {
    await page.goto(`${url}#${name}`);
    await page.reload();
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(dir, `${name}.png`), omitBackground: name === 'intro' });
  }
  await browser.close();
}

async function main() {
  const media = process.env.MEDIA_DIR;
  if (!media) throw new Error('MEDIA_DIR manquant');
  const out = path.join(__dirname, '..', 'out');
  const tmp = path.join(out, 'video-tmp');
  fs.mkdirSync(tmp, { recursive: true });
  await renderStills(tmp);

  const args = ['-y', '-hide_banner', '-loglevel', 'warning'];
  const filters = [];
  OPENING.forEach(([film, ss, t]) => args.push('-ss', String(ss), '-t', String(t), '-i', path.join(media, film, `${film}.mp4`)));
  args.push('-loop', '1', '-framerate', '30', '-t', '7', '-i', path.join(tmp, 'intro.png'));
  for (const name of SCENES) args.push('-loop', '1', '-framerate', '30', '-t', String(SCENE_LEN), '-i', path.join(tmp, `${name}.png`));
  args.push('-loop', '1', '-framerate', '30', '-t', String(OUTRO_LEN), '-i', path.join(tmp, 'outro.png'));
  const music = path.join(out, 'musique.wav');
  args.push('-i', music);

  const n = OPENING.length;
  const openLen = OPENING.reduce((s, [, , t]) => s + t, 0);
  OPENING.forEach((_, i) => filters.push(`[${i}:v]scale=-2:1080,crop=1920:1080,fps=30,setsar=1,format=yuv420p[c${i}]`));
  filters.push(`${OPENING.map((_, i) => `[c${i}]`).join('')}concat=n=${n}:v=1:a=0,eq=brightness=-0.06:saturation=0.9,vignette=PI/4[mont]`);
  filters.push(`[${n}:v]format=rgba,fade=in:st=2.2:d=0.9:alpha=1[logo]`);
  filters.push(`[mont][logo]overlay=0:0:shortest=1,format=yuv420p,settb=1/30,setpts=N/30/TB,fps=30[v0]`);
  const zoom = (i, label, frames) =>
    filters.push(`[${i}:v]scale=2880:1620,zoompan=z='1+0.04*on/${frames}':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1920x1080:fps=30,setsar=1,format=yuv420p,settb=1/30,setpts=N/30/TB,fps=30[${label}]`);
  SCENES.forEach((_, k) => zoom(n + 1 + k, `s${k}`, Math.round(SCENE_LEN * 30)));
  zoom(n + 1 + SCENES.length, 'out', Math.round(OUTRO_LEN * 30));

  let prev = 'v0';
  let length = openLen;
  [...SCENES.map((_, k) => `s${k}`), 'out'].forEach((label, k, all) => {
    const next = k === all.length - 1 ? 'vid' : `x${k}`;
    filters.push(`[${prev}][${label}]xfade=transition=fade:duration=${FADE}:offset=${(length - FADE).toFixed(2)}[${next}]`);
    length += (label === 'out' ? OUTRO_LEN : SCENE_LEN) - FADE;
    prev = next;
  });
  filters.push(`[vid]fade=out:st=${(length - 0.8).toFixed(2)}:d=0.8[final]`);

  args.push('-filter_complex', filters.join(';'), '-map', '[final]', '-map', `${n + 2 + SCENES.length}:a`,
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-pix_fmt', 'yuv420p', '-r', '30',
    '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart',
    path.join(out, 'video-presentation-1920x1080.mp4'));
  execFileSync(process.env.FFMPEG || 'ffmpeg', args, { stdio: 'inherit' });
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`vidéo : ${length.toFixed(1)} s`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
