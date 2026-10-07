import { generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { WebSocket } from 'ws';
import { loadConfig, type Config } from '../src/config.js';
import { authMessage } from '../src/relay/auth.js';
import { DEFAULT_LIMITS, type RelayLimits } from '../src/relay/relay.js';
import { createRelayServer, type RelayServer } from '../src/server.js';

export async function startServer(
  options: { config?: Partial<Config>; limits?: Partial<RelayLimits> } = {},
): Promise<{ server: RelayServer; port: number; url: string }> {
  const config = { ...loadConfig({}), host: '127.0.0.1', port: 0, ...options.config };
  const server = createRelayServer(config, { ...DEFAULT_LIMITS, ...options.limits });
  const port = await server.listen();
  return { server, port, url: `ws://127.0.0.1:${port}/relay` };
}

export interface TestIdentity {
  id: string;
  privateKey: KeyObject;
}

export function newIdentity(): TestIdentity {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { id: publicKey.export({ format: 'jwk' }).x as string, privateKey };
}

/** A WebSocket client that buffers received JSON messages so tests can await them in order. */
export class TestClient {
  private readonly queue: Record<string, unknown>[] = [];
  private readonly waiters: ((message: Record<string, unknown>) => void)[] = [];
  readonly closed: Promise<number>;

  private constructor(readonly ws: WebSocket) {
    ws.on('message', (data) => {
      const message = JSON.parse(data.toString()) as Record<string, unknown>;
      const waiter = this.waiters.shift();
      if (waiter) waiter(message);
      else this.queue.push(message);
    });
    this.closed = new Promise((resolve) => ws.once('close', resolve));
  }

  static connect(url: string): Promise<TestClient> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.once('open', () => resolve(new TestClient(ws)));
      ws.once('error', reject);
    });
  }

  /** Connects and completes the challenge-response login. */
  static async login(url: string, identity: TestIdentity, host?: string): Promise<TestClient> {
    const client = await TestClient.connect(url);
    const challenge = await client.next();
    const nonce = Buffer.from(challenge.nonce as string, 'base64url');
    const signedHost = host ?? new URL(url).host;
    const sig = sign(null, authMessage(nonce, signedHost), identity.privateKey).toString(
      'base64url',
    );
    client.send({ type: 'auth', id: identity.id, sig });
    return client;
  }

  send(message: unknown): void {
    this.ws.send(JSON.stringify(message));
  }

  next(timeoutMs = 2000): Promise<Record<string, unknown>> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timed out waiting for message')), timeoutMs);
      this.waiters.push((message) => {
        clearTimeout(timer);
        resolve(message);
      });
    });
  }

  /** Resolves true if no message arrives within `ms`. */
  async silentFor(ms: number): Promise<boolean> {
    try {
      await this.next(ms);
      return false;
    } catch {
      return true;
    }
  }

  close(): Promise<void> {
    return new Promise((resolve) => {
      if (this.ws.readyState === WebSocket.CLOSED) return resolve();
      this.ws.once('close', () => resolve());
      this.ws.close();
    });
  }
}
