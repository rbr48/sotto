// End-to-end test of guest links (Phase 5) through the real relay:
//
//  1. A professional's personal guest link opens a guest page in a fresh
//     browser: device check, name, "Join with video" → waiting room.
//  2. The professional admits the guest → live video call → hang up.
//  3. The guest knocks again and the professional declines.
//  4. Replacing the personal link makes the old link stop working.
//  5. A one-time link works once; the second visitor is told it was used.
//  6. A tampered link is rejected before anything is sent.
//  7. The relay never sees guest names or any readable guest/call data.
import assert from 'node:assert/strict';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  assertRelaySawOnlyCiphertext,
  base,
  clickButton,
  launch,
  newContext,
  openPage,
  readAttribute,
  titleIncludes,
  typeInto,
  videoPlaying,
  dataAttribute,
} from './lib.mjs';

const browser = await launch();

/** Opens a guest link, waits for the device check and knocks. */
async function knock(context, label, link, { name, voiceOnly = false } = {}) {
  const guest = await openPage(context, label, link);
  await titleIncludes(guest, 'Check your camera');
  if (name) await typeInto(guest, /Your name/, name);
  await clickButton(guest, voiceOnly ? 'Join with voice only' : 'Join with video');
  return guest;
}

try {
  const context = await newContext(browser);

  const pro = await openPage(context, 'professional', base);
  await titleIncludes(pro, 'Ready');
  await typeInto(pro, /Your name, as guests will see it/, 'Dr Rao');
  await pro.waitForFunction(
    () => {
      const link = document.documentElement.getAttribute('data-sotto-guest-link');
      if (!link) return false;
      const payload = link.split('#g=')[1];
      const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
      return json.includes('"n":"Dr Rao"');
    },
    null,
    { timeout: 30_000, polling: 250 },
  );
  const personalLink = await readAttribute(pro, 'guest-link');
  assert.ok(personalLink.includes('/#g='), 'guest link uses the URL fragment');
  console.log('✓ professional has a personal guest link with their name');

  // 1–2. Knock, admit, talk, hang up.
  const asha = await knock(context, 'asha', personalLink, { name: 'Asha Verma' });
  await titleIncludes(asha, 'Waiting to be let in');
  console.log('✓ guest checked devices and is waiting to be let in');

  await clickButton(pro, 'Admit');
  await Promise.all([titleIncludes(asha, 'Connected'), titleIncludes(pro, 'Connected')]);
  await Promise.all([videoPlaying(asha), videoPlaying(pro)]);
  console.log('✓ professional admitted the guest; live video call');

  await clickButton(pro, 'Hang up');
  await titleIncludes(asha, 'Call ended (they hung up)');
  await clickButton(pro, 'OK');
  console.log('✓ hang up reached the guest');

  // 3. Knock again, get declined.
  await clickButton(asha, 'Join again');
  await titleIncludes(asha, 'Check your camera');
  await clickButton(asha, 'Join with voice only');
  await titleIncludes(asha, 'Waiting to be let in');
  await clickButton(pro, 'Decline');
  await titleIncludes(asha, 'Declined (declined)');
  console.log('✓ professional declined the second knock');

  // 4. Replace the personal link: the old one stops working.
  await clickButton(pro, 'Replace personal link (the old one stops working)');
  await pro.waitForFunction(
    (old) => document.documentElement.getAttribute('data-sotto-guest-link') !== old,
    personalLink,
  );
  const oldLinkGuest = await knock(context, 'old-link', personalLink);
  await titleIncludes(oldLinkGuest, 'Declined (revoked)');
  console.log('✓ the replaced link no longer works');

  // 5. One-time link: first guest gets in, second is told it was used.
  await clickButton(pro, 'Create one-time link');
  await pro.waitForFunction(
    () => document.documentElement.getAttribute('data-sotto-one-time-link'),
  );
  const oneTime = await readAttribute(pro, 'one-time-link');
  const first = await knock(context, 'one-time-1', oneTime);
  await titleIncludes(first, 'Waiting to be let in');
  await clickButton(pro, 'Admit');
  await Promise.all([titleIncludes(first, 'Connected'), titleIncludes(pro, 'Connected')]);
  await clickButton(first, 'Hang up');
  await titleIncludes(pro, 'Call ended');
  const second = await knock(context, 'one-time-2', oneTime);
  await titleIncludes(second, 'Declined (used)');
  console.log('✓ one-time link worked once, then reported as used');

  // 6. A tampered link is rejected on the guest's device.
  const fresh = await readAttribute(pro, 'guest-link');
  const [prefix, payload] = fresh.split('#g=');
  const json = Buffer.from(payload, 'base64url').toString();
  const forged = Buffer.from(json.replace('"n":"Dr Rao"', '"n":"Bank of X"')).toString('base64url');
  const tampered = await openPage(context, 'tampered', `${prefix}#g=${forged}`);
  await titleIncludes(tampered, 'Link not valid');
  console.log('✓ a tampered link is rejected');

  // 7. Privacy: nothing readable reached the relay, including names.
  const sends = assertRelaySawOnlyCiphertext(assert, ['Asha', 'Verma', 'Dr Rao']);
  console.log(`✓ relay saw ${sends} encrypted messages; no names or readable guest data`);
  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  await dataAttribute(pro, 'call-phase', 'ended');
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
