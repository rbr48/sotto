// End-to-end test of a group chat, through the real relay and real browsers.
// Meera, Arun and Ravi each have their own browser context, so Ravi can go
// offline while the others stay online:
//
//  1. All three add each other as contacts (a group needs every member to be
//     a contact of every other).
//  2. Meera makes the group "Weekend plans" with Arun and Ravi.
//  3. Arun accepts. Ravi declines, which is final for that invitation.
//  4. Meera invites Ravi again from the group info, and Ravi accepts.
//  5. Messages go both ways: each one shows its sender's name, and Meera's
//     reaches everyone.
//  6. Ravi goes offline. Meera sends; Arun gets it at once. Ravi comes back
//     and gets it from Meera's app, which stays open, once.
//  7. The relay sees only encrypted envelopes, never the group's name or the
//     members' names; the pages contact no third-party hosts.
import assert from 'node:assert/strict';
import {
  accessibilityNodes,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  connectAll,
  dumpPages,
  enableSemantics,
  launch,
  newContext,
  openApp,
  openGroup,
  openTab,
  secondsSince,
  sleep,
  timeout,
  typeInto,
  waitUntil,
  watchRelay,
} from './lib.mjs';

/** Waits for an offline member: the outbox is sent again on a 30 s check. */
const slow = 120_000;

const group = 'Weekend plans';

const browser = await launch();

/** Picks an item of the sheet or menu that is open, by its label. */
async function chooseItem(page, label) {
  await enableSemantics(page);
  const item = page
    .getByRole('menuitem', { name: label, exact: true })
    .or(page.getByRole('button', { name: label, exact: true }))
    .first();
  await item.waitFor({ timeout, polling: 250 });
  await item.click();
}

/** Ticks a contact on the new-group page. */
async function tick(page, name) {
  await enableSemantics(page);
  const box = page.getByRole('checkbox', { name: new RegExp(`^${name}`) }).first();
  await box.waitFor({ timeout, polling: 250 });
  await box.click();
  await page.waitForFunction(
    (n) =>
      [...document.querySelectorAll('[role="checkbox"]')].some(
        (node) => node.getAttribute('aria-label')?.startsWith(n) && node.getAttribute('aria-checked') === 'true',
      ),
    name,
  );
}

/** Sends a message from the open chat or group. */
async function send(page, text) {
  await typeInto(page, 'Write a message', text);
  await clickButton(page, 'Send');
}

/** A clock time as a bubble reads it ("4:21 PM", or "16:21"). */
const clock = '\\d{1,2}:\\d{2}(\\s?[AP]M)?';

/** Escapes text for use inside a RegExp. */
const escape = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * One bubble, by its whole spoken text: "Ravi Kumar, 4:21 PM: Hi" for a
 * member's message, "You, 4:21 PM, Delivered to all: Hi" for one's own. The
 * text is anchored, so the list around the bubbles never matches.
 */
const message = (page, who, text, status = '') =>
  page.getByText(new RegExp(`^${who}, ${clock}${status ? `, ${status}` : ''}: ${escape(text)}$`));

/** Waits until a group message shows on a member's page, named by its sender. */
const shown = (page, text, sender, limit = timeout) =>
  message(page, sender, text).first().waitFor({ timeout: limit });

/** Waits until one's own group message shows a state, such as "Delivered to all". */
const state = (page, text, status, limit = timeout) =>
  message(page, 'You', text, status).first().waitFor({ timeout: limit });

const everyone = '(Delivered to all|Read by all)';

let meera = null;
let arun = null;
let ravi = null;

