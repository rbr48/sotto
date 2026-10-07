import { describe, expect, it } from 'vitest';
import { isValidId } from '../src/relay/ids.js';
import { TokenBucket } from '../src/relay/limits.js';
import { MessageQueue } from '../src/relay/queue.js';
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
  it('expires messages and keeps byte accounting consistent', () => {
    let now = 0;
    const queue = new MessageQueue({ ttlMs: 10, maxPerRecipient: 5, maxTotalBytes: 6 }, () => now);
    expect(queue.push('bob', 'alice', 'abc')).toBe(true);
    expect(queue.push('bob', 'alice', 'def')).toBe(true);
    expect(queue.push('carol', 'alice', 'g')).toBe(false); // over total bytes
    now = 11;
    queue.prune();
    expect(queue.size).toBe(0);
    expect(queue.push('carol', 'alice', 'abcdef')).toBe(true); // bytes were released
    expect(queue.take('carol').map((m) => m.body)).toEqual(['abcdef']);
    expect(queue.take('carol')).toEqual([]);
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
