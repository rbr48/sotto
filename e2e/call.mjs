// End-to-end test through the real relay and real browsers:
//
//  1. The crypto self-test passes in the browser (sodium.js).
//  2. Bob shares his call link; Alice opens it and her call rings at Bob's.
//  3. Bob accepts; both connect with live video; the relay only ever sees
//     login messages and encrypted envelopes.
//  4. Carol calls Bob while he is busy and gets "busy".
//  5. Alice hangs up; both sides see why the call ended.
//  6. Carol calls again and Bob declines; then Carol calls and cancels.
//  7. Alice turns on "Hide my IP address" and calls again: the call must
//     connect through the TURN server (relayed), not directly.
//
// Needs the relay at ws://localhost:8080/relay (configured with a TURN
// server, see README.md) and the web build (built with SOTTO_RELAY_URL
// pointing there) served at SOTTO_WEB_URL.
import assert from 'node:assert/strict';
import {
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dataAttribute,
  launch,
  newContext,
  openPage,
  timeout,
  titleIncludes,
  toggleSwitch,
  videoPlaying,
} from './lib.mjs';

const browser = await launch();

try {
  const context = await newContext(browser);

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
  await dataAttribute(alice, 'route', 'direct');
  console.log('✓ Bob accepted; both connected with live video (direct connection)');

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

  await carol.reload({ waitUntil: 'domcontentloaded', timeout });
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Decline');
  await Promise.all([
    titleIncludes(carol, 'Call ended (declined)'),
    titleIncludes(bob, 'Call ended (you declined)'),
  ]);
  console.log('✓ Bob declined Carol');

  await carol.reload({ waitUntil: 'domcontentloaded', timeout });
  await Promise.all([titleIncludes(carol, 'Ringing'), titleIncludes(bob, 'Incoming call')]);
  await clickButton(carol, 'Cancel');
  await Promise.all([
    titleIncludes(carol, 'Call ended (cancelled)'),
    titleIncludes(bob, 'Call ended (missed)'),
  ]);
  console.log('✓ Carol cancelled; Bob sees a missed call');

  await toggleSwitch(alice, /Hide my IP address/);
  await dataAttribute(alice, 'hide-ip', 'true');
  await clickButton(alice, 'Video call');
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await Promise.all([videoPlaying(alice), videoPlaying(bob)]);
  await dataAttribute(alice, 'route', 'relayed');
  console.log('✓ With "Hide my IP address" the call connected through the TURN server');
  await clickButton(bob, 'Hang up');
  await titleIncludes(alice, 'Call ended (they hung up)');

  const sends = assertRelaySawOnlyCiphertext(assert);
  assert.ok(sends >= 10, `expected encrypted messages, got ${sends}`);
  console.log(`✓ relay saw ${sends} encrypted messages and no readable call data`);
  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  console.log('PASS');
} finally {
  await browser.close();
}
