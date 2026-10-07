// End-to-end test of Phase 7 behaviour in the browser:
//
//  1. Sounds: the caller hears the ringback tone while the callee's device
//     rings, the callee hears the ringtone; both stop when answered.
//  2. A dialog left open (here "Share my contact") closes when a call comes
//     in, so the call can be answered.
//  3. A guest knocking plays the knock chime.
//  4. The browser can't switch servers (it always uses the server it was
//     loaded from); the setting exists only in the installed apps.
import assert from 'node:assert/strict';
import {
  dumpPages,
  base,
  clickButton,
  dataAttribute,
  enableSemantics,
  launch,
  newContext,
  openApp,
  openPage,
  openTab,
  readAttribute,
  titleIncludes,
  typeInto,
  assertNoThirdPartyRequests,
} from './lib.mjs';

const browser = await launch();

try {
  const context = await newContext(browser);
  const meera = await openApp(context, 'meera', 'Dr Meera Rao');
  const arun = await openApp(context, 'arun', 'Arun Mehta');

  await openTab(meera, 'Contacts');
  await clickButton(meera, 'Share my contact');
  const contactLink = await readAttribute(meera, 'contact-link');
  await openTab(arun, 'Contacts');
  await clickButton(arun, 'Add contact');
  await typeInto(arun, 'Contact link', contactLink);
  await clickButton(arun, 'Next');
  await clickButton(arun, 'Save contact');

  // Meera's "Share my contact" dialog is still open when Arun calls.
  await clickButton(arun, 'Voice call Dr Meera Rao');
  await titleIncludes(meera, 'Incoming call');
  await Promise.all([dataAttribute(meera, 'sound', 'ringtone'), dataAttribute(arun, 'sound', 'ringback')]);
  console.log('✓ ringtone on the callee, ringback tone on the caller');
  await clickButton(meera, 'Accept');
  await Promise.all([titleIncludes(meera, 'Connected'), titleIncludes(arun, 'Connected')]);
  await Promise.all([dataAttribute(meera, 'sound', 'none'), dataAttribute(arun, 'sound', 'none')]);
  console.log('✓ the open dialog closed for the incoming call; sounds stopped when answered');
  await clickButton(arun, 'Hang up');
  await titleIncludes(meera, 'Call ended (they hung up)');
  await clickButton(meera, 'OK');

  // A guest knocks.
  const guestLink = await readAttribute(meera, 'guest-link');
  const guest = await openPage(context, 'guest', guestLink);
  await titleIncludes(guest, 'Check your camera');
  await clickButton(guest, 'Join with voice only');
  await titleIncludes(guest, 'Waiting to be let in');
  await dataAttribute(meera, 'cue', 'knock');
  console.log('✓ a knocking guest plays the knock chime');
  await clickButton(meera, 'Decline');

  // No server setting in the browser.
  await openTab(meera, 'Settings');
  await enableSemantics(meera);
  // Settings is a lazy list: scroll through all of it.
  let sawSounds = false;
  let sawServer = false;
  await meera.mouse.move(640, 400);
  for (let i = 0; i < 30; i++) {
    sawSounds ||= (await meera.getByRole('switch', { name: /Ringtone and chimes/ }).count()) > 0;
    sawServer ||= (await meera.getByRole('button', { name: 'Use another server' }).count()) > 0;
    await meera.mouse.wheel(0, 300);
    await meera.waitForTimeout(150);
  }
  assert.ok(sawSounds, 'sound setting shown');
  assert.ok(!sawServer, 'no server setting in the browser');
  console.log('✓ the browser has sound settings but no server setting');

  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
