// End-to-end test of the actions on a chat message (reply, react, forward,
// edit and delete for everyone), through the real relay and real browsers.
// Meera, Arun and Ravi each have their own browser context:
//
//  1. Meera, Arun and Ravi add each other as contacts, and Meera and Arun open
//     their chat (Meera first, so she sees each message arrive live).
//  2. Arun sends "Hello". Meera replies to it with "Got it", quoting "Hello"
//     (each side shows one quote).
//  3. Arun reacts to Meera's reply with a thumbs up, and Meera sees it.
//  4. Arun forwards "Hello" to Ravi, and Ravi sees it marked Forwarded.
//  5. Arun edits "Hello" to "Hello again", and Meera sees Edited and the new
//     text.
//  6. Arun deletes his message for everyone, and Meera sees "Message deleted".
//  7. The relay sees only encrypted envelopes; the pages contact no third-party
//     hosts.
import assert from 'node:assert/strict';
import {
  addContact,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  bubble,
  clickButton,
  dataAttribute,
  dumpPages,
  enableSemantics,
  launch,
  longPressBubble,
  newContext,
  openApp,
  openChat,
  shareContactLink,
  timeout,
  typeInto,
} from './lib.mjs';

const browser = await launch();

/** Adds text at the end of the composer's text, as a user does after Edit. */
async function appendToComposer(page, text) {
  await enableSemantics(page);
  const field = page.getByRole('textbox', { name: 'Write a message' });
  await field.first().waitFor({ timeout, polling: 250 });
  await field.first().click();
  await page.keyboard.press('End');
  await page.keyboard.type(text, { delay: 20 });
  await page.waitForFunction((t) => document.activeElement?.value?.endsWith(t), text, {
    timeout,
    polling: 250,
  });
}

/** Picks an item of the menu or sheet that is open, by its label. */
async function chooseMenuItem(page, label) {
  await enableSemantics(page);
  const item = page
    .getByRole('menuitem', { name: label, exact: true })
    .or(page.getByRole('button', { name: label, exact: true }))
    .first();
  await item.waitFor({ timeout, polling: 250 });
  await item.click();
}

/** Opens the menu of a bubble and picks an item from it. */
async function actOn(page, text, label) {
  await longPressBubble(page, text);
  await chooseMenuItem(page, label);
}

/**
 * Waits until the open chat shows `count` quotes. A quote is left out of the
 * accessibility tree, so the page publishes how many it shows instead.
 */
async function quotesShown(page, count) {
  await dataAttribute(page, 'quotes', String(count));
}

let meera = null;
let arun = null;
let ravi = null;

try {
  const meeraContext = await newContext(browser);
  const arunContext = await newContext(browser);
  const raviContext = await newContext(browser);
  meera = await openApp(meeraContext, 'meera', 'Meera Rao');
  arun = await openApp(arunContext, 'arun', 'Arun Mehta');
  ravi = await openApp(raviContext, 'ravi', 'Ravi Kumar');

  // 1. Each adds the others, then Meera and Arun open their chat.
  const meeraLink = await shareContactLink(meera);
  const arunLink = await shareContactLink(arun);
  const raviLink = await shareContactLink(ravi);
  await addContact(arun, meeraLink, 'Meera Rao');
  await addContact(meera, arunLink, 'Arun Mehta');
  await addContact(arun, raviLink, 'Ravi Kumar');
  await addContact(ravi, arunLink, 'Arun Mehta');
  await openChat(meera, 'Arun Mehta');
  await openChat(arun, 'Meera Rao');
  console.log('✓ contacts: Meera, Arun and Ravi have added each other; Meera and Arun have their chat open');

  // 2. Arun sends "Hello"; Meera replies to it.
  await typeInto(arun, 'Write a message', 'Hello');
  await clickButton(arun, 'Send');
  await meera.getByText('Hello').first().waitFor();
  await bubble(arun, 'Hello', '(Delivered|Read)').first().waitFor();
  await actOn(meera, 'Hello', 'Reply');
  await typeInto(meera, 'Write a message', 'Got it');
  await clickButton(meera, 'Send');
  await bubble(arun, 'Got it').first().waitFor();
  await bubble(meera, 'Got it', '(Delivered|Read)').first().waitFor();
  await quotesShown(arun, 1);
  await quotesShown(meera, 1);
  console.log('✓ Arun sent "Hello"; Meera replied to it, and both sides show the quote');

  // 3. Arun reacts to Meera's reply with a thumbs up.
  await actOn(arun, 'Got it', 'React');
  await clickButton(arun, '👍');
  await meera.getByRole('button', { name: '👍, Arun Mehta' }).first().waitFor();
  console.log('✓ Arun reacted to Meera\'s reply with a thumbs up; Meera sees it');

  // 4. Arun forwards "Hello" to Ravi, who sees it marked Forwarded.
  await openChat(ravi, 'Arun Mehta');
  await actOn(arun, 'Hello', 'Forward');
  await chooseMenuItem(arun, 'Ravi Kumar');
  await bubble(ravi, 'Hello', 'Forwarded').first().waitFor();
  console.log('✓ Arun forwarded "Hello" to Ravi, and Ravi sees it marked Forwarded');

  // 5. Arun edits "Hello" to "Hello again"; Meera sees the edit.
  await actOn(arun, 'Hello', 'Edit');
  await appendToComposer(arun, ' again');
  await clickButton(arun, 'Send');
  await bubble(meera, 'Hello again', 'Edited').first().waitFor();
  await bubble(arun, 'Hello again', 'Edited').first().waitFor();
  console.log('✓ Arun edited "Hello" to "Hello again"; Meera sees Edited and the new text');

  // 6. Arun deletes his message for everyone; Meera sees the placeholder.
  await actOn(arun, 'Hello again', 'Delete for everyone');
  await clickButton(arun, 'Delete for everyone');
  await bubble(meera, 'Message deleted').first().waitFor();
  await bubble(arun, 'Message deleted').first().waitFor();
  console.log('✓ Arun deleted his message for everyone; Meera sees "Message deleted"');

  // 7. Nothing readable reached the relay; no third-party hosts.
  const sends = assertRelaySawOnlyCiphertext(assert, [
    'Hello',
    'Got it',
    'Meera Rao',
    'Arun Mehta',
    'Ravi Kumar',
    '👍',
  ]);
  assert.ok(sends > 0, 'the chat sent encrypted envelopes through the relay');
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; no text or names; no third-party hosts`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
