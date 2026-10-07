// End-to-end check of the Phase 1 proof of concept: two browser tabs join the
// same dev room through the relay and must reach "Connected" with live video.
//
// Needs the relay running with SOTTO_DEV_ROOMS=1 and the web build served at
// SOTTO_WEB_URL (default http://localhost:8099/). The page shows the call
// status in its title, which is what this script watches.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const base = process.env.SOTTO_WEB_URL ?? 'http://localhost:8099/';
const url = new URL(`?room=e2e-${Date.now()}&join=1`, base).toString();
const timeout = 60_000;

const browser = await chromium.launch({
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
});
try {
  // Flutter web needs a locale; headless Chromium may not report one.
  const context = await browser.newContext({
    locale: 'en-US',
    permissions: ['camera', 'microphone'],
  });
  const [a, b] = [await context.newPage(), await context.newPage()];
  for (const [name, page] of [['A', a], ['B', b]]) {
    page.on('pageerror', (error) => console.error(`${name} page error: ${error.message}`));
  }
  const titleIncludes = (page, text) =>
    page.waitForFunction((t) => document.title.includes(t), text, { timeout });

  await a.goto(url);
  await titleIncludes(a, 'Waiting');
  console.log('A is waiting');

  await b.goto(url);
  await Promise.all([titleIncludes(a, 'Connected'), titleIncludes(b, 'Connected')]);
  console.log('A and B connected');

  const playing = (page) =>
    page.waitForFunction(
      () => {
        const videos = [...document.querySelectorAll('video')];
        return videos.length >= 2 && videos.every((v) => v.videoWidth > 0 && !v.paused);
      },
      null,
      { timeout },
    );
  await Promise.all([playing(a), playing(b)]);
  console.log('Video is playing on both sides');

  await b.close();
  await titleIncludes(a, 'Waiting');
  assert.match(await a.title(), /Waiting/);
  console.log('A returned to waiting after B left');
  console.log('PASS');
} finally {
  await browser.close();
}
