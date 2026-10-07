// End-to-end test through the real relay and real browsers:
//
//  1. The crypto self-test passes in the browser (sodium.js).
//  2. Bob shares his call link; Alice opens it and her call rings at Bob's.
//  3. Bob accepts; both connect with live video; the relay only ever sees
//     login messages and encrypted envelopes.
//  4. Carol calls Bob while he is busy and gets "busy".
//  5. Alice hangs up; both sides see why the call ended.
//  6. Carol calls again and Bob declines; then Carol calls and cancels.
//
// Needs the relay at ws://localhost:8080/relay and the web build (built with
// SOTTO_RELAY_URL pointing there) served at SOTTO_WEB_URL.
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

const base = process.env.SOTTO_WEB_URL ?? 'http://localhost:8099/';
const timeout = 60_000;

const browser = await chromium.launch({
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
});

/** Everything the browsers send to the relay. */
const framesToRelay = [];

async function openPage(context, name, url) {
  const page = await context.newPage();
  page.on('pageerror', (error) => console.error(`${name} page error: ${error.message}`));
  page.on('websocket', (ws) =>
    ws.on('framesent', ({ payload }) => framesToRelay.push(String(payload))),
  );
  await page.goto(url);
  return page;
}

const titleIncludes = (page, text) =>
  page.waitForFunction((t) => document.title.includes(t), text, { timeout });

/** Clicks a Flutter button by its label, via Flutter's accessibility tree. */
async function clickButton(page, name) {
  if ((await page.locator('flt-semantics-placeholder').count()) > 0) {
    await page.locator('flt-semantics-placeholder').dispatchEvent('click');
  }
  const button = page.getByRole('button', { name, exact: true });
  await button.waitFor({ timeout });
  await button.click();
}

const videoPlaying = (page) =>
  page.waitForFunction(
    () => {
      const videos = [...document.querySelectorAll('video')];
      return videos.length >= 2 && videos.every((v) => v.videoWidth > 0 && !v.paused);
    },
    null,
    { timeout },
  );

try {
  // Flutter web needs a locale; headless Chromium may not report one.
  const context = await browser.newContext({
    locale: 'en-US',
    permissions: ['camera', 'microphone'],
  });

  const selfTest = await openPage(context, 'self-test', new URL('?selftest=1', base).toString());
  await selfTest.waitForFunction(() => /Self-test (passed|failed|error)/.test(document.title), null, {
    timeout,
  });
  assert.equal(await selfTest.title(), 'Sotto · Self-test passed');
  await selfTest.close();
  console.log('✓ crypto self-test passed in the browser');

  const bob = await openPage(context, 'bob', base);
  await titleIncludes(bob, 'Ready');
  const bobLink = await bob.evaluate(() => document.documentElement.dataset.sottoCallLink);
  assert.ok(bobLink?.includes('?call='), 'Bob has a call link');
  console.log('✓ Bob is online with a call link');

  const alice = await openPage(context, 'alice', bobLink);
  await Promise.all([titleIncludes(alice, 'Ringing'), titleIncludes(bob, 'Incoming call')]);
  console.log('✓ Alice opened the link; Bob is ringing');

  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await Promise.all([videoPlaying(alice), videoPlaying(bob)]);
  console.log('✓ Bob accepted; both connected with live video');

  const carol = await openPage(context, 'carol', bobLink);
  await titleIncludes(carol, 'Call ended (busy)');
  assert.match(await bob.title(), /Connected/);
  console.log('✓ Carol got "busy"; the ongoing call was not disturbed');

  await clickButton(alice, 'Hang up');
  await Promise.all([
    titleIncludes(alice, 'Call ended (you hung up)'),
    titleIncludes(bob, 'Call ended (they hung up)'),
  ]);
  console.log('✓ Alice hung up; both sides know why the call ended');

  await carol.reload();
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Decline');
  await Promise.all([
    titleIncludes(carol, 'Call ended (declined)'),
    titleIncludes(bob, 'Call ended (you declined)'),
  ]);
  console.log('✓ Bob declined Carol');

  await carol.reload();
  await Promise.all([titleIncludes(carol, 'Ringing'), titleIncludes(bob, 'Incoming call')]);
  await clickButton(carol, 'Cancel');
  await Promise.all([
    titleIncludes(carol, 'Call ended (cancelled)'),
    titleIncludes(bob, 'Call ended (missed)'),
  ]);
  console.log('✓ Carol cancelled; Bob sees a missed call');

  // The relay must only ever see logins and opaque envelopes.
  const sends = framesToRelay.filter((f) => f.includes('"type":"send"'));
  assert.ok(sends.length >= 10, `expected encrypted messages, got ${sends.length}`);
  for (const frame of framesToRelay) {
    const message = JSON.parse(frame);
    assert.ok(['auth', 'send'].includes(message.type), `unexpected frame type ${message.type}`);
    for (const leak of ['v=0', 'a=fingerprint', 'candidate:', 'sdp.', 'call.', 'video']) {
      assert.ok(!frame.includes(leak), `relay saw readable call data (${leak})`);
    }
  }
  console.log(`✓ relay saw ${sends.length} encrypted messages and no readable call data`);
  console.log('PASS');
} finally {
  await browser.close();
}
