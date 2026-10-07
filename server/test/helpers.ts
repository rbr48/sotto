import { WebSocket } from 'ws';
import { loadConfig, type Config } from '../src/config.js';
import { createRelayServer, type RelayServer } from '../src/server.js';

export async function startServer(
  overrides: Partial<Config> = {},
): Promise<{ server: RelayServer; port: number }> {
  const config = {
    ...loadConfig({}),
    host: '127.0.0.1',
    port: 0,
    enableDevRooms: true,
    ...overrides,
  };
  const server = createRelayServer(config);
  const port = await server.listen();
  return { server, port };
}

/** A WebSocket client that buffers received JSON messages so tests can await them in order. */
export class TestClient {
  private readonly queue: unknown[] = [];
  private readonly waiters: ((message: unknown) => void)[] = [];

  private constructor(readonly ws: WebSocket) {
    ws.on('message', (data) => {
      const message: unknown = JSON.parse(data.toString());
      const waiter = this.waiters.shift();
      if (waiter) waiter(message);
      else this.queue.push(message);
    });
  }

  static connect(url: string): Promise<TestClient> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.once('open', () => resolve(new TestClient(ws)));
      ws.once('error', reject);
    });
  }

  send(message: unknown): void {
    this.ws.send(JSON.stringify(message));
  }

  next(timeoutMs = 2000): Promise<unknown> {
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

  close(): Promise<void> {
    return new Promise((resolve) => {
      if (this.ws.readyState === WebSocket.CLOSED) return resolve();
      this.ws.once('close', () => resolve());
      this.ws.close();
    });
  }
}
