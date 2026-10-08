// Bandwidth adaptation end to end, in real browsers through the real relay:
//
//  1. Alice calls Bob with video; both connect with live video.
//  2. Alice's upload turns poor (simulated through the test hook): her video
//     steps down and then pauses, the browser accepts each new encoding, and
//     Bob is told her video is paused (he sees why, not a frozen picture).
//  3. Her upload recovers: video comes back at the low level and Bob is told.
//
// Needs the web build made with --dart-define=SOTTO_TEST_HOOKS=true (and
// the relay, as for call.mjs).
import assert from 'node:assert/strict';
import {
  clickButton,
  dataAttribute,
  dumpPages,
  launch,
  newContext,
  openApp,
  openPage,
  titleIncludes,
  videoPlaying,
} from './lib.mjs';

const browser = await launch();

/** Feeds the call `count` upload samples of this quality. */
const upload = (page, quality, count) =>
  page.evaluate(
    ([q, n]) => {
      for (let i = 0; i < n; i++) window.sottoTestUpload(q);
    },
    [quality, count],
  );

try {
  const context = await newContext(browser);
  const bob = await openApp(context, 'bob', 'Bob');
  const bobLink = await bob.evaluate(() => document.documentElement.dataset.sottoCallLink);
  const alice = await openPage(context, 'alice', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await Promise.all([videoPlaying(alice), videoPlaying(bob)]);
  assert.equal(
    await alice.evaluate(() => typeof window.sottoTestUpload),
    'function',
    'the web app was built with SOTTO_TEST_HOOKS=true',
  );
  console.log('✓ Alice and Bob are in a video call');

  await upload(alice, 'poor', 2);
  await dataAttribute(alice, 'video-level', 'reduced');
  await dataAttribute(alice, 'video-level-applied', 'reduced');
  console.log('✓ a poor upload lowers the video; the browser took the new encoding');

  await upload(alice, 'poor', 5);
  await dataAttribute(alice, 'video-level', 'paused');
  await dataAttribute(alice, 'video-level-applied', 'paused');
  await dataAttribute(bob, 'peer-video-paused', 'true');
  assert.match(await alice.title(), /Connected/);
  console.log('✓ a weak upload pauses the video; the voice call goes on and Bob is told');

  await upload(alice, 'good', 8);
  await dataAttribute(alice, 'video-level', 'low');
  await dataAttribute(alice, 'video-level-applied', 'low');
  await dataAttribute(bob, 'peer-video-paused', 'false');
  console.log('✓ once the upload recovers, video comes back and Bob is told');

  await clickButton(alice, 'Hang up');
  await titleIncludes(bob, 'Call ended (they hung up)');
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
