// End-to-end test of the failure path of chat, through the real relay and real
// browsers. Meera and Arun are contacts, each in its own browser context, so
// Meera can go offline while Arun stays online:
//
//  1. Meera and Arun add each other as contacts, and Arun opens the chat with
//     Meera while she is online.
//  2. Meera goes offline. Arun sends "Are you there?". Nobody answers the open,
//     so the message shows "Not sent: Meera Rao did not answer.", with a Retry
//     button and the problem banner.
//  3. Meera comes back online. Arun's app sends the sealed text through the
//     relay again on its next check (the first copy may have gone to her dead
//     connection), so it reaches her by itself: her chat shows it once, and
//     Arun's bubble turns Delivered or Read.
//  4. Nothing is left to retry on Arun's side.
//  5. The relay sees only encrypted envelopes; the pages contact no third-party
//     hosts.
import assert from 'node:assert/strict';
import {
  accessibilityNodes,
  addContact,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  bubble,
  clickButton,
  dumpPages,
  launch,
  newContext,
  openApp,
  openChat,
  secondsSince,
  shareContactLink,
  sleep,
  typeInto,
  waitUntil,
  watchRelay,
} from './lib.mjs';

/** Failure-path waits: a missed open is reported 20 to 50 s after the send. */
const slow = 90_000;

const browser = await launch();

/**
 * Meera's and Arun's relay connections (see watchRelay). Her counts confirm
 * the cut; his sends show the message going out again, since a message can
 * only go out again through a new session, and a session starts with a send.
 */
let meeraRelay = null;
let arunRelay = null;

let meera = null;
let arun = null;

