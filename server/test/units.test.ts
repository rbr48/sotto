import { describe, expect, it } from 'vitest';
import { isValidId } from '../src/relay/ids.js';
import { TokenBucket } from '../src/relay/limits.js';
import { MessageQueue } from '../src/relay/queue.js';
import { loadConfig } from '../src/config.js';
import { createRelayServer } from '../src/server.js';
import { newIdentity } from './helpers.js';

describe('isValidId', () => {
  it('accepts canonical 32-byte base64url keys only', () => {
    const id = newIdentity().id;
    expect(isValidId(id)).toBe(true);
    expect(isValidId(`${id}=`)).toBe(false);
    expect(isValidId(id.slice(1))).toBe(false);
    expect(isValidId(id.replace(/^./, '+'))).toBe(false);
    // Same bytes, but non-zero unused trailing bits: not canonical.
    const last = id.at(-1)!;
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    const sibling = alphabet[(alphabet.indexOf(last) & ~3) + 1]!;
    expect(isValidId(id.slice(0, 42) + sibling)).toBe(false);
    expect(isValidId(42)).toBe(false);
  });
});

describe('MessageQueue', () => {
  const limits = { ttlMs: 10, maxPerRecipient: 5, maxTotalBytes: 6, maxBytesPerSource: 100 };

  it('expires messages and keeps byte accounting consistent', () => {
    let now = 0;
    const queue = new MessageQueue(limits, () => now);
    expect(queue.push('bob', 'alice', 'abc', 's')).toBe(true);
    expect(queue.push('bob', 'alice', 'def', 's')).toBe(true);
    expect(queue.push('carol', 'alice', 'g', 's')).toBe(false); // over total bytes
    now = 11;
    queue.prune();
    expect(queue.size).toBe(0);
    expect(queue.push('carol', 'alice', 'abcdef', 's')).toBe(true); // bytes were released
    expect(queue.undelivered('carol', 1).map((m) => m.body)).toEqual(['abcdef']);
    expect(queue.undelivered('carol', 1)).toEqual([]);
  });

  it('gives each connection each envelope once', () => {
    const queue = new MessageQueue(limits, () => 0);
    queue.push('bob', 'alice', 'one', 's');
    expect(queue.undelivered('bob', 1).map((m) => m.body)).toEqual(['one']);
    expect(queue.undelivered('bob', 2).map((m) => m.body)).toEqual(['one']);
    queue.push('bob', 'alice', 'two', 's');
    expect(queue.undelivered('bob', 1).map((m) => m.body)).toEqual(['two']);
    expect(queue.size).toBe(2); // held until they expire, not on delivery
  });

  it('caps what one source may hold, and releases its share on expiry', () => {
    let now = 0;
    const queue = new MessageQueue(
      { ttlMs: 10, maxPerRecipient: 50, maxTotalBytes: 1000, maxBytesPerSource: 5 },
      () => now,
    );
    expect(queue.push('bob', 'alice', 'abc', 'addr')).toBe(true);
    expect(queue.push('bob', 'alice', 'defg', 'addr')).toBe(false); // 3 + 4 > 5
    expect(queue.push('bob', 'alice', 'de', 'other')).toBe(true); // another source is fine
    now = 11;
    expect(queue.push('bob', 'alice', 'fghij', 'addr')).toBe(true); // share released
  });

  it('expires in order, and never lets a clock that steps back extend a message', () => {
    let now = 0;
    const queue = new MessageQueue({ ...limits, maxTotalBytes: 100 }, () => now);
    expect(queue.push('bob', 'alice', 'early', 's')).toBe(true);
    now = 5;
    expect(queue.push('bob', 'alice', 'late', 's')).toBe(true);
    now = -100; // the device clock was set back
    expect(queue.undelivered('bob', 1).map((m) => m.body)).toEqual(['early', 'late']);
    now = 10; // 'early' was queued at 0 and expires at 10, whatever the clock said since
    expect(queue.undelivered('bob', 2).map((m) => m.body)).toEqual(['late']);
    now = 15;
    expect(queue.undelivered('bob', 3)).toEqual([]);
    expect(queue.size).toBe(0);
  });

  it('keeps working through many expirations (no full scan per push)', () => {
    let now = 0;
    const queue = new MessageQueue(
      { ttlMs: 5, maxPerRecipient: 50, maxTotalBytes: 1e9, maxBytesPerSource: 1e9 },
      () => now,
    );
    for (let tick = 0; tick < 20_000; tick++) {
      now = tick;
      expect(queue.push(`r${tick % 100}`, 'alice', 'x', 's')).toBe(true);
    }
    // Only the last five ticks' envelopes are still alive.
    expect(queue.size).toBe(5);
  });
});

describe('TokenBucket', () => {
  it('allows bursts and refills over time', () => {
    let now = 0;
    const bucket = new TokenBucket(2, 2, () => now);
    expect([bucket.take(), bucket.take(), bucket.take()]).toEqual([true, true, false]);
    now = 500;
    expect([bucket.take(), bucket.take()]).toEqual([true, false]);
  });
});

describe('loadConfig', () => {
  it('allows port 0 (any free port) but rejects other invalid numbers', async () => {
    const { loadConfig } = await import('../src/config.js');
    expect(loadConfig({ PORT: '0' }).port).toBe(0);
    expect(() => loadConfig({ PORT: '-1' })).toThrow();
    expect(() => loadConfig({ SOTTO_HEARTBEAT_MS: '0' })).toThrow();
  });
});

describe('relay name', () => {
  it('is read from SOTTO_DOMAIN, trimmed and lower-cased', () => {
    expect(loadConfig({ SOTTO_DOMAIN: ' Call.Example.COM ' }).publicHost).toBe('call.example.com');
  });

  it('is required: the relay refuses to start without one', () => {
    expect(() => createRelayServer({ ...loadConfig({}), port: 0 })).toThrow(
      'SOTTO_DOMAIN must be set',
    );
  });
});

describe('loadConfig ICE settings', () => {
  it('parses comma-separated URL lists and the TURN secret', async () => {
    const { loadConfig } = await import('../src/config.js');
    const config = loadConfig({
      SOTTO_STUN_URLS: 'stun:a:3478',
      SOTTO_TURN_URLS: ' turn:a:3478?transport=udp , turns:a:5349?transport=tcp ,',
      SOTTO_TURN_SECRET: 'x',
    });
    expect(config.ice).toEqual({
      stunUrls: ['stun:a:3478'],
      turnUrls: ['turn:a:3478?transport=udp', 'turns:a:5349?transport=tcp'],
      turnSecret: 'x',
      turnTtlSec: 21600,
    });
    expect(loadConfig({}).ice.turnUrls).toEqual([]);
  });
});
