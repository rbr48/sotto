// End-to-end check of the proof of concept: the crypto self-test passes in the
// browser, then two browser tabs join the same dev room through the relay,
// exchange identity cards and encrypted call-setup messages, and must reach
// "Connected" with live video.
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
  // Everything the relay receives, to prove it only ever sees ciphertext.
  const framesToRelay = [];
  for (const [name, page] of [['A', a], ['B', b]]) {
    page.on('pageerror', (error) => console.error(`${name} page error: ${error.message}`));
    page.on('websocket', (ws) => ws.on('framesent', ({ payload }) => framesToRelay.push(String(payload))));
  }
  const titleIncludes = (page, text) =>
    page.waitForFunction((t) => document.title.includes(t), text, { timeout });

  // The crypto self-test proves the browser (sodium.js) produces exactly the
  // same results as the native library and the independent test vectors.
  const selfTest = await context.newPage();
  await selfTest.goto(new URL('?selftest=1', base).toString());
  await selfTest.waitForFunction(() => /Self-test (passed|failed|error)/.test(document.title), null, {
    timeout,
  });
  assert.equal(await selfTest.title(), 'Sotto · Self-test passed');
  await selfTest.close();
  console.log('Crypto self-test passed in the browser');

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

  const sealed = framesToRelay.filter((f) => f.includes('"kind":"sealed"'));
  assert.ok(sealed.length >= 3, `expected encrypted offer/answer/candidates, got ${sealed.length}`);
  for (const frame of framesToRelay) {
    for (const leak of ['v=0', 'a=fingerprint', 'candidate:', 'sdp.offer', 'sdp.answer']) {
      assert.ok(!frame.includes(leak), `relay saw readable call data (${leak})`);
    }
  }
  console.log(`Relay saw ${sealed.length} encrypted messages and no readable call data`);

  await b.close();
  await titleIncludes(a, 'Waiting');
  assert.match(await a.title(), /Waiting/);
  console.log('A returned to waiting after B left');
  console.log('PASS');
} finally {
  await browser.close();
}
