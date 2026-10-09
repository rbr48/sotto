// End-to-end test of the failure path of chat, through the real relay and real
// browsers. Meera and Arun are contacts, each in its own browser context, so
// Meera can go offline while Arun stays online:
//
//  1. Meera and Arun add each other as contacts, and Arun opens the chat with
//     Meera while she is online.
//  2. Meera goes offline. Arun sends "Are you there?". Nobody answers the open,
//     so the message shows "Not sent", with a Retry button and the problem
//     banner.
//  3. Meera comes back online. The message must not arrive by itself.
//  4. Arun presses Retry while Meera is online. The message is delivered, and
//     Meera sees it exactly once.
//  5. The relay sees only encrypted envelopes; the pages contact no third-party
//     hosts.
import assert from 'node:assert/strict';
import {
  addContact,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dumpPages,
  framesToRelay,
  launch,
  newContext,
  openApp,
  openChat,
  shareContactLink,
  typeInto,
} from './lib.mjs';

/** Failure-path waits: a missed open is reported 20 to 50 s after the send. */
const slow = 90_000;

const browser = await launch();

/** Auth frames sent to the relay so far, by any page. */
const authFrames = () =>
  framesToRelay.filter((frame) => frame.includes('"type":"auth"')).length;

/**
 * Meera's relay connection, watched from her browser context while she is
 * offline. A cut connection can die without a close event, so the evidence is
 * what the app does (failed reconnects) and what reaches her (frames).
 */
const meeraRelay = {
  offline: false,
  receivedTotal: 0, // every frame her relay connection received (shows the counter works)
  retriesWhileOffline: 0,
  framesWhileOffline: 0,
  loginsWhileOffline: 0,
};

