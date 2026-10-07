import type { WebSocket } from 'ws';
import { newChallenge, verifyAuth } from './auth.js';
import { isValidId } from './ids.js';
import { ConnectionCounter, TokenBucket } from './limits.js';
import { MessageQueue, type QueueLimits } from './queue.js';
import type { IceServer } from './turn.js';

/**
 * The Sotto relay: routes end-to-end encrypted envelopes between Sotto IDs.
 *
 * It can't read envelope bodies (they are sealed to the recipient) and it
 * keeps everything in memory: who is connected, and envelopes waiting up to
 * `queue.ttlMs` for a recipient to connect. Nothing is logged or stored.
 *
 * Protocol (JSON text frames):
 *
 *   server → { type: "challenge", nonce }
 *   client → { type: "auth", id, sig }          sig over auth.ts:authMessage
 *   server → { type: "ready", id, ice }          ice = STUN/TURN servers
 *   client → { type: "ice" }                    fresh TURN credentials
 *   server → { type: "ice", ice }
 *   client → { type: "send", to, body, ref? }   body = envelope (opaque)
 *   server → { type: "message", from, body }    from = authenticated sender
 *   server → { type: "ack", ref, status }       delivered | queued | dropped
 *   server → { type: "error", code }
 */
export interface RelayLimits {
  authTimeoutMs: number;
  maxBodyChars: number;
  messagesPerSec: number;
  messageBurst: number;
  maxConnectionsPerAddress: number;
  maxDevicesPerId: number;
  queue: QueueLimits;
}

export const DEFAULT_LIMITS: RelayLimits = {
  authTimeoutMs: 10_000,
  maxBodyChars: 72 * 1024,
  messagesPerSec: 20,
  messageBurst: 60,
  maxConnectionsPerAddress: 20,
  maxDevicesPerId: 5,
  queue: { ttlMs: 60_000, maxPerRecipient: 50, maxTotalBytes: 64 * 1024 * 1024 },
};

export type RelayErrorCode =
  | 'bad-message'
  | 'auth-failed'
  | 'auth-timeout'
  | 'not-authenticated'
  | 'bad-recipient'
  | 'too-large'
  | 'rate-limited'
  | 'too-many-connections'
  | 'too-many-devices';

/** WebSocket close codes used by the relay. */
export const CloseCode = {
  authFailed: 4001,
  authTimeout: 4002,
  tooManyDevices: 4003,
  tryAgainLater: 1013,
} as const;

interface Connection {
  ws: WebSocket;
  id: string | null;
  nonce: Buffer;
  host: string;
  bucket: TokenBucket;
}

export class Relay {
  private readonly online = new Map<string, Set<Connection>>();
  private readonly queue: MessageQueue;
  private readonly addresses: ConnectionCounter;
  private readonly pruneTimer: NodeJS.Timeout;

  constructor(
    private readonly limits: RelayLimits = DEFAULT_LIMITS,
    /** Fresh ICE servers (with new TURN credentials) for each request. */
    private readonly iceServers: () => IceServer[] = () => [],
  ) {
    this.queue = new MessageQueue(limits.queue);
    this.addresses = new ConnectionCounter(limits.maxConnectionsPerAddress);
    this.pruneTimer = setInterval(() => this.queue.prune(), 10_000);
    this.pruneTimer.unref();
  }

  /** Number of distinct IDs online (aggregate only). */
  get onlineCount(): number {
    return this.online.size;
  }

  get queuedCount(): number {
    return this.queue.size;
  }

  close(): void {
    clearInterval(this.pruneTimer);
  }

