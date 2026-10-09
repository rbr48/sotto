// End-to-end test of peer-to-peer messages (chat), through the real relay and
// real browsers:
//
//  1. Meera and Arun add each other as contacts (chats need contacts on both
//     sides), each from the other's contact link.
//  2. Meera opens the chat with Arun and leaves it open. Arun writes; the
//     message goes straight to Meera, who sees it arrive, and Arun sees it
//     delivered.
//  3. Meera replies in the open chat; Arun sees the reply arrive.
//  4. The relay sees only encrypted envelopes: no message text, names or
//     connection details; the pages contact no third-party hosts.
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

const browser = await launch();

try {
  const context = await newContext(browser);
  const meera = await openApp(context, 'meera', 'Meera Rao');
  const arun = await openApp(context, 'arun', 'Arun Mehta');

  // 1. Each adds the other.
  const meeraLink = await shareContactLink(meera);
  const arunLink = await shareContactLink(arun);
  await addContact(arun, meeraLink, 'Meera Rao');
  await addContact(meera, arunLink, 'Arun Mehta');
  console.log('✓ contacts: Meera and Arun have added each other from their links');

  // 2. Meera opens the chat first, so she sees the message arrive live.
  await openChat(meera, 'Arun Mehta');
  await openChat(arun, 'Meera Rao');
  await typeInto(arun, 'Write a message', 'Salaam from Arun');
  await clickButton(arun, 'Send');
  await arun.getByText('Salaam from Arun').first().waitFor();
  // Meera has the chat open, so her read receipt can arrive first: either status
  // means the message got to her device.
  await arun.getByText(/Delivered|Read/).first().waitFor();
  await meera.getByText('Salaam from Arun').first().waitFor();
  console.log('✓ Arun wrote; Meera saw it arrive, and Arun sees it delivered');

  // 3. Meera replies in the open chat; Arun sees it arrive.
  await typeInto(meera, 'Write a message', 'Wa alaikum from Meera');
  await clickButton(meera, 'Send');
  await meera.getByText('Wa alaikum from Meera').first().waitFor();
  await arun.getByText('Wa alaikum from Meera').first().waitFor();
  console.log('✓ Meera replied; Arun sees the reply in the open chat');

  // 4. Nothing readable reached the relay; no third-party hosts.
  const sends = assertRelaySawOnlyCiphertext(assert, [
    'Salaam',
    'Wa alaikum',
    'Meera Rao',
    'Arun Mehta',
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
