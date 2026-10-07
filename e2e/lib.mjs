// Shared helpers for the browser end-to-end tests.
import { chromium } from 'playwright';

export const base = process.env.SOTTO_WEB_URL ?? 'http://localhost:8099/';
export const timeout = 60_000;

export async function launch() {
  return chromium.launch({
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
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

export async function openPage(context, name, url) {
  const page = await context.newPage();
  page.on('pageerror', (error) => console.error(`${name} page error: ${error.message}`));
  page.on('request', (request) => {
    const url = new URL(request.url());
    if (/^(https?|wss?):$/.test(url.protocol)) contactedHosts.add(url.host);
  });
  page.on('websocket', (ws) =>
    ws.on('framesent', ({ payload }) => framesToRelay.push(String(payload))),
  );
  await page.goto(url);
  return page;
}

export const titleIncludes = (page, text) =>
  page.waitForFunction((t) => document.title.includes(t), text, { timeout });

export async function enableSemantics(page) {
  if ((await page.locator('flt-semantics-placeholder').count()) > 0) {
    await page.locator('flt-semantics-placeholder').dispatchEvent('click');
  }
}

/** Clicks a Flutter button by its label, via Flutter's accessibility tree. */
export async function clickButton(page, name) {
  await enableSemantics(page);
  const button = page.getByRole('button', { name, exact: typeof name === 'string' }).first();
  await button.waitFor({ timeout });
  try {
    await button.click({ timeout: 5000 });
  } catch {
    // Another accessibility node can overlap the button after a layout
    // change; deliver the click to the button itself.
    await button.dispatchEvent('click');
  }
}

/** Flips a Flutter switch whose label matches `name`. */
export async function toggleSwitch(page, name) {
  await enableSemantics(page);
  const toggle = page.getByRole('switch', { name }).or(page.getByRole('checkbox', { name }));
  await toggle.first().waitFor({ timeout });
  await toggle.first().click();
}

/** Types into a Flutter text field found by its label. */
export async function typeInto(page, label, text) {
  await enableSemantics(page);
  const field = page.getByRole('textbox', { name: label });
  await field.first().waitFor({ timeout });
  await field.first().click();
  await page.keyboard.type(text);
}

export const dataAttribute = (page, name, value) =>
  page.waitForFunction(
    ([n, v]) => document.documentElement.getAttribute(`data-sotto-${n}`) === v,
    [name, value],
    { timeout },
  );

export const readAttribute = (page, name) =>
  page.evaluate((n) => document.documentElement.getAttribute(`data-sotto-${n}`), name);

export const videoPlaying = (page) =>
  page.waitForFunction(
    () => {
      // Only videos showing a stream (a stopped camera preview has none).
      const videos = [...document.querySelectorAll('video')].filter((v) => v.srcObject);
      return videos.length >= 2 && videos.every((v) => v.videoWidth > 0 && !v.paused);
    },
    null,
    { timeout },
  );

/** Every frame sent to the relay must be a login, ICE request or opaque envelope. */
export function assertRelaySawOnlyCiphertext(assert, extraLeaks = []) {
  const sends = framesToRelay.filter((f) => f.includes('"type":"send"'));
  for (const frame of framesToRelay) {
    const message = JSON.parse(frame);
    assert.ok(
      ['auth', 'send', 'ice'].includes(message.type),
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
