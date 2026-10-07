// End-to-end test of auto-answer for trusted contacts (Phase 5B, Phase 6):
//
//  1. Bob can't turn auto-answer on before choosing a verified contact.
//  2. After a normal call, Bob adds Alice to his contacts, confirming that
//     they compared safety numbers.
//  3. Choosing her for auto-answer and switching it on both need the app
//     lock: Bob sets a PIN, then confirms it.
//  4. Alice's call rings for the delay (5 s), then connects by itself: voice
//     only from Bob's side, "Auto-answered" on both.
//  5. Bob can still decline during the delay.
//  6. A stranger's call keeps ringing; it is never auto-answered.
import assert from 'node:assert/strict';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dataAttribute,
  enableSemantics,
  enterPin,
  launch,
  newContext,
  openApp,
  openPage,
  openTab,
  readAttribute,
  setPin,
  titleIncludes,
  toggleSwitch,
  typeInto,
} from './lib.mjs';

const browser = await launch();
const pin = '246810';

try {
  const context = await newContext(browser);

  const bob = await openApp(context, 'bob', 'Bob');
  const bobLink = await readAttribute(bob, 'call-link');

  // 1. The switch is disabled while nobody is chosen.
  await openTab(bob, 'Settings');
  await enableSemantics(bob);
  const autoSwitch = bob
    .getByRole('switch', { name: /Auto-answer calls from trusted contacts/ })
    .or(bob.getByRole('checkbox', { name: /Auto-answer calls from trusted contacts/ }))
    .first();
  await autoSwitch.waitFor();
  assert.equal(await autoSwitch.isDisabled(), true, 'auto-answer needs a trusted contact first');
  console.log('✓ auto-answer cannot be switched on before choosing a verified contact');

  // 2. Normal call, then add Alice as a verified contact.
  const alice = await openPage(context, 'alice', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await clickButton(alice, 'Hang up');
  await titleIncludes(bob, 'Call ended (they hung up)');

  await clickButton(bob, 'Add to contacts');
  await typeInto(bob, 'Name', 'Alice');
  await toggleSwitch(bob, /I compared this safety number/);
  await clickButton(bob, 'Save contact');
  await clickButton(bob, 'OK');
  console.log('✓ Bob added Alice to his contacts after comparing the safety number');

  // 3. Choose Alice for auto-answer (sets the PIN), then switch it on (asks for it).
  await openTab(bob, 'Contacts');
  await clickButton(bob, /^Alice/);
  await toggleSwitch(bob, /Answer their calls automatically/);
  await titleIncludes(bob, 'Ready');
  await setPin(bob, pin);
  await clickButton(bob, 'Done');
  // The contact list now marks Alice for auto-answer.
  await bob.getByRole('button', { name: /^Alice[\s\S]*Verified · Auto-answer/ }).waitFor();

  await openTab(bob, 'Settings');
  await toggleSwitch(bob, /Auto-answer calls from trusted contacts/);
  await typeInto(bob, 'PIN', '111111');
  await clickButton(bob, 'Confirm');
  await bob.getByText('Wrong PIN.').first().waitFor();
  await enterPin(bob, pin);
  await dataAttribute(bob, 'auto-answer', 'true');
  console.log('✓ choosing Alice set an app lock; switching auto-answer on needed the PIN (a wrong one was refused)');

  // 4. Alice calls again: rings for ~5 s, then connects without Bob touching anything.
  await clickButton(alice, 'Video call');
  await titleIncludes(bob, 'Incoming call');
  const ringStart = Date.now();
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  const rang = (Date.now() - ringStart) / 1000;
  assert.ok(rang >= 4, `rang only ${rang.toFixed(1)} s before auto-answering`);
  await Promise.all([dataAttribute(alice, 'auto-answered', 'true'), dataAttribute(bob, 'auto-answered', 'true')]);
  // Bob answered voice-only: his camera was never opened.
  await dataAttribute(bob, 'sending-video', 'false');
  await dataAttribute(alice, 'sending-video', 'true');
  console.log(`✓ Alice's call rang ${rang.toFixed(1)} s, then was auto-answered (voice only, shown on both sides)`);
  await clickButton(alice, 'Hang up');
  await titleIncludes(bob, 'Call ended');
  await clickButton(bob, 'OK');

  // 5. Bob declines during the delay.
  await clickButton(alice, 'Video call');
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Decline');
  await titleIncludes(alice, 'Call ended (declined)');
  await bob.waitForTimeout(6000);
  assert.match(await bob.title(), /Call ended \(you declined\)/);
  console.log('✓ declining during the ring delay wins');
  await clickButton(bob, 'OK');

  // 6. A stranger is never auto-answered.
  const stranger = await openPage(context, 'stranger', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await bob.waitForTimeout(8000);
  assert.match(await bob.title(), /Incoming call/);
  assert.match(await stranger.title(), /Ringing/);
  await clickButton(bob, 'Decline');
  console.log('✓ a stranger kept ringing (never auto-answered)');

  const sends = assertRelaySawOnlyCiphertext(assert, ['Alice', pin]);
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; contacts and settings never left Bob's device`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
