import { afterEach, describe, expect, it } from 'vitest';
import { CloseCode, type RelayLimits } from '../src/relay/relay.js';
import type { Config } from '../src/config.js';
import type { RelayServer } from '../src/server.js';
import { newIdentity, startServer, TestClient } from './helpers.js';

describe('relay', () => {
  let server: RelayServer | undefined;
  const clients: TestClient[] = [];

  async function start(options: { config?: Partial<Config>; limits?: Partial<RelayLimits> } = {}) {
    const started = await startServer(options);
    server = started.server;
    return started.url;
  }

  async function login(url: string, identity = newIdentity()) {
    const client = await TestClient.login(url, identity);
    clients.push(client);
    expect(await client.next()).toEqual({ type: 'ready', id: identity.id });
    return { client, identity };
  }

  afterEach(async () => {
    await Promise.all(clients.splice(0).map((c) => c.close()));
    await server?.close();
    server = undefined;
  });

  describe('login', () => {
    it('accepts a valid signature over the challenge', async () => {
      const url = await start();
      const { client, identity } = await login(url);
      expect(server!.relay.onlineCount).toBe(1);
      expect(identity.id).toHaveLength(43);
      await client.close();
    });

    it('sends a fresh 32-byte challenge on every connection', async () => {
      const url = await start();
      const a = await TestClient.connect(url);
      const b = await TestClient.connect(url);
      clients.push(a, b);
      const [ca, cb] = [await a.next(), await b.next()];
      expect(ca.type).toBe('challenge');
      expect(Buffer.from(ca.nonce as string, 'base64url')).toHaveLength(32);
      expect(ca.nonce).not.toEqual(cb.nonce);
    });

    it('rejects a signature made with another key', async () => {
      const url = await start();
      const victim = newIdentity();
      const attacker = newIdentity();
      const client = await TestClient.login(url, {
        id: victim.id,
        privateKey: attacker.privateKey,
      });
      clients.push(client);
      expect(await client.next()).toEqual({ type: 'error', code: 'auth-failed' });
      expect(await client.closed).toBe(CloseCode.authFailed);
      expect(server!.relay.onlineCount).toBe(0);
    });

    it('rejects a signature made for a different server (relayed challenge)', async () => {
      const url = await start();
      const client = await TestClient.login(url, newIdentity(), 'evil.example.com');
      clients.push(client);
      expect(await client.next()).toEqual({ type: 'error', code: 'auth-failed' });
      expect(await client.closed).toBe(CloseCode.authFailed);
    });

    it('rejects malformed IDs and signatures', async () => {
      const url = await start();
      for (const auth of [
        { type: 'auth', id: 'short', sig: 'AA' },
        { type: 'auth', id: newIdentity().id, sig: 5 },
        { type: 'auth' },
      ]) {
        const client = await TestClient.connect(url);
        clients.push(client);
        await client.next();
        client.send(auth);
        expect(await client.next()).toEqual({ type: 'error', code: 'auth-failed' });
      }
    });

    it('ignores everything but auth before login', async () => {
      const url = await start();
      const client = await TestClient.connect(url);
      clients.push(client);
      await client.next();
      client.send({ type: 'send', to: newIdentity().id, body: 'x' });
      expect(await client.next()).toEqual({ type: 'error', code: 'not-authenticated' });
    });

    it('disconnects clients that never log in', async () => {
      const url = await start({ limits: { authTimeoutMs: 100 } });
      const client = await TestClient.connect(url);
      clients.push(client);
      await client.next();
      expect(await client.next()).toEqual({ type: 'error', code: 'auth-timeout' });
      expect(await client.closed).toBe(CloseCode.authTimeout);
    });
  });

  describe('routing', () => {
    it('delivers to the recipient with the authenticated sender attached', async () => {
      const url = await start();
      const alice = await login(url);
      const bob = await login(url);
      alice.client.send({ type: 'send', to: bob.identity.id, body: 'sealed-envelope', ref: 'r1' });
      expect(await bob.client.next()).toEqual({
        type: 'message',
        from: alice.identity.id,
        body: 'sealed-envelope',
      });
      expect(await alice.client.next()).toEqual({ type: 'ack', ref: 'r1', status: 'delivered' });
    });

    it('ignores any "from" the client tries to set', async () => {
      const url = await start();
      const alice = await login(url);
      const bob = await login(url);
      const carol = newIdentity();
      alice.client.send({ type: 'send', to: bob.identity.id, body: 'x', from: carol.id });
      expect((await bob.client.next()).from).toBe(alice.identity.id);
    });

    it('fans out to every device of the recipient', async () => {
      const url = await start();
      const alice = await login(url);
      const bob = newIdentity();
      const phone = await login(url, bob);
      const desktop = await login(url, bob);
      alice.client.send({ type: 'send', to: bob.id, body: 'ring' });
      expect((await phone.client.next()).body).toBe('ring');
      expect((await desktop.client.next()).body).toBe('ring');
    });

    it('stops routing to a device after it disconnects', async () => {
      const url = await start();
      const alice = await login(url);
      const bob = await login(url);
      await bob.client.close();
      await new Promise((r) => setTimeout(r, 50));
      expect(server!.relay.onlineCount).toBe(1);
      alice.client.send({ type: 'send', to: bob.identity.id, body: 'x', ref: 'r' });
      expect(await alice.client.next()).toEqual({ type: 'ack', ref: 'r', status: 'queued' });
    });

    it('holds messages for an offline recipient and delivers them on login', async () => {
      const url = await start();
      const alice = await login(url);
      const bob = newIdentity();
      alice.client.send({ type: 'send', to: bob.id, body: 'first', ref: 'a' });
      alice.client.send({ type: 'send', to: bob.id, body: 'second', ref: 'b' });
      expect(await alice.client.next()).toEqual({ type: 'ack', ref: 'a', status: 'queued' });
      expect(await alice.client.next()).toEqual({ type: 'ack', ref: 'b', status: 'queued' });
      const bobClient = await login(url, bob);
      expect(await bobClient.client.next()).toEqual({
        type: 'message',
        from: alice.identity.id,
        body: 'first',
      });
      expect(await bobClient.client.next()).toEqual({
        type: 'message',
        from: alice.identity.id,
        body: 'second',
      });
      expect(server!.relay.queuedCount).toBe(0);
    });

    it('drops held messages after the time limit', async () => {
      const url = await start({
        limits: { queue: { ttlMs: 100, maxPerRecipient: 10, maxTotalBytes: 1e6 } },
      });
      const alice = await login(url);
      const bob = newIdentity();
      alice.client.send({ type: 'send', to: bob.id, body: 'too late' });
      await new Promise((r) => setTimeout(r, 200));
      const bobClient = await login(url, bob);
      expect(await bobClient.client.silentFor(200)).toBe(true);
    });

    it('drops messages when the recipient queue is full', async () => {
      const url = await start({
        limits: { queue: { ttlMs: 60_000, maxPerRecipient: 1, maxTotalBytes: 1e6 } },
      });
      const alice = await login(url);
      const bob = newIdentity();
      alice.client.send({ type: 'send', to: bob.id, body: '1', ref: 'a' });
      alice.client.send({ type: 'send', to: bob.id, body: '2', ref: 'b' });
      expect((await alice.client.next()).status).toBe('queued');
      expect((await alice.client.next()).status).toBe('dropped');
    });
  });

  describe('validation and limits', () => {
    it('rejects bad recipients, empty bodies, oversized bodies and unknown types', async () => {
      const url = await start({ limits: { maxBodyChars: 10 } });
      const { client } = await login(url);
      const to = newIdentity().id;
      const cases: [unknown, string][] = [
        [{ type: 'send', to: 'nope', body: 'x' }, 'bad-recipient'],
        [{ type: 'send', to: `${to.slice(0, 42)}B`, body: 'x' }, 'bad-recipient'],
        [{ type: 'send', to, body: '' }, 'bad-message'],
        [{ type: 'send', to, body: 'x'.repeat(11) }, 'too-large'],
        [{ type: 'whatever' }, 'bad-message'],
        [[1, 2], 'bad-message'],
      ];
      for (const [message, code] of cases) {
        client.send(message);
        expect(await client.next(), JSON.stringify(message)).toEqual({ type: 'error', code });
      }
      client.ws.send('{not json');
      expect(await client.next()).toEqual({ type: 'error', code: 'bad-message' });
    });

    it('rate-limits each connection', async () => {
      const url = await start({ limits: { messagesPerSec: 1, messageBurst: 3 } });
      // Login itself uses one token.
      const { client } = await login(url);
      const to = newIdentity().id;
      for (let i = 0; i < 2; i++) client.send({ type: 'send', to, body: 'x', ref: `${i}` });
      expect((await client.next()).type).toBe('ack');
      expect((await client.next()).type).toBe('ack');
      client.send({ type: 'send', to, body: 'x' });
      expect(await client.next()).toEqual({ type: 'error', code: 'rate-limited' });
    });

    it('limits connections per network address', async () => {
      const url = await start({ limits: { maxConnectionsPerAddress: 2 } });
      const a = await TestClient.connect(url);
      const b = await TestClient.connect(url);
      const c = await TestClient.connect(url);
      clients.push(a, b, c);
      expect((await c.next()).code).toBe('too-many-connections');
      expect(await c.closed).toBe(CloseCode.tryAgainLater);
    });

    it('uses the proxy-reported address only when told to trust the proxy', async () => {
      const url = await start({
        config: { trustProxy: true },
        limits: { maxConnectionsPerAddress: 1 },
      });
      const { WebSocket } = await import('ws');
      const open = (ip: string) =>
        new Promise<InstanceType<typeof WebSocket>>((resolve) => {
          const ws = new WebSocket(url, { headers: { 'x-forwarded-for': `10.0.0.9, ${ip}` } });
          ws.once('message', () => resolve(ws));
        });
      const first = await open('203.0.113.1');
      const second = await open('203.0.113.2');
      expect(second.readyState).toBe(WebSocket.OPEN);
      first.close();
      second.close();
    });

    it('limits devices per Sotto ID', async () => {
      const url = await start({ limits: { maxDevicesPerId: 1 } });
      const identity = newIdentity();
      await login(url, identity);
      const second = await TestClient.login(url, identity);
      clients.push(second);
      expect(await second.next()).toEqual({ type: 'error', code: 'too-many-devices' });
      expect(await second.closed).toBe(CloseCode.tooManyDevices);
    });
  });

  describe('http', () => {
    it('serves /health and refuses other paths, including the old dev rooms', async () => {
      const url = await start();
      const base = url.replace('ws://', 'http://').replace('/relay', '');
      const res = await fetch(`${base}/health`);
      expect(await res.json()).toEqual({ status: 'ok' });
      expect((await fetch(`${base}/nope`)).status).toBe(404);
      await expect(TestClient.connect(url.replace('/relay', '/dev/rooms'))).rejects.toThrow();
    });

    it('closes connections that send oversized frames', async () => {
      const url = await start({ config: { maxMessageBytes: 1024 } });
      const client = await TestClient.connect(url);
      clients.push(client);
      await client.next();
      client.ws.send('x'.repeat(4096));
      expect(await client.closed).toBe(1009);
    });
  });
});
