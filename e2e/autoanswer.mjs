// End-to-end test of auto-answer for trusted callers (Phase 5B):
//
//  1. Bob can't turn auto-answer on before trusting anyone.
//  2. After a normal call, Bob trusts Alice; the dialog requires confirming
//     that they compared safety numbers.
//  3. With auto-answer on, Alice's call rings for the delay (5 s), then
//     connects by itself: voice only from Bob's side, "Auto-answered" on both.
//  4. Bob can still decline during the delay.
//  5. A stranger's call keeps ringing; it is never auto-answered.
import assert from 'node:assert/strict';
import {
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dataAttribute,
  enableSemantics,
  launch,
  newContext,
  openPage,
  readAttribute,
  titleIncludes,
  toggleSwitch,
  typeInto,
} from './lib.mjs';

const browser = await launch();

try {
  const context = await newContext(browser);

  const bob = await openPage(context, 'bob', base);
  await titleIncludes(bob, 'Ready');
  const bobLink = await readAttribute(bob, 'call-link');

  // 1. The switch is disabled while nobody is trusted.
  await enableSemantics(bob);
  const autoSwitch = bob
    .getByRole('switch', { name: /Auto-answer calls from trusted callers/ })
    .or(bob.getByRole('checkbox', { name: /Auto-answer calls from trusted callers/ }))
    .first();
  await autoSwitch.waitFor();
  assert.equal(await autoSwitch.isDisabled(), true, 'auto-answer needs a trusted caller first');
  console.log('✓ auto-answer cannot be switched on before trusting someone');

  // 2. Normal call, then trust Alice.
  const alice = await openPage(context, 'alice', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await clickButton(alice, 'Hang up');
  await titleIncludes(bob, 'Call ended (they hung up)');

  await clickButton(bob, 'Trust this caller');
  const trustButton = bob.getByRole('button', { name: 'Trust', exact: true });
  await trustButton.waitFor();
  assert.equal(await trustButton.isDisabled(), true, 'must confirm the safety number first');
  await bob.getByRole('checkbox', { name: /I compared this safety number/ }).click();
  await typeInto(bob, 'Name', 'Alice');
  await clickButton(bob, 'Trust');
  await toggleSwitch(bob, /Auto-answer calls from trusted callers/);
  await dataAttribute(bob, 'auto-answer', 'true');
  await clickButton(bob, 'OK');
  console.log('✓ Bob trusted Alice after confirming the safety number, and turned auto-answer on');

  // 3. Alice calls again: rings for ~5 s, then connects without Bob touching anything.
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

  // 4. Bob declines during the delay.
  await clickButton(alice, 'Video call');
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Decline');
  await titleIncludes(alice, 'Call ended (declined)');
  await bob.waitForTimeout(6000);
  assert.match(await bob.title(), /Call ended \(you declined\)/);
  console.log('✓ declining during the ring delay wins');
  await clickButton(bob, 'OK');

  // 5. A stranger is never auto-answered.
  const stranger = await openPage(context, 'stranger', bobLink);
  await titleIncludes(bob, 'Incoming call');
  await bob.waitForTimeout(8000);
  assert.match(await bob.title(), /Incoming call/);
  assert.match(await stranger.title(), /Ringing/);
  await clickButton(bob, 'Decline');
  console.log('✓ a stranger kept ringing (never auto-answered)');

  const sends = assertRelaySawOnlyCiphertext(assert, ['Alice']);
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; trust settings never left Bob's device`);
  console.log('PASS');
} finally {
  await browser.close();
}
