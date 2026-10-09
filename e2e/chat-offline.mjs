// End-to-end test of the failure path of chat, through the real relay and real
// browsers. Meera and Arun are contacts, each in its own browser context, so
// Meera can go offline while Arun stays online:
//
//  1. Meera and Arun add each other as contacts, and Arun opens the chat with
//     Meera while she is online.
//  2. Meera goes offline. Arun sends "Are you there?". Nobody answers the open,
//     so the message shows "Not sent: Meera Rao is offline", with a Retry button and the problem
//     banner.
//  3. Meera comes back online. The message must not arrive by itself, and
//     Arun's app must send nothing to the relay: a new session starts with an
//     open, which is a send.
//  4. Arun presses Retry while Meera is online. The message is delivered, and
//     Meera's chat shows it once.
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

const isRelayUrl = (url) => /\/relay$/.test(url);

/**
 * Meera's relay connection, watched from her browser context.
 *
 * In Chromium, setOffline(true) does not close a WebSocket. The socket stays
 * open, and the browser holds its frames both ways until the network returns.
 * So the cut is confirmed rather than assumed: her app's ping goes unanswered,
 * so it drops the socket and tries to connect again, and each try fails while
 * she is offline. No frame may reach her meanwhile.
 */
const meeraRelay = {
  offline: false, // set 1 s after the cut, cleared before she comes back
  logins: 0, // login messages she sent, online or not
  loginsWhileOffline: 0,
  framesReceived: 0, // every frame her relay connections received
  framesWhileOffline: 0,
  attemptsWhileOffline: 0, // relay connections her app opened while offline
};

/**
 * Relay sends from Arun's browser. A message can only go out again through a
 * new session, and a session starts with a send.
 */
const arunRelay = { sends: 0 };

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
  // Watch both relay connections from the start, before the pages open them.
  meeraContext.on('page', (page) => {
    page.on('websocket', (ws) => {
      // A try made while she is offline is a relay connection that never opens.
      if (meeraRelay.offline && isRelayUrl(ws.url())) meeraRelay.attemptsWhileOffline += 1;
      ws.on('framereceived', () => {
        meeraRelay.framesReceived += 1;
        if (meeraRelay.offline) meeraRelay.framesWhileOffline += 1;
      });
      ws.on('framesent', ({ payload }) => {
        if (!String(payload).includes('"type":"auth"')) return;
        meeraRelay.logins += 1;
        if (meeraRelay.offline) meeraRelay.loginsWhileOffline += 1;
      });
    });
  });
  arunContext.on('page', (page) => {
    page.on('websocket', (ws) => {
      ws.on('framesent', ({ payload }) => {
        if (String(payload).includes('"type":"send"')) arunRelay.sends += 1;
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
  // Positive controls: while she is online, her login and her frames are
  // counted, so the zero counts checked later can tell a cut from a broken counter.
  await waitUntil(() => meeraRelay.logins >= 1, "Meera's login to the relay");
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
  await waitUntil(() => arunRelay.sends > sendsBeforeMessage, "Arun's app to send the open to the relay");
  await bubble(arun, 'Not sent: Meera Rao is offline').first().waitFor({ timeout: slow });
  const notSentIn = secondsSince(sentAt);
  // The plan's wording (docs/MESSAGING_PLAN.md, "Offline").
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
  console.log(
    `✓ Arun sees "Not sent: Meera Rao is offline", a Retry button and the problem banner, ${notSentIn} after sending`,
  );

  // 3. Meera comes back online. Nothing may have reached her while she was
  // offline, and she did not log in while offline.
  assert.equal(meeraRelay.framesWhileOffline, 0, 'no relay frame reached Meera while she was offline');
  assert.equal(meeraRelay.loginsWhileOffline, 0, 'Meera did not log in to the relay while offline');
  const loginsBefore = meeraRelay.logins;
  const sendsBeforeReturn = arunRelay.sends;
  meeraRelay.offline = false;
  await meeraContext.setOffline(false);
  const backAt = Date.now();
  // Her app's next try connects and logs in again: a new login from her own connection.
  await waitUntil(() => meeraRelay.logins > loginsBefore, "Meera's relay login after she came back online");
  console.log(
    `✓ Meera is back: she logged in to the relay ${secondsSince(backAt)} after the network returned`,
  );

  // Meera opens her chat with Arun. For 35 s, Arun's app must stay silent and
  // the message must not arrive. The window is longer than the chat's 30 s
  // ticker, so a resend that the ticker starts would show up as a send here.
  await openChat(meera, 'Arun Mehta');
  await sleep(35_000);
  assert.equal(
    arunRelay.sends,
    sendsBeforeReturn,
    "Arun's app sent nothing to the relay after Meera came back (no background resend)",
  );
  assert.equal(await bubble(meera).count(), 0, 'Meera must not get the message by itself');
  assert.equal(
    await bubble(arun, 'Not sent: Meera Rao is offline').count(),
    1,
    'Arun still shows "Not sent: Meera Rao is offline"',
  );
  assert.equal(await bubble(arun, 'Delivered').count(), 0, 'Arun does not see "Delivered" yet');
  console.log(
    '✓ Meera is back and her chat is open: in 35 s the message did not arrive, Arun sent nothing, and Arun still shows "Not sent: Meera Rao is offline"',
  );

  // 4. Arun presses Retry while Meera is online. The same message (same id) goes
  // out again, and it shows once in Meera's chat.
  await clickButton(arun, 'Retry');
  await bubble(arun, 'Delivered').first().waitFor({ timeout: slow });
  const deliveredIn = secondsSince(backAt);
  await bubble(meera).first().waitFor({ timeout: slow });
  // Wait before counting, so that a copy arriving late has time to show up.
  await sleep(3000);
  assert.equal(await bubble(meera).count(), 1, 'Meera\'s chat shows "Are you there?" once');
  assert.equal(await bubble(arun).count(), 1, 'Arun has exactly one "Are you there?" bubble');
  assert.equal(await bubble(arun, 'Not sent').count(), 0, 'no "Not sent" left on Arun\'s side');
  assert.equal(
    await arun.getByRole('button', { name: 'Retry', exact: true }).count(),
    0,
    'no Retry button left on Arun\'s side',
  );
  console.log(
    `✓ Arun pressed Retry: Delivered, and Meera's chat shows "Are you there?" once (${deliveredIn} after she came back online)`,
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
