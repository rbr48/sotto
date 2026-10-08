// A visitor without a camera (getUserMedia for video fails with
// NotFoundError, as on a desktop with no webcam) opens a call link: the
// video call still goes through with their microphone alone, and they
// still see the other person's video.
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
} from './lib.mjs';

const browser = await launch();

try {
  const context = await newContext(browser);
  const bob = await openApp(context, 'bob', 'Bob');
  const bobLink = await bob.evaluate(() => document.documentElement.dataset.sottoCallLink);

  const noCamera = await newContext(browser);
  await noCamera.addInitScript(() => {
    const original = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = (constraints) =>
      constraints?.video
        ? Promise.reject(new DOMException('Requested device not found', 'NotFoundError'))
        : original(constraints);
  });
  const alice = await openPage(noCamera, 'alice', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await dataAttribute(alice, 'sending-video', 'false');
  console.log('✓ without a camera, the video call connected with the microphone alone');

  await alice.waitForFunction(() =>
    [...document.querySelectorAll('video')].some(
      (v) => v.srcObject?.getVideoTracks().length && v.videoWidth > 0 && !v.paused,
    ),
  );
  assert.match(await bob.title(), /Connected/);
  console.log("✓ and still shows the other person's video");

  await clickButton(alice, 'Hang up');
  await titleIncludes(bob, 'Call ended (they hung up)');
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
