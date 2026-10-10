// Shared helpers for the browser end-to-end tests.
import assert from 'node:assert/strict';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { writeFakeCamera } from './fake-camera.mjs';

export const base = process.env.SOTTO_WEB_URL ?? 'http://localhost:8099/';
export const timeout = 60_000;

export async function launch() {
  const camera = join(tmpdir(), 'sotto-fake-camera.y4m');
  writeFakeCamera(camera);
  return chromium.launch({
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-video-capture=${camera}`,
    ],
  });
}

export async function newContext(browser) {
  // Flutter web needs a locale; headless Chromium may not report one.
  return browser.newContext({ locale: 'en-US', permissions: ['camera', 'microphone'] });
}

/** Everything the browsers send to the relay. */
export const framesToRelay = [];

/** Every host any page contacted (HTTP and WebSocket). */
export const contactedHosts = new Set();

/** Open pages and their console output, printed if a test fails. */
const pages = [];

export async function openPage(context, name, url) {
  const page = await context.newPage();
  const log = [];
  pages.push({ name, page, log });
  // Poll on a timer, not on animation frames: background tabs on a busy
  // machine get few or no frames, so frame-based polling can miss changes
  // for a long time (this made CI time out while the page was correct).
  const waitForFunction = page.waitForFunction.bind(page);
  page.waitForFunction = (fn, arg, options = {}) =>
    waitForFunction(fn, arg, { timeout, polling: 250, ...options });
  page.on('console', (m) => log.push(`${m.type()}: ${m.text()}`.slice(0, 300)));
  page.on('pageerror', (error) => console.error(`${name} page error: ${error.message}`));
  page.on('request', (request) => {
    const url = new URL(request.url());
    if (/^(https?|wss?):$/.test(url.protocol)) contactedHosts.add(url.host);
  });
  page.on('websocket', (ws) =>
    ws.on('framesent', ({ payload }) => framesToRelay.push(String(payload))),
  );
  // The tests wait for the app's own state (page title), so don't also wait
  // for every resource's "load" event, which is slow on busy CI runners.
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout });
  return page;
}

export const titleIncludes = (page, text) =>
  page.waitForFunction((t) => document.title.includes(t), text, { timeout, polling: 250 });

export async function enableSemantics(page) {
  if ((await page.locator('flt-semantics-placeholder').count()) > 0) {
    await page.locator('flt-semantics-placeholder').dispatchEvent('click');
  }
}

/** Clicks a Flutter button by its label, via Flutter's accessibility tree. */
export async function clickButton(page, name) {
  await enableSemantics(page);
  const button = page.getByRole('button', { name, exact: typeof name === 'string' }).first();
  await button.waitFor({ timeout, polling: 250 });
  // A disabled button ignores clicks (e.g. "Join" until the camera preview
  // is ready): wait until it is enabled, since a dispatched click doesn't.
  for (const end = Date.now() + timeout; !(await button.isEnabled()); ) {
    if (Date.now() > end) throw new Error(`button "${name}" stayed disabled`);
    await page.waitForTimeout(250);
  }
  if (page.context().browser()?.browserType().name() === 'firefox') {
    // Firefox: the accessibility tree is rebuilt while a call's timer ticks,
    // and a real click can straddle the rebuild and get lost. One click
    // event on the button itself is reliable.
    await button.dispatchEvent('click');
    return;
  }
  try {
    await button.click({ timeout: 5000 });
  } catch {
    // Another accessibility node can overlap the button after a layout
    // change; deliver the click to the button itself.
    await button.dispatchEvent('click');
  }
}

/** Scrolls a long Flutter page (built lazily, so only what is on screen is
 * in the accessibility tree) until `locator` is there. */
export async function scrollUntilFound(page, locator, step = 400) {
  await enableSemantics(page);
  for (let i = 0; i < 40 && (await locator.count()) === 0; i++) {
    await page.mouse.move(640, 360);
    await page.mouse.wheel(0, step);
    await page.waitForTimeout(250);
  }
  await locator.first().waitFor();
}

/** Flips a Flutter switch whose label matches `name`. */
export async function toggleSwitch(page, name) {
  await enableSemantics(page);
  const toggle = page.getByRole('switch', { name }).or(page.getByRole('checkbox', { name }));
  await toggle.first().waitFor({ timeout, polling: 250 });
  await toggle.first().click();
}

/** Types into a Flutter text field found by its label. */
export async function typeInto(page, label, text) {
  await enableSemantics(page);
  const field = page.getByRole('textbox', { name: label });
  await field.first().waitFor({ timeout, polling: 250 });
  await page.evaluate(() => {
    window.__sottoPreviousFocus = document.activeElement;
  });
  await field.first().click();
  // Flutter moves focus to a new <input> after the click; typing before
  // that loses keystrokes (or sends them to the previous field).
  await page
    .waitForFunction(
      () =>
        ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName) &&
        document.activeElement !== window.__sottoPreviousFocus,
      null,
      { timeout: 2000 },
    )
    .catch(() => {}); // the field already had focus
  await page.waitForTimeout(100);
  await page.keyboard.type(text, { delay: 20 });
  await page.waitForFunction(
    (t) => document.activeElement?.value?.endsWith(t),
    text,
    { timeout: 5000 },
  );
}

/** Switches the professional's app to a tab (Home, Contacts, History, Settings). */
export async function openTab(page, name) {
  await enableSemantics(page);
  // Navigation destinations are announced as "Settings, Tab 4 of 4".
  const tab = page.getByRole('button', { name: new RegExp(`^${name}\\s+Tab \\d of \\d`) });
  await tab.first().waitFor({ timeout, polling: 250 });
  await tab.first().click();
}

/** Sets the app lock PIN in the "Set a PIN" dialog. */
export async function setPin(page, pin) {
  await typeInto(page, /New PIN/, pin);
  await typeInto(page, 'Repeat the PIN', pin);
  await clickButton(page, 'Save PIN');
}

/** Confirms a sensitive change with the PIN. */
export async function enterPin(page, pin, button = 'Confirm') {
  await typeInto(page, 'PIN', pin);
  await clickButton(page, button);
}

/** First start of the professional's app in a browser: name (and practice). */
export async function onboard(page, name, { practice } = {}) {
  await titleIncludes(page, 'Welcome');
  await clickButton(page, 'Start');
  await typeInto(page, 'Your name', name);
  if (practice) await typeInto(page, /Practice or organisation/, practice);
  await clickButton(page, 'Continue');
}

/** Opens the professional's app and goes through onboarding. */
export async function openApp(context, label, name, options) {
  const page = await openPage(context, label, base);
  await onboard(page, name, options);
  await titleIncludes(page, 'Ready');
  return page;
}

/** Shares this person's contact link (from the Contacts tab). */
export async function shareContactLink(page) {
  await openTab(page, 'Contacts');
  await clickButton(page, 'Share my contact');
  await enableSemantics(page);
  await page
    .getByText('QR code of your contact link')
    .or(page.locator('[aria-label="QR code of your contact link"]'))
    .first()
    .waitFor();
  const link = await readAttribute(page, 'contact-link');
  assert.ok(link.includes('/#c='), 'contact link keeps details in the fragment');
  await clickButton(page, 'Done');
  return link;
}

/** Adds a contact from someone's contact link. */
export async function addContact(page, link, name) {
  await openTab(page, 'Contacts');
  await clickButton(page, 'Add contact');
  await typeInto(page, 'Contact link', link);
  await clickButton(page, 'Next');
  await clickButton(page, 'Save contact');
  await page.getByRole('button', { name: new RegExp(`^${name}`) }).first().waitFor();
}

const composer = (page) => page.getByRole('textbox', { name: 'Write a message' });

/**
 * Opens the chat with a contact from any tab. A chat that is already open is
 * left first, since the tab bar is hidden under it; then the contact's Message
 * button on the Contacts tab opens the chat.
 */
export async function openChat(page, name) {
  if ((await composer(page).count()) > 0) {
    await clickButton(page, 'Back');
    await composer(page).first().waitFor({ state: 'detached', timeout });
  }
  await openTab(page, 'Contacts');
  await clickButton(page, new RegExp(`^Message: ${name}`));
  await composer(page).first().waitFor();
}

/** Escapes text for use inside a RegExp. */
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * The bubble that shows `text`. An optional `status` (a regex fragment, such as
 * "Not sent" or "(Delivered|Read)") must be in the same bubble. Flutter exposes
 * a bubble's words either as text (a Delivered or incoming bubble) or as the
 * accessible name of its group (a Not sent bubble, whose Retry button is its
 * only text), so both are matched. The group's label names the status before
 * the text ("You, 4:21 PM, Not sent: ...: Are you there?") and the visible
 * text shows it after, so both orders are matched.
 */
export function bubble(page, text, status = '') {
  const body = escapeRegExp(text);
  const pattern = status
    ? new RegExp(`${body}[\\s\\S]*${status}|${status}[\\s\\S]*${body}`)
    : new RegExp(body);
  return page.getByText(pattern).or(page.getByRole('group', { name: pattern }));
}

/**
 * Opens the menu of the bubble that shows `text`, as a user does on this
 * project: a long press on a touch device, a right click on a desktop one.
 * A touch project sets `hasTouch` on its context.
 */
export async function longPressBubble(page, text) {
  const target = bubble(page, text).first();
  await target.waitFor({ timeout });
  const box = await target.boundingBox();
  if (!box) throw new Error(`the bubble "${text}" has no position on the page`);
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  if (await page.evaluate(() => navigator.maxTouchPoints > 0)) {
    // Flutter starts a long press after 500 ms; hold a little longer.
    await page.mouse.down();
    await page.waitForTimeout(700);
    await page.mouse.up();
  } else {
    await page.mouse.click(x, y, { button: 'right' });
  }
}

/**
 * Runs `action`, a click that starts a download, and returns the Playwright
 * Download. `download.path()` gives the saved file, kept until the browser closes.
 */
export async function captureDownload(page, action) {
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout }),
    action(),
  ]);
  return download;
}

export const dataAttribute = (page, name, value) =>
  page.waitForFunction(
    ([n, v]) => document.documentElement.getAttribute(`data-sotto-${n}`) === v,
    [name, value],
    { timeout, polling: 250 },
  );

/** Waits until the app has published a value (a dialog may still be opening). */
export const readAttribute = async (page, name) => {
  const value = await page.waitForFunction(
    (n) => document.documentElement.getAttribute(`data-sotto-${n}`),
    name,
    { timeout, polling: 250 },
  );
  return value.jsonValue();
};

export const videoPlaying = (page) =>
  page.waitForFunction(
    () => {
      // Only videos showing a stream (a stopped camera preview has none).
      const videos = [...document.querySelectorAll('video')].filter((v) => v.srcObject);
      return videos.length >= 2 && videos.every((v) => v.videoWidth > 0 && !v.paused);
    },
    null,
    { timeout, polling: 250 },
  );

/** Every frame sent to the relay must be a login, ICE request or opaque envelope. */
export function assertRelaySawOnlyCiphertext(assert, extraLeaks = []) {
  const sends = framesToRelay.filter((f) => f.includes('"type":"send"'));
  for (const frame of framesToRelay) {
    const message = JSON.parse(frame);
    assert.ok(
      ['auth', 'send', 'ice', 'ping'].includes(message.type),
      `unexpected frame type ${message.type}`,
    );
    for (const leak of ['v=0', 'a=fingerprint', 'candidate:', 'sdp.', 'call.', 'guest.', 'video', ...extraLeaks]) {
      assert.ok(!frame.includes(leak), `relay saw readable data (${leak})`);
    }
  }
  return sends.length;
}

/** The app must only talk to its own web server and relay: no fonts, scripts
 * or anything else from third parties (they would see visitors' IPs). */
export function assertNoThirdPartyRequests(assert, allowed) {
  for (const host of contactedHosts) {
    assert.ok(allowed.includes(host), `page contacted a third party: ${host}`);
  }
  return [...contactedHosts];
}

/** Prints every page's title and recent console output (for CI failures). */
export async function dumpPages() {
  for (const { name, page, log } of pages) {
    try {
      if (!page.isClosed() && process.env.SOTTO_SCREENSHOTS) {
        await page.screenshot({ path: `${process.env.SOTTO_SCREENSHOTS}/${name}.png` });
      }
    } catch {
      // ignore
    }
    let title = '(closed)';
    try {
      if (!page.isClosed()) title = await page.title();
    } catch {
      // ignore
    }
    let attrs = '';
    try {
      if (!page.isClosed()) {
        attrs = await page.evaluate(() =>
          [...document.documentElement.attributes]
            .filter((a) => a.name.startsWith('data-sotto-') && !a.name.endsWith('-link'))
            .map((a) => `${a.name.slice(11)}=${a.value}`)
            .join(' '),
        );
      }
    } catch {
      // ignore
    }
    console.error(`--- ${name}: "${title}" ${attrs}`);
    for (const line of log.slice(-15)) console.error(`    ${line}`);
  }
}