/** Polls until `check()` holds, or fails after `limit` ms. */
async function waitUntil(check, what, limit = slow) {
  for (const end = Date.now() + limit; !check(); ) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const secondsSince = (from) => `${((Date.now() - from) / 1000).toFixed(1)} s`;

/**
 * The bubble of the "Are you there?" message, with its status ("Sending",
 * "Not sent", "Delivered") when given. Flutter exposes a bubble's words either
 * as text (a Delivered or incoming bubble) or as the accessible name of its
 * group (a Not sent bubble, whose Retry button is its only text), so both are
 * matched.
 */
const bubble = (page, status = '') => {
  const pattern = status ? new RegExp(`Are you there\\?\\s*${status}`) : /Are you there\?/;
  return page.getByText(pattern).or(page.getByRole('group', { name: pattern }));
};

/** The accessibility nodes on a page that carry a label or text, for failure output. */
const accessibilityNodes = (page) =>
  page
    .evaluate(() =>
      [...document.querySelectorAll('flt-semantics')]
        .map((node) => {
          const label = node.getAttribute('aria-label');
          const text = node.textContent;
          if (!label && !text) return null;
          return `${node.tagName.toLowerCase()} role=${node.getAttribute('role') ?? '-'} label=${JSON.stringify(label)} text=${JSON.stringify(text)}`;
        })
        .filter(Boolean),
    )
    .catch(() => []);

let meera = null;
let arun = null;

try {
  const meeraContext = await newContext(browser);
  const arunContext = await newContext(browser);
  // Watch Meera's relay connection from the start, before her page opens it.
  meeraContext.on('page', (page) => {
    page.on('console', (message) => {
      if (meeraRelay.offline && /WebSocket connection to .* failed/.test(message.text())) {
        meeraRelay.retriesWhileOffline += 1;
      }
    });
    page.on('websocket', (ws) => {
      ws.on('framereceived', () => {
        meeraRelay.receivedTotal += 1;
        if (meeraRelay.offline) meeraRelay.framesWhileOffline += 1;
      });
      ws.on('framesent', ({ payload }) => {
        if (meeraRelay.offline && String(payload).includes('"type":"auth"')) {
          meeraRelay.loginsWhileOffline += 1;
        }
      });
    });
  });
  meera = await openApp(meeraContext, 'meera', 'Meera Rao');
  arun = await openApp(arunContext, 'arun', 'Arun Mehta');

  // 1. Each adds the other; Arun opens the chat with Meera while she is online.
  const meeraContactLink = await shareContactLink(meera);
  const arunContactLink = await shareContactLink(arun);
  await addContact(arun, meeraContactLink, 'Meera Rao');
  await addContact(meera, arunContactLink, 'Arun Mehta');
  await openChat(arun, 'Meera Rao');
  console.log('✓ contacts: Meera and Arun have added each other; Arun has the chat with Meera open');

  // 2. Meera goes offline. Her app notices that its relay connection has stopped
  // answering (a ping every 25 s, 10 s to answer), then tries to reconnect, and
  // each try fails while she is offline. Wait for the first failed try, so that
  // Arun sends only once she is really cut off.
  const receivedBefore = meeraRelay.receivedTotal;
  const offlineAt = Date.now();
  meeraRelay.offline = true;
  await meeraContext.setOffline(true);
  await waitUntil(
    () => meeraRelay.retriesWhileOffline > 0,
    "Meera's app to notice that it is offline and try to reconnect",
  );
  console.log(
    `✓ Meera is offline: her app noticed after ${secondsSince(offlineAt)} and tried to reconnect ` +
      `(her connection had received ${receivedBefore} relay frames before going offline)`,
  );

  // Arun sends. Nobody answers the open, so after the timeout the message is
  // marked not sent, with the Retry button and the banner.
  const sentAt = Date.now();
  await typeInto(arun, 'Write a message', 'Are you there?');
  await clickButton(arun, 'Send');
  await bubble(arun, 'Not sent').first().waitFor({ timeout: slow });
  const notSentIn = secondsSince(sentAt);
  await arun
    .getByText('The connection could not be made. Your messages were not sent; you can retry.')
    .first()
    .waitFor({ timeout: slow });
  assert.equal(await bubble(arun).count(), 1, 'Arun has exactly one "Are you there?" bubble');
  assert.equal(
    await arun.getByRole('button', { name: 'Retry', exact: true }).count(),
    1,
    'Arun has one Retry button',
  );
  // Nothing reached Meera while she was offline, and she did not log in.
  assert.equal(meeraRelay.framesWhileOffline, 0, 'no relay frame reached Meera while she was offline');
  assert.equal(meeraRelay.loginsWhileOffline, 0, 'Meera did not log in to the relay while offline');
  console.log(
    `✓ Arun sees "Not sent", a Retry button and the problem banner, ${notSentIn} after sending; Meera received no relay frame while offline`,
  );

  // 3. Meera comes back online. Her app logs in again: that is the new auth
  // frame, since Arun does not log in again. Then give the relay 2 s to
  // deliver anything queued for her.
  const authBefore = authFrames();
  meeraRelay.offline = false;
  await meeraContext.setOffline(false);
  await waitUntil(() => authFrames() > authBefore, "Meera's relay login after reconnecting");
  const backAt = Date.now();
  await sleep(2000);
  console.log('✓ Meera is back online; the relay has had 2 s to deliver anything queued for her');

  // Meera opens her chat with Arun and waits 5 s. The message must not arrive
  // by itself, and Arun still shows "Not sent".
  await openChat(meera, 'Arun Mehta');
  await sleep(5000);
  assert.equal(await bubble(meera).count(), 0, 'Meera must not get the message by itself');
  assert.equal(await bubble(arun, 'Not sent').count(), 1, 'Arun still shows "Not sent"');
  assert.equal(await bubble(arun, 'Delivered').count(), 0, 'Arun does not see "Delivered" yet');
  console.log(
    '✓ Meera is back and her chat is open: the message did not arrive; Arun still shows "Not sent"',
  );

  // 4. Arun presses Retry while Meera is online. The message goes out again,
  // with the same id, and Meera sees it exactly once.
  await clickButton(arun, 'Retry');
  await bubble(arun, 'Delivered').first().waitFor({ timeout: slow });
  const deliveredIn = secondsSince(backAt);
  await bubble(meera).first().waitFor({ timeout: slow });
  assert.equal(await bubble(meera).count(), 1, 'Meera sees "Are you there?" exactly once');
  assert.equal(await bubble(arun).count(), 1, 'Arun has exactly one "Are you there?" bubble');
  assert.equal(await bubble(arun, 'Not sent').count(), 0, 'no "Not sent" left on Arun\'s side');
  assert.equal(
    await arun.getByRole('button', { name: 'Retry', exact: true }).count(),
    0,
    'no Retry button left on Arun\'s side',
  );
  console.log(
    `✓ Arun pressed Retry: Delivered, and Meera sees "Are you there?" once (${deliveredIn} after she came back online)`,
  );

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
