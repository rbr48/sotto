// Guest pages on Safari's engine (WebKit), with the professional in Chromium:
//
//  1. The crypto self-test (libsodium in WebAssembly) passes in WebKit.
//  2. A signed guest link opens: the professional's name is verified and
//     shown, and the device check starts.
//  3. Without camera or microphone access, the guest is told how to allow
//     it and can't knock yet.
//  4. A signed contact link opens and verifies; a tampered guest link is
//     rejected.
//  5. WebKit pages only contacted their own server.
//
// Not covered: a live call. Playwright's Linux WebKit always refuses camera
// and microphone access, so the call itself (WebRTC between Safari and
// Chromium) still needs a manual check on a real iPhone and Mac (see
// e2e/README.md).
import assert from 'node:assert/strict';
import { webkit } from 'playwright';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  base,
  clickButton,
  enableSemantics,
  launch,
  newContext,
  openApp,
  openPage,
  openTab,
  readAttribute,
  titleIncludes,
} from './lib.mjs';

const chromium = await launch();
const safari = await webkit.launch();

/** Waits for text on a Flutter page (in its accessibility tree). */
async function seesText(page, text) {
  await enableSemantics(page);
  const exact = typeof text === 'string';
  await page.getByText(text, { exact }).first().waitFor({ timeout: 60_000 });
}

try {
  const safariContext = await safari.newContext({ locale: 'en-US' });

  // 1. Crypto self-test.
  const selfTest = await openPage(safariContext, 'safari-self-test', new URL('?selftest=1', base).toString());
  await titleIncludes(selfTest, 'Self-test passed');
  await selfTest.close();
  console.log('✓ crypto self-test passed in WebKit');

  // 2–3. A guest link: verified name, device check, clear advice without devices.
  const pro = await openApp(await newContext(chromium), 'professional', 'Dr Rao');
  const guestLink = await readAttribute(pro, 'guest-link');
  const guest = await openPage(safariContext, 'safari-guest', guestLink);
  await titleIncludes(guest, 'Check your camera');
  await seesText(guest, 'Call with Dr Rao');
  console.log('✓ the signed guest link opened in WebKit and shows "Call with Dr Rao"');
  await seesText(guest, /could not use your camera or microphone/);
  const join = guest.getByRole('button', { name: 'Join with video' }).first();
  assert.equal(await join.isDisabled(), true, 'no knocking without camera or microphone');
  console.log('✓ without camera access, the guest is told how to allow it and cannot knock yet');

  // 4. A contact link, then a tampered guest link.
  await openTab(pro, 'Contacts');
  await clickButton(pro, 'Share my contact');
  const contactLink = await readAttribute(pro, 'contact-link');
  const contact = await openPage(safariContext, 'safari-contact', contactLink);
  await titleIncludes(contact, 'Ready');
  await seesText(contact, 'Call Dr Rao');
  await contact.getByRole('button', { name: /Video call/ }).first().waitFor({ timeout: 60_000 });
  console.log('✓ the signed contact link opened in WebKit with call buttons');

  const [prefix, payload] = guestLink.split('#g=');
  const json = Buffer.from(payload, 'base64url').toString();
  const forged = Buffer.from(json.replace('"n":"Dr Rao"', '"n":"Bank of X"')).toString('base64url');
  const tampered = await openPage(safariContext, 'safari-tampered', `${prefix}#g=${forged}`);
  await titleIncludes(tampered, 'Link not valid');
  console.log('✓ a tampered link is rejected in WebKit');

  // 5. Privacy.
  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await safari.close();
  await chromium.close();
}
