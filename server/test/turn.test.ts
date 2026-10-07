import { createHmac } from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import { iceServersFor, turnCredentials, type IceConfig } from '../src/relay/turn.js';
import type { RelayServer } from '../src/server.js';
import { newIdentity, startServer, TestClient } from './helpers.js';

const config: IceConfig = {
  stunUrls: ['stun:turn.example:3478'],
  turnUrls: ['turn:turn.example:3478?transport=udp', 'turns:turn.example:5349?transport=tcp'],
  turnSecret: 'test-secret',
  turnTtlSec: 3600,
};

describe('turnCredentials', () => {
  it('produces credentials coturn accepts: HMAC-SHA1 of "<expiry>:<random>"', () => {
    const now = Date.UTC(2026, 9, 7);
    const { username, credential, expiresAt } = turnCredentials('test-secret', 3600, now);
    const [expiry, random] = username.split(':');
    expect(Number(expiry)).toBe(now / 1000 + 3600);
    expect(expiresAt).toBe(now / 1000 + 3600);
    expect(random).toMatch(/^[A-Za-z0-9_-]{12}$/);
    expect(credential).toBe(createHmac('sha1', 'test-secret').update(username).digest('base64'));
  });

  it('never reuses usernames and contains no user identifier', () => {
    const usernames = new Set(Array.from({ length: 50 }, () => turnCredentials('s', 60).username));
    expect(usernames.size).toBe(50);
  });
});

describe('iceServersFor', () => {
  it('returns STUN plus TURN with fresh credentials', () => {
    const servers = iceServersFor(config);
    expect(servers[0]).toEqual({ urls: config.stunUrls });
    expect(servers[1]?.urls).toEqual(config.turnUrls);
    expect(servers[1]?.username).toBeDefined();
    expect(servers[1]?.credential).toBeDefined();
  });

  it('omits TURN without a secret, and returns nothing when unconfigured', () => {
    expect(iceServersFor({ ...config, turnSecret: '' })).toEqual([{ urls: config.stunUrls }]);
    expect(iceServersFor({ stunUrls: [], turnUrls: [], turnSecret: '', turnTtlSec: 1 })).toEqual(
      [],
    );
  });
});

describe('relay hands out ICE servers', () => {
  let server: RelayServer | undefined;
  const clients: TestClient[] = [];

  afterEach(async () => {
    await Promise.all(clients.splice(0).map((c) => c.close()));
    await server?.close();
  });

  it('only to logged-in clients: in "ready" and on request', async () => {
    const started = await startServer({ config: { ice: config } });
    server = started.server;

    const anonymous = await TestClient.connect(started.url);
    clients.push(anonymous);
    await anonymous.next();
    anonymous.send({ type: 'ice' });
    expect(await anonymous.next()).toEqual({ type: 'error', code: 'not-authenticated' });

    const identity = newIdentity();
    const client = await TestClient.login(started.url, identity);
    clients.push(client);
    const ready = await client.next();
    expect(ready.type).toBe('ready');
    const ice = ready.ice as { urls: string[]; username?: string }[];
    expect(ice).toHaveLength(2);
    expect(ice[1]?.username).not.toContain(identity.id);

    client.send({ type: 'ice' });
    const refreshed = (await client.next()) as { type: string; ice: { username?: string }[] };
    expect(refreshed.type).toBe('ice');
    expect(refreshed.ice[1]?.username).not.toBe(ice[1]?.username);
  });
});