try {
  const meeraContext = await newContext(browser);
  const arunContext = await newContext(browser);
  // Watch both relay connections from the start, before the pages open them.
  meeraRelay = watchRelay(meeraContext);
  arunRelay = watchRelay(arunContext);
  meera = await openApp(meeraContext, 'meera', 'Meera Rao');
  arun = await openApp(arunContext, 'arun', 'Arun Mehta');

  // 1. Each adds the other; Arun opens the chat with Meera while she is online.
  const meeraContactLink = await shareContactLink(meera);
  const arunContactLink = await shareContactLink(arun);
  await addContact(arun, meeraContactLink, 'Meera Rao');
  await addContact(meera, arunContactLink, 'Arun Mehta');
  await openChat(arun, 'Meera Rao');
  // Positive controls: while she is online, her login and her frames are
  // counted, so the zero counts checked later can tell a cut from a broken counter.
  await waitUntil(() => meeraRelay.logins >= 1, "Meera's login to the relay", slow);
  assert.ok(meeraRelay.framesReceived > 0, 'frames reached Meera while she was online');
  console.log('✓ contacts: Meera and Arun have added each other; Arun has the chat with Meera open');

  // 2. Meera goes offline. Arun sends only once her app has noticed the cut.
  const receivedBefore = meeraRelay.framesReceived;
  const offlineAt = Date.now();
  await meeraContext.setOffline(true);
  // Frames already on their way when the cut landed are not counted.
  await sleep(1000);
  meeraRelay.offline = true;
  await waitUntil(
    () => meeraRelay.attemptsWhileOffline > 0,
    "Meera's app to notice the cut and try to reconnect (setOffline did not stop her relay connection)",
    slow,
  );
  console.log(
    `✓ Meera is offline: her app noticed after ${secondsSince(offlineAt)} and tried to reconnect ` +
      `(her connection had received ${receivedBefore} relay frames before going offline)`,
  );

  // Arun sends. Nobody answers the open, so after the timeout the message is
  // marked not sent, with the Retry button and the banner.
  const sendsBeforeMessage = arunRelay.sends;
  const sentAt = Date.now();
  await typeInto(arun, 'Write a message', 'Are you there?');
  await clickButton(arun, 'Send');
  await waitUntil(
    () => arunRelay.sends > sendsBeforeMessage,
    "Arun's app to send the open to the relay",
    slow,
  );
  await bubble(arun, 'Are you there?', 'Not sent: Meera Rao did not answer.')
    .first()
    .waitFor({ timeout: slow });
  const notSentIn = secondsSince(sentAt);
  // The plan's wording (docs/MESSAGING_PLAN.md, "Offline").
  await arun
    .getByText('The connection could not be made. Your messages were not sent; you can retry.')
    .first()
    .waitFor({ timeout: slow });
  assert.equal(await bubble(arun, 'Are you there?').count(), 1, 'Arun has exactly one "Are you there?" bubble');
  assert.equal(
    await arun.getByRole('button', { name: 'Retry', exact: true }).count(),
    1,
    'Arun has one Retry button',
  );
  console.log(
    `✓ Arun sees "Not sent: Meera Rao did not answer.", a Retry button and the problem banner, ${notSentIn} after sending`,
  );

  // 3. Meera comes back online. Nothing may have reached her while she was
  // offline, and she did not log in while offline.
  assert.equal(meeraRelay.framesWhileOffline, 0, 'no relay frame reached Meera while she was offline');
  assert.equal(meeraRelay.loginsWhileOffline, 0, 'Meera did not log in to the relay while offline');
  const loginsBefore = meeraRelay.logins;
  meeraRelay.offline = false;
  await meeraContext.setOffline(false);
  const backAt = Date.now();
  // Her app's next try connects and logs in again: a new login from her own connection.
  await waitUntil(() => meeraRelay.logins > loginsBefore, "Meera's relay login after she came back online", slow);
  console.log(
    `✓ Meera is back: she logged in to the relay ${secondsSince(backAt)} after the network returned`,
  );

  // The text also goes through the relay, sealed. The relay keeps a message for
  // an offline device for up to 60 s, and Arun's app sends it again on each
  // check (every 30 s) until Meera acknowledges it, so it arrives by itself.
  // Meera's chat is opened only after Arun sees the text delivered: opening it
  // starts a direct connection, which would deliver the text by another route.
  await bubble(arun, 'Are you there?', '(Delivered|Read)').first().waitFor({ timeout: slow });
  const deliveredIn = secondsSince(backAt);
  await openChat(meera, 'Arun Mehta');
  await bubble(meera, 'Are you there?').first().waitFor({ timeout: slow });
  // Wait before counting, so that a copy arriving late has time to show up.
  await sleep(3000);
  assert.equal(await bubble(meera, 'Are you there?').count(), 1, 'Meera\'s chat shows "Are you there?" once');
  assert.equal(await bubble(arun, 'Are you there?').count(), 1, 'Arun has exactly one "Are you there?" bubble');
  console.log(
    `✓ Meera is back: the sealed text reached her once by itself, and Arun sees it delivered (${deliveredIn} after she came back online)`,
  );

  // 4. Nothing is left to retry.
  assert.equal(await bubble(arun, 'Are you there?', 'Not sent').count(), 0, 'no "Not sent" left on Arun\'s side');
  assert.equal(
    await arun.getByRole('button', { name: 'Retry', exact: true }).count(),
    0,
    'no Retry button left on Arun\'s side',
  );
  console.log('✓ nothing is left to retry on Arun\'s side');

  // 5. Nothing readable reached the relay; no third-party hosts.
  const sends = assertRelaySawOnlyCiphertext(assert, ['Are you there', 'Meera Rao', 'Arun Mehta']);
  assert.ok(sends > 0, 'the chat sent encrypted envelopes through the relay');
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; no text or names; no third-party hosts`);
  console.log('PASS');
} catch (error) {
  for (const [name, page] of [
    ['meera', meera],
    ['arun', arun],
  ]) {
    if (!page) continue;
    for (const node of await accessibilityNodes(page)) console.error(`${name} node: ${node}`);
  }
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
