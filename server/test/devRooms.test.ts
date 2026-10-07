import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';
import { parseClientMessage } from '../src/devRooms.js';
import type { RelayServer } from '../src/server.js';
import { startServer, TestClient } from './helpers.js';

describe('dev rooms', () => {
  let server: RelayServer;
  let url: string;
  const clients: TestClient[] = [];

  const connect = async (): Promise<TestClient> => {
    const client = await TestClient.connect(url);
    clients.push(client);
    return client;
  };

  beforeEach(async () => {
    const started = await startServer();
    server = started.server;
    url = `ws://127.0.0.1:${started.port}/dev/rooms`;
  });

  afterEach(async () => {
    await Promise.all(clients.splice(0).map((c) => c.close()));
    await server.close();
  });

  it('pairs two peers and forwards signals between them', async () => {
    const alice = await connect();
    const bob = await connect();

    alice.send({ type: 'join', room: 'room-1234' });
    expect(await alice.next()).toEqual({ type: 'joined', peers: 0 });

    bob.send({ type: 'join', room: 'room-1234' });
    expect(await bob.next()).toEqual({ type: 'joined', peers: 1 });
    expect(await alice.next()).toEqual({ type: 'peer-joined' });

    bob.send({ type: 'signal', data: { sdp: 'offer' } });
    expect(await alice.next()).toEqual({ type: 'signal', data: { sdp: 'offer' } });

    alice.send({ type: 'signal', data: { sdp: 'answer' } });
    expect(await bob.next()).toEqual({ type: 'signal', data: { sdp: 'answer' } });
  });

  it('rejects a third peer', async () => {
    const [a, b, c] = [await connect(), await connect(), await connect()];
    a.send({ type: 'join', room: 'full-room' });
    await a.next();
    b.send({ type: 'join', room: 'full-room' });
    await b.next();
    c.send({ type: 'join', room: 'full-room' });
    expect(await c.next()).toEqual({ type: 'error', code: 'room-full' });
  });

  it('tells the remaining peer when the other disconnects, and frees empty rooms', async () => {
    const alice = await connect();
    const bob = await connect();
    alice.send({ type: 'join', room: 'leave-test' });
    await alice.next();
    bob.send({ type: 'join', room: 'leave-test' });
    await bob.next();
    await alice.next();

    await bob.close();
    expect(await alice.next()).toEqual({ type: 'peer-left' });

    alice.send({ type: 'leave' });
    const carol = await connect();
    carol.send({ type: 'join', room: 'leave-test' });
    expect(await carol.next()).toEqual({ type: 'joined', peers: 0 });
  });

  it('rejects invalid room codes, malformed messages and signals outside a room', async () => {
    const client = await connect();
    client.send({ type: 'join', room: 'a b' });
    expect(await client.next()).toEqual({ type: 'error', code: 'bad-room' });
    client.ws.send('not json');
    expect(await client.next()).toEqual({ type: 'error', code: 'bad-message' });
    client.send({ type: 'signal', data: 1 });
    expect(await client.next()).toEqual({ type: 'error', code: 'not-in-room' });
  });

  it('enforces the room limit', async () => {
    await server.close();
    const started = await startServer({ maxRooms: 1 });
    server = started.server;
    url = `ws://127.0.0.1:${started.port}/dev/rooms`;
    const a = await connect();
    const b = await connect();
    a.send({ type: 'join', room: 'first' });
    await a.next();
    b.send({ type: 'join', room: 'second' });
    expect(await b.next()).toEqual({ type: 'error', code: 'too-many-rooms' });
  });
});

describe('parseClientMessage', () => {
  it('accepts valid messages and rejects everything else', () => {
    expect(parseClientMessage('{"type":"join","room":"abcd"}')).toEqual({
      type: 'join',
      room: 'abcd',
    });
    expect(parseClientMessage('{"type":"signal","data":null}')).toEqual({
      type: 'signal',
      data: null,
    });
    expect(parseClientMessage('{"type":"leave"}')).toEqual({ type: 'leave' });
    expect(parseClientMessage('{"type":"join","room":5}')).toBeNull();
    expect(parseClientMessage('{"type":"signal"}')).toBeNull();
    expect(parseClientMessage('{"type":"other"}')).toBeNull();
    expect(parseClientMessage('[]')).toBeNull();
    expect(parseClientMessage('null')).toBeNull();
  });
});

describe('server', () => {
  it('serves /health', async () => {
    const { server, port } = await startServer({ enableDevRooms: false });
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ status: 'ok', devRooms: false });
      expect((await fetch(`http://127.0.0.1:${port}/nope`)).status).toBe(404);
    } finally {
      await server.close();
    }
  });

  it('refuses dev-room connections when dev rooms are disabled', async () => {
    const { server, port } = await startServer({ enableDevRooms: false });
    try {
      await expect(TestClient.connect(`ws://127.0.0.1:${port}/dev/rooms`)).rejects.toThrow();
    } finally {
      await server.close();
    }
  });

  it('closes connections that send oversized messages', async () => {
    const { server, port } = await startServer({ maxMessageBytes: 1024 });
    try {
      const client = await TestClient.connect(`ws://127.0.0.1:${port}/dev/rooms`);
      const closed = new Promise<number>((resolve) => client.ws.once('close', resolve));
      client.ws.send('x'.repeat(4096));
      expect(await closed).toBe(1009);
      expect(client.ws.readyState).toBe(WebSocket.CLOSED);
    } finally {
      await server.close();
    }
  });
});
