// A call survives losing its network path:
//
//  1. Alice calls Bob with "Hide my IP address", so the media goes through
//     the TURN server.
//  2. The TURN server freezes (SIGSTOP), as if the network went away: both
//     sides show "Reconnecting", and the call is not ended.
//  3. The TURN server comes back (SIGCONT): the call reconnects by itself
//     (ICE restart) and the video plays again.
//
// Needs the TURN server's pidfile (SOTTO_TURN_PIDFILE, default
// /tmp/turn.pid; see README.md). Without it the test is skipped, except
// in CI.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dataAttribute,
  framesToRelay,
  launch,
  newContext,
  openApp,
  openPage,
  titleIncludes,
  toggleSwitch,
  videoPlaying,
} from './lib.mjs';

const pidfile = process.env.SOTTO_TURN_PIDFILE ?? '/tmp/turn.pid';
if (!existsSync(pidfile)) {
  if (process.env.CI) throw new Error(`TURN pidfile ${pidfile} not found`);
  console.log(`SKIP: no TURN pidfile at ${pidfile}`);
  process.exit(0);
}
const turnPid = Number(readFileSync(pidfile, 'utf8').trim());
// Fails early if the pidfile is stale (e.g. the TURN server couldn't get its
// port and exited) or the process belongs to someone else.
process.kill(turnPid, 0);

const browser = await launch();
let frozen = false;

try {
  const context = await newContext(browser);
  const bob = await openApp(context, 'bob', 'Bob');
  const bobLink = await bob.evaluate(() => document.documentElement.dataset.sottoCallLink);

  // Alice's page rings Bob as it opens; cancel, then call again relay-only.
  const alice = await openPage(context, 'alice', bobLink);
  await titleIncludes(alice, 'Ringing');
  await clickButton(alice, 'Cancel');
  await titleIncludes(alice, 'Call ended (cancelled)');
  await toggleSwitch(alice, /Hide my IP address/);
  await dataAttribute(alice, 'hide-ip', 'true');
  await clickButton(alice, 'Video call');
  await titleIncludes(bob, 'Incoming call');
  await clickButton(bob, 'Accept');
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await Promise.all([videoPlaying(alice), videoPlaying(bob)]);
  await dataAttribute(alice, 'route', 'relayed');
  console.log('✓ Alice and Bob are in a call through the TURN server');

  const sendsBefore = framesToRelay.filter((f) => f.includes('"type":"send"')).length;
  process.kill(turnPid, 'SIGSTOP');
  frozen = true;
  await Promise.all([titleIncludes(alice, 'Reconnecting'), titleIncludes(bob, 'Reconnecting')]);
  await Promise.all([dataAttribute(alice, 'reconnecting', 'true'), dataAttribute(bob, 'reconnecting', 'true')]);
  console.log('✓ the path went away: both sides show "Reconnecting"');

  // Long enough for the connection to fail and for several restarts.
  await alice.waitForTimeout(15_000);
  assert.match(await alice.title(), /Reconnecting/);
  assert.match(await bob.title(), /Reconnecting/);
  console.log('✓ the call stays up while the network is gone');

  process.kill(turnPid, 'SIGCONT');
  frozen = false;
  await Promise.all([titleIncludes(alice, 'Connected'), titleIncludes(bob, 'Connected')]);
  await Promise.all([dataAttribute(alice, 'reconnecting', 'false'), dataAttribute(bob, 'reconnecting', 'false')]);
  await Promise.all([videoPlaying(alice), videoPlaying(bob)]);
  await dataAttribute(alice, 'route', 'relayed');
  const restartMessages = framesToRelay.filter((f) => f.includes('"type":"send"')).length - sendsBefore;
  assert.ok(restartMessages > 0, 'the restart was negotiated through the relay');
  console.log(`✓ the network came back: the call reconnected by itself (${restartMessages} encrypted messages)`);

  await clickButton(bob, 'Hang up');
  await titleIncludes(alice, 'Call ended (they hung up)');

  assertRelaySawOnlyCiphertext(assert);
  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  if (frozen) process.kill(turnPid, 'SIGCONT');
  await browser.close();
}
