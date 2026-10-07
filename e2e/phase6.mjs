// End-to-end test of the professional app essentials (Phase 6):
//
//  1. Onboarding: name and practice; guest links carry "Name (Practice)".
//  2. Contacts: Meera shares her contact link (also as a QR code); Arun
//     adds her from the link and calls her from his contacts.
//  3. Call screens: names, a running call timer and a quality indicator.
//  4. History on both devices with talk time; a private session note.
//  5. App lock: set a PIN, lock; an incoming call still rings on top of the
//     lock; a wrong PIN is refused, the right one unlocks.
//  6. Device picker lists the camera and microphone.
//  7. The relay never sees names, practices, notes or the PIN.
import assert from 'node:assert/strict';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  dataAttribute,
  enableSemantics,
  enterPin,
  launch,
  newContext,
  openApp,
  openTab,
  readAttribute,
  setPin,
  titleIncludes,
  typeInto,
} from './lib.mjs';

const browser = await launch();
const note = 'Discussed the referral; follow up Tuesday';
const pin = '135790';

try {
  const context = await newContext(browser);

  // 1. Onboarding with a practice name.
  const meera = await openApp(context, 'meera', 'Dr Meera Rao', { practice: 'Lotus Clinic' });
  await meera.waitForFunction(() => {
    const link = document.documentElement.getAttribute('data-sotto-guest-link');
    if (!link) return false;
    const payload = link.split('#g=')[1].replace(/-/g, '+').replace(/_/g, '/');
    return atob(payload).includes('"n":"Dr Meera Rao (Lotus Clinic)"');
  });
  console.log('✓ onboarding: guest links show "Dr Meera Rao (Lotus Clinic)"');

  // 2. Share and add a contact.
  await openTab(meera, 'Contacts');
  await clickButton(meera, 'Share my contact');
  await enableSemantics(meera);
  await meera.getByText('QR code of your contact link').or(meera.locator('[aria-label="QR code of your contact link"]')).first().waitFor();
  const contactLink = await readAttribute(meera, 'contact-link');
  assert.ok(contactLink.includes('/#c='), 'contact link keeps details in the fragment');
  await clickButton(meera, 'Done');

  const arun = await openApp(context, 'arun', 'Arun Mehta');
  await openTab(arun, 'Contacts');
  await clickButton(arun, 'Add contact');
  await typeInto(arun, 'Contact link', contactLink);
  await clickButton(arun, 'Next');
  await clickButton(arun, 'Save contact');
  await arun.getByRole('button', { name: /^Dr Meera Rao[\s\S]*Lotus Clinic/ }).waitFor();
  console.log('✓ Arun added Meera from her contact link (name and practice from the signed link)');

  // 3. Call from contacts; names, timer, quality.
  await clickButton(arun, 'Video call Dr Meera Rao');
  await titleIncludes(meera, 'Incoming call');
  await meera.getByText('Unknown caller').first().waitFor();
  await clickButton(meera, 'Accept');
  await Promise.all([titleIncludes(arun, 'Connected'), titleIncludes(meera, 'Connected')]);
  await arun.getByText('Dr Meera Rao (Lotus Clinic)').first().waitFor();
  const timer = async (page) => {
    await enableSemantics(page);
    return page.waitForFunction(() =>
      [...document.querySelectorAll('flt-semantics, span, flt-paragraph')].some((e) =>
        /^0:0[2-9]$/.test(e.textContent.trim()),
      ),
    );
  };
  await Promise.all([timer(arun), timer(meera)]);
  await Promise.all([
    arun.waitForFunction(() => document.documentElement.hasAttribute('data-sotto-quality')),
    meera.waitForFunction(() => document.documentElement.hasAttribute('data-sotto-quality')),
  ]);
  const quality = await readAttribute(arun, 'quality');
  console.log(`✓ call from contacts: names shown, timer running, quality "${quality}"`);
  await arun.waitForTimeout(1500);
  await clickButton(arun, 'Hang up');
  await titleIncludes(meera, 'Call ended (they hung up)');
  await titleIncludes(arun, 'Call ended (you hung up)');

  // 4. History and a session note.
  await clickButton(arun, 'Add note');
  await typeInto(arun, /Session note/, note);
  await clickButton(arun, 'Save');
  await clickButton(arun, 'OK');
  await openTab(arun, 'History');
  const entry = arun.getByRole('button', {
    name: /^Dr Meera Rao \(Lotus Clinic\)[\s\S]*Today[\s\S]*0:0\d · video[\s\S]*Has a note/,
  });
  await entry.waitFor();
  await entry.click();
  // The note is shown again when the entry is opened.
  await arun.getByRole('textbox', { name: /Session note/ }).first().click();
  await arun.waitForFunction((n) => document.activeElement?.value === n, note);
  await clickButton(arun, 'Save');
  await openTab(meera, 'History');
  await meera.getByRole('button', { name: /^Unknown caller[\s\S]*Today[\s\S]*0:0\d · video/ }).waitFor();
  console.log('✓ both devices list the call with its talk time; the note is kept with it');

  // 5. App lock.
  await openTab(meera, 'Settings');
  await clickButton(meera, 'Set a PIN');
  await setPin(meera, pin);
  await clickButton(meera, 'Lock now');
  await titleIncludes(meera, 'Locked');

  await openTab(arun, 'Contacts');
  await clickButton(arun, 'Voice call Dr Meera Rao');
  await titleIncludes(meera, 'Incoming call');
  await clickButton(meera, 'Decline');
  await titleIncludes(arun, 'Call ended (declined)');
  await titleIncludes(meera, 'Locked');
  console.log('✓ a call rang on top of the lock; after it, the app is locked again');

  await enterPin(meera, '000000', 'Unlock');
  await meera.getByText('Wrong PIN.').first().waitFor();
  await enterPin(meera, pin, 'Unlock');
  await titleIncludes(meera, 'Call ended (you declined)');
  console.log('✓ a wrong PIN is refused; the right PIN unlocks');

  // 6. Devices.
  await clickButton(meera, 'OK');
  await openTab(meera, 'Settings');
  await meera.getByText('Camera', { exact: true }).first().waitFor();
  const radios = await meera.getByRole('radio').count();
  assert.ok(radios >= 4, `expected default + fake camera/mic choices, saw ${radios}`);
  console.log(`✓ device picker lists ${radios} choices (system defaults and the fake devices)`);

  // 7. Nothing readable reached the relay.
  const sends = assertRelaySawOnlyCiphertext(assert, ['Meera', 'Lotus', 'Arun', 'Tuesday', pin]);
  assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ relay saw ${sends} encrypted messages; no names, notes or PIN`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
