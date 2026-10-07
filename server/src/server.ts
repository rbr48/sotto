import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Config } from './config.js';
import { DEFAULT_LIMITS, Relay, type RelayLimits } from './relay/relay.js';

export const RELAY_PATH = '/relay';

export interface RelayServer {
  readonly http: Server;
  readonly relay: Relay;
  /** Resolves to the port actually bound (useful when configured with port 0). */
  listen(): Promise<number>;
  close(): Promise<void>;
}

interface TrackedSocket extends WebSocket {
  isAlive?: boolean;
}

export function createRelayServer(
  config: Config,
  limits: RelayLimits = DEFAULT_LIMITS,
): RelayServer {
  const relay = new Relay(limits);
  const http = createServer(handleHttp);
  const wss = new WebSocketServer({ noServer: true, maxPayload: config.maxMessageBytes });

  http.on('upgrade', (req, socket, head) => {
    const path = new URL(req.url ?? '/', 'http://localhost').pathname;
    const host = req.headers.host;
    if (path !== RELAY_PATH || host === undefined) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws: TrackedSocket) => {
      ws.isAlive = true;
      ws.on('pong', () => {
        ws.isAlive = true;
      });
      relay.attach(ws, host, clientAddress(req, config.trustProxy));
    });
  });

  const heartbeat = setInterval(() => {
    for (const client of wss.clients as Set<TrackedSocket>) {
      if (client.isAlive === false) {
        client.terminate();
        continue;
      }
      client.isAlive = false;
      client.ping();
    }
  }, config.heartbeatMs);
  heartbeat.unref();

  return {
    http,
    relay,
    listen: () =>
      new Promise((resolve, reject) => {
        http.once('error', reject);
        http.listen(config.port, config.host, () => {
          http.off('error', reject);
          resolve((http.address() as AddressInfo).port);
        });
      }),
    close: () =>
      new Promise((resolve) => {
        clearInterval(heartbeat);
        relay.close();
        for (const client of wss.clients) client.terminate();
        wss.close();
        http.close(() => resolve());
      }),
  };
}

function clientAddress(req: IncomingMessage, trustProxy: boolean): string {
  if (trustProxy) {
    const forwarded = req.headers['x-forwarded-for'];
    const value = Array.isArray(forwarded) ? forwarded.at(-1) : forwarded;
    const last = value?.split(',').at(-1)?.trim();
    if (last) return last;
  }
  return req.socket.remoteAddress ?? 'unknown';
}

function handleHttp(req: IncomingMessage, res: ServerResponse): void {
  const path = new URL(req.url ?? '/', 'http://localhost').pathname;
  if (req.method === 'GET' && path === '/health') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not-found' }));
}