try {
  const meeraContext = await newContext(browser);
  const arunContext = await newContext(browser);
  const raviContext = await newContext(browser);
  const raviRelay = watchRelay(raviContext);
  meera = await openApp(meeraContext, 'meera', 'Meera Rao');
  arun = await openApp(arunContext, 'arun', 'Arun Mehta');
  ravi = await openApp(raviContext, 'ravi', 'Ravi Kumar');

  // 1. Everyone adds everyone.
  await connectAll([
    { page: meera, name: 'Meera Rao' },
    { page: arun, name: 'Arun Mehta' },
    { page: ravi, name: 'Ravi Kumar' },
  ]);
  console.log('✓ contacts: Meera, Arun and Ravi have each added the other two');

  // 2. Meera makes the group with Arun and Ravi.
  await openTab(meera, 'Chats');
  await clickButton(meera, 'New chat');
  await chooseItem(meera, 'New group');
  await typeInto(meera, 'Group name', group);
  await tick(meera, 'Arun Mehta');
  await tick(meera, 'Ravi Kumar');
  await clickButton(meera, 'Create group');
  await meera.getByRole('textbox', { name: 'Write a message' }).first().waitFor({ timeout });
  console.log(`✓ Meera made "${group}" with Arun and Ravi, and the group is open`);

  // 3. Arun accepts; Ravi declines.
  await openGroup(arun, group);
  await clickButton(arun, 'Accept');
  await arun.getByRole('textbox', { name: 'Write a message' }).first().waitFor({ timeout });
  await openGroup(ravi, group);
  await clickButton(ravi, 'Decline');
  await ravi.getByText('You declined this invitation.').first().waitFor({ timeout });
  assert.equal(
    await ravi.getByRole('button', { name: 'Accept', exact: true }).count(),
    0,
    'a declined invitation can no longer be accepted',
  );
  console.log('✓ Arun accepted; Ravi declined, and his invitation can no longer be accepted');

  // 4. Meera invites Ravi again from the group info; Ravi accepts.
  await clickButton(meera, 'Group info');
  await meera
    .getByRole('group', { name: /^Ravi Kumar\s+Declined/ })
    .first()
    .waitFor({ timeout });
  await clickButton(meera, 'Invite again');
  await meera.keyboard.press('Escape');
  await clickButton(ravi, 'Accept');
  await ravi.getByRole('textbox', { name: 'Write a message' }).first().waitFor({ timeout });
  console.log('✓ Meera invited Ravi again, and he accepted');

  // 5. Messages both ways, each named by its sender.
  await send(meera, 'Hi all');
  await shown(arun, 'Hi all', 'Meera Rao');
  await shown(ravi, 'Hi all', 'Meera Rao');
  await state(meera, 'Hi all', everyone);
  await send(ravi, 'Count me in');
  await shown(meera, 'Count me in', 'Ravi Kumar');
  await shown(arun, 'Count me in', 'Ravi Kumar');
  await send(arun, 'Me too');
  await shown(meera, 'Me too', 'Arun Mehta');
  await shown(ravi, 'Me too', 'Arun Mehta');
  console.log('✓ Meera, Ravi and Arun each sent to the group; everyone sees each message with its sender');

  // 6. Ravi goes offline; Meera sends while he is away.
  await waitUntil(() => raviRelay.logins >= 1, "Ravi's login to the relay");
  const offlineAt = Date.now();
  await raviContext.setOffline(true);
  // Frames already on their way when the cut landed are not counted.
  await sleep(1000);
  raviRelay.offline = true;
  await waitUntil(
    () => raviRelay.attemptsWhileOffline > 0,
    "Ravi's app to notice the cut and try to reconnect",
    slow,
  );
  console.log(`✓ Ravi is offline: his app noticed after ${secondsSince(offlineAt)}`);

  await send(meera, 'See you Saturday');
  await shown(arun, 'See you Saturday', 'Meera Rao');
  // Arun has it; Ravi cannot yet, so it is sent to one of the two.
  await state(meera, 'See you Saturday', 'Sent to 1 of 2');
  await sleep(3000);
  assert.equal(
    await message(meera, 'You', 'See you Saturday', everyone).count(),
    0,
    'a message is not shown as delivered to all while a member is offline',
  );
  assert.equal(raviRelay.framesWhileOffline, 0, 'no relay frame reached Ravi while he was offline');
  console.log('✓ Meera sent while Ravi was offline; Arun got it, and it shows Sent to 1 of 2');

  const loginsBefore = raviRelay.logins;
  raviRelay.offline = false;
  await raviContext.setOffline(false);
  const backAt = Date.now();
  await waitUntil(() => raviRelay.logins > loginsBefore, "Ravi's relay login after he came back online", slow);
  await shown(ravi, 'See you Saturday', 'Meera Rao', slow);
  await state(meera, 'See you Saturday', everyone, slow);
  // Wait before counting, so that a copy arriving late has time to show up.
  await sleep(3000);
  assert.equal(await message(ravi, 'Meera Rao', 'See you Saturday').count(), 1, 'Ravi has the message once');
  assert.equal(await message(arun, 'Meera Rao', 'See you Saturday').count(), 1, 'Arun has the message once');
  console.log(
    `✓ Ravi is back: Meera's app sent him the message, once, ${secondsSince(backAt)} after he came back online`,
  );

  // 7. Nothing readable reached the relay; no third-party hosts.
  const sends = assertRelaySawOnlyCiphertext(assert, [
    group,
    'Meera Rao',
    'Arun Mehta',
    'Ravi Kumar',
    'Hi all',
    'Count me in',
    'Me too',
    'See you Saturday',
  ]);
  assert.ok(sends > 0, 'the group sent encrypted envelopes through the relay');
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; no group name, member names or text; no third-party hosts`);
  console.log('PASS');
} catch (error) {
  for (const [name, page] of [
    ['meera', meera],
    ['arun', arun],
    ['ravi', ravi],
  ]) {
    if (!page) continue;
    for (const node of await accessibilityNodes(page)) console.error(`${name} node: ${node}`);
  }
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