  /**
   * Takes over a freshly upgraded WebSocket. `host` is the Host header the
   * client connected with; `address` identifies the client network address
   * for connection limits only.
   */
  attach(ws: WebSocket, host: string, address: string): void {
    const handle = this.addresses.acquire(address);
    if (handle === null) {
      send(ws, { type: 'error', code: 'too-many-connections' });
      ws.close(CloseCode.tryAgainLater, 'too many connections');
      return;
    }
    const conn: Connection = {
      ws,
      id: null,
      nonce: newChallenge(),
      host,
      bucket: new TokenBucket(this.limits.messagesPerSec, this.limits.messageBurst),
    };
    const authTimer = setTimeout(() => {
      if (conn.id === null) {
        send(ws, { type: 'error', code: 'auth-timeout' });
        ws.close(CloseCode.authTimeout, 'auth timeout');
      }
    }, this.limits.authTimeoutMs);

    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        ws.close(1003, 'binary not supported');
        return;
      }
      this.onMessage(conn, data.toString());
    });
    ws.on('close', () => {
      clearTimeout(authTimer);
      this.addresses.release(handle);
      this.goOffline(conn);
    });
    ws.on('error', () => ws.terminate());

    send(ws, { type: 'challenge', nonce: conn.nonce.toString('base64url') });
  }

  private onMessage(conn: Connection, raw: string): void {
    if (!conn.bucket.take()) {
      send(conn.ws, { type: 'error', code: 'rate-limited' });
      return;
    }
    let message: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(raw);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error();
      message = parsed as Record<string, unknown>;
    } catch {
      send(conn.ws, { type: 'error', code: 'bad-message' });
      return;
    }

    if (conn.id === null) {
      if (message.type !== 'auth') {
        send(conn.ws, { type: 'error', code: 'not-authenticated' });
        return;
      }
      this.authenticate(conn, message.id, message.sig);
      return;
    }

    if (message.type === 'ice') {
      send(conn.ws, { type: 'ice', ice: this.iceServers() });
      return;
    }
    if (message.type !== 'send') {
      send(conn.ws, { type: 'error', code: 'bad-message' });
      return;
    }
    const ref = typeof message.ref === 'string' && message.ref.length <= 64 ? message.ref : null;
    if (!isValidId(message.to)) {
      send(conn.ws, { type: 'error', code: 'bad-recipient' });
      return;
    }
    if (typeof message.body !== 'string' || message.body.length === 0) {
      send(conn.ws, { type: 'error', code: 'bad-message' });
      return;
    }
    if (message.body.length > this.limits.maxBodyChars) {
      send(conn.ws, { type: 'error', code: 'too-large' });
      return;
    }
    const status = this.route(conn.id, message.to, message.body);
    if (ref !== null) send(conn.ws, { type: 'ack', ref, status });
  }

  private authenticate(conn: Connection, id: unknown, sig: unknown): void {
    if (!verifyAuth(id, sig, conn.nonce, conn.host)) {
      send(conn.ws, { type: 'error', code: 'auth-failed' });
      conn.ws.close(CloseCode.authFailed, 'auth failed');
      return;
    }
    const verifiedId = id as string;
    const devices = this.online.get(verifiedId) ?? new Set<Connection>();
    if (devices.size >= this.limits.maxDevicesPerId) {
      send(conn.ws, { type: 'error', code: 'too-many-devices' });
      conn.ws.close(CloseCode.tooManyDevices, 'too many devices');
      return;
    }
    conn.id = verifiedId;
    devices.add(conn);
    this.online.set(verifiedId, devices);
    send(conn.ws, { type: 'ready', id: verifiedId, ice: this.iceServers() });
    for (const queued of this.queue.take(verifiedId)) {
      send(conn.ws, { type: 'message', from: queued.from, body: queued.body });
    }
  }

  private route(from: string, to: string, body: string): 'delivered' | 'queued' | 'dropped' {
    const devices = this.online.get(to);
    if (devices !== undefined && devices.size > 0) {
      for (const device of devices) send(device.ws, { type: 'message', from, body });
      return 'delivered';
    }
    return this.queue.push(to, from, body) ? 'queued' : 'dropped';
  }

  private goOffline(conn: Connection): void {
    if (conn.id === null) return;
    const devices = this.online.get(conn.id);
    devices?.delete(conn);
    if (devices?.size === 0) this.online.delete(conn.id);
  }
}

function send(ws: WebSocket, message: Record<string, unknown>): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message));
}
