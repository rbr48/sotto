// A guest on Firefox (fake camera and microphone) calls a professional on
// Chromium, through the real relay and TURN server:
//
//  1. The crypto self-test passes in Firefox.
//  2. The guest opens a signed guest link, checks devices and knocks.
//  3. Admitted: live video both ways; the guest hangs up and both sides
//     see it.
//  4. Again with voice only.
//  5. Firefox pages only contacted their own server.
import assert from 'node:assert/strict';
import { firefox } from 'playwright';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  base,
  clickButton,
  launch,
  newContext,
  openApp,
  openPage,
  readAttribute,
  titleIncludes,
  typeInto,
  videoPlaying,
} from './lib.mjs';

const chromium = await launch();
const gecko = await firefox.launch({
  firefoxUserPrefs: {
    'media.navigator.streams.fake': true,
    'media.navigator.permission.disabled': true,
  },
});

try {
  const firefoxContext = await gecko.newContext({ locale: 'en-US' });

  const selfTest = await openPage(firefoxContext, 'firefox-self-test', new URL('?selftest=1', base).toString());
  await titleIncludes(selfTest, 'Self-test passed');
  await selfTest.close();
  console.log('✓ crypto self-test passed in Firefox');

  const pro = await openApp(await newContext(chromium), 'professional', 'Dr Rao');
  const link = await readAttribute(pro, 'guest-link');

  const guest = await openPage(firefoxContext, 'firefox-guest', link);
  await titleIncludes(guest, 'Check your camera');
  await typeInto(guest, /Your name/, 'Asha Verma');
  await clickButton(guest, 'Join with video');
  await titleIncludes(guest, 'Waiting to be let in');
  console.log('✓ Firefox guest checked devices and is waiting to be let in');

  await clickButton(pro, 'Admit');
  await Promise.all([titleIncludes(guest, 'Connected'), titleIncludes(pro, 'Connected')]);
  await Promise.all([videoPlaying(guest), videoPlaying(pro)]);
  console.log('✓ admitted: live video both ways between Firefox and Chromium');
  // Firefox reports the candidate pair's round trip in milliseconds; read as
  // seconds, a good local call showed "poor".
  await guest.waitForTimeout(6000);
  assert.equal(await readAttribute(guest, 'quality'), 'good');
  console.log('✓ Firefox shows call quality "good" on a good connection');

  await clickButton(guest, 'Hang up');
  await titleIncludes(pro, 'Call ended');
  await clickButton(pro, 'OK');
  console.log('✓ the Firefox guest hung up; the professional saw it');

  await clickButton(guest, 'Join again');
  await titleIncludes(guest, 'Check your camera');
  await clickButton(guest, 'Join with voice only');
  await titleIncludes(guest, 'Waiting to be let in');
  await clickButton(pro, 'Admit');
  await Promise.all([titleIncludes(guest, 'Connected'), titleIncludes(pro, 'Connected')]);
  await clickButton(pro, 'Hang up');
  await titleIncludes(guest, 'Call ended');
  console.log('✓ voice-only call from Firefox');

  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await gecko.close();
  await chromium.close();
}
