// "Remember me on this browser" in a real browser (IndexedDB, Web Crypto):
//
//  1. Without it, the page warns before leaving and the home screen says
//     the links work only while the tab is open.
//  2. "Remember me" (from that card): the warning goes away; reloading
//     keeps the same guest link and contact link.
//  3. What the browser stores holds no readable names, and its key can't be
//     extracted.
//  4. Remembering at onboarding works the same way (even if an empty
//     database was left behind).
//  5. "Forget this browser": the storage is deleted; after reloading, the
//     page starts with a new identity.
import assert from 'node:assert/strict';
import {
  dumpPages,
  assertNoThirdPartyRequests,
  base,
  clickButton,
  dataAttribute,
  enableSemantics,
  launch,
  newContext,
  openPage,
  openTab,
  readAttribute,
  titleIncludes,
  toggleSwitch,
  typeInto,
} from './lib.mjs';

const browser = await launch();

async function startOnboarding(page, name) {
  await titleIncludes(page, 'Welcome');
  await clickButton(page, 'Start');
  await typeInto(page, 'Your name', name);
}

/** Scrolls a long Flutter list (built lazily) until a switch shows up. */
async function scrollUntil(page, name) {
  await enableSemantics(page);
  const target = page.getByRole('switch', { name }).or(page.getByRole('checkbox', { name }));
  for (let i = 0; i < 30 && (await target.count()) === 0; i++) {
    await page.mouse.move(640, 360);
    await page.mouse.wheel(0, 600);
    await page.waitForTimeout(250);
  }
}

/** Reloads, accepting the "leave this page?" question if the browser asks. */
async function reload(page) {
  await page.evaluate(() => document.documentElement.removeAttribute('data-sotto-guest-link'));
  await page.reload();
}

/** Every value Sotto stored in IndexedDB, described for checking. */
const storedRecords = (page) =>
  page.evaluate(
    async () => {
      // Opening a deleted database would create it again: look first.
      const names = (await indexedDB.databases()).map((d) => d.name);
      if (!names.includes('sotto')) return [];
      return new Promise((resolve, reject) => {
        const open = indexedDB.open('sotto');
        open.onerror = () => reject(open.error);
        open.onsuccess = () => {
          const db = open.result;
          if (!db.objectStoreNames.contains('kv')) {
            db.close();
            resolve([]);
            return;
          }
          const store = db.transaction('kv').objectStore('kv');
          const keys = store.getAllKeys();
          const values = store.getAll();
          values.onsuccess = () => {
            resolve(
              values.result.map((value, i) => ({
                key: String(keys.result[i]),
                kind: value?.constructor?.name,
                extractable: value?.extractable,
                text: value instanceof Uint8Array ? new TextDecoder('latin1').decode(value) : '',
              })),
            );
            db.close();
          };
        };
      });
    },
  );

try {
  // 1–3. A session that keeps nothing, then "Remember me" from the card.
  const context = await newContext(browser);
  const page = await openPage(context, 'professional', base);
  page.on('dialog', (dialog) => dialog.accept());
  await startOnboarding(page, 'Dr Meera Rao');
  await clickButton(page, 'Continue');
  await titleIncludes(page, 'Ready');
  await dataAttribute(page, 'leave-warning', 'true');
  await enableSemantics(page);
  await page
    .locator('[aria-label*="These links work only while this tab is open"]')
    .first()
    .waitFor({ state: 'attached' });
  console.log('✓ a session that keeps nothing warns before leaving and says links are temporary');

  await clickButton(page, 'Remember me');
  await dataAttribute(page, 'leave-warning', 'false');
  const guestLink = await readAttribute(page, 'guest-link');
  await reload(page);
  await titleIncludes(page, 'Ready');
  assert.equal(await readAttribute(page, 'guest-link'), guestLink, 'same guest link after reloading');
  console.log('✓ "Remember me": no warning, and the same guest link after reloading');

  const records = await storedRecords(page);
  const wrapping = records.find((r) => r.key === 'wrapping-key');
  assert.equal(wrapping?.kind, 'CryptoKey');
  assert.equal(wrapping?.extractable, false, 'the wrapping key cannot be exported');
  assert.ok(records.some((r) => r.key === 'vault'), 'the vault is stored');
  assert.ok(records.some((r) => r.key.startsWith('secret:')), 'secrets are stored');
  for (const record of records) {
    assert.ok(!record.text.includes('Meera'), `${record.key} must not hold a readable name`);
  }
  console.log(`✓ ${records.length} stored records: encrypted, and the key is not extractable`);

  // 5. Forget this browser.
  await openTab(page, 'Settings');
  await scrollUntil(page, 'Remember me on this browser');
  await toggleSwitch(page, 'Remember me on this browser');
  await clickButton(page, 'Forget');
  await dataAttribute(page, 'leave-warning', 'true');
  assert.equal(await readAttribute(page, 'guest-link'), guestLink, 'this tab keeps working');
  assert.equal((await storedRecords(page)).length, 0, 'nothing left in the browser');
  await reload(page);
  await titleIncludes(page, 'Welcome');
  console.log('✓ "Forget this browser" deleted everything; reloading starts a new identity');

  // 4. Remember at onboarding (a fresh browser profile).
  const fresh = await newContext(browser);
  // Something left an empty "sotto" database (no table) before the app ever
  // ran here (the self-test page doesn't start the app): that must not
  // break it.
  const before = await openPage(fresh, 'self-test', new URL('?selftest=1', base).toString());
  await titleIncludes(before, 'Self-test passed');
  await before.evaluate(
    () =>
      new Promise((resolve) => {
        const open = indexedDB.open('sotto');
        open.onsuccess = () => {
          open.result.close();
          resolve();
        };
      }),
  );
  assert.equal((await storedRecords(before)).length, 0);
  await before.close();
  const second = await openPage(fresh, 'colleague', base);
  second.on('dialog', (dialog) => dialog.accept());
  await startOnboarding(second, 'Arun Mehta');
  await toggleSwitch(second, 'Remember me on this browser');
  await clickButton(second, 'Continue');
  await titleIncludes(second, 'Ready');
  await dataAttribute(second, 'leave-warning', 'false');
  await openTab(second, 'Contacts');
  await clickButton(second, 'Share my contact');
  const contactLink = await readAttribute(second, 'contact-link');
  await second.evaluate(() => document.documentElement.removeAttribute('data-sotto-contact-link'));
  await second.reload();
  await titleIncludes(second, 'Ready');
  await openTab(second, 'Contacts');
  await clickButton(second, 'Share my contact');
  assert.equal(await readAttribute(second, 'contact-link'), contactLink, 'same contact link');
  console.log('✓ remembered at onboarding: the same contact link after reloading');

  const hosts = assertNoThirdPartyRequests(assert, [new URL(base).host, 'localhost:8080']);
  console.log(`✓ pages only contacted their own servers (${hosts.join(', ')})`);
  console.log('PASS');
} catch (error) {
  await dumpPages();
  throw error;
} finally {
  await browser.close();
}
