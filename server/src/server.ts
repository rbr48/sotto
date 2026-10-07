import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Config } from './config.js';
import { DevRooms } from './devRooms.js';

export const DEV_ROOMS_PATH = '/dev/rooms';

export interface RelayServer {
  readonly http: Server;
  /** Resolves to the port actually bound (useful when configured with port 0). */
  listen(): Promise<number>;
  close(): Promise<void>;
}

interface TrackedSocket extends WebSocket {
  isAlive?: boolean;
}

export function createRelayServer(config: Config): RelayServer {
  const devRooms = config.enableDevRooms ? new DevRooms(config.maxRooms) : null;
  const http = createServer((req, res) => handleHttp(req, res, devRooms));
  const wss = new WebSocketServer({ noServer: true, maxPayload: config.maxMessageBytes });

  http.on('upgrade', (req, socket, head) => {
    const path = new URL(req.url ?? '/', 'http://localhost').pathname;
    if (devRooms === null || path !== DEV_ROOMS_PATH) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws));
  });

  wss.on('connection', (ws: TrackedSocket) => {
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });
    ws.on('message', (data, isBinary) => {
      if (isBinary) {
        ws.close(1003, 'binary not supported');
        return;
      }
      devRooms?.handle(ws, data.toString());
    });
    ws.on('close', () => devRooms?.leave(ws));
    ws.on('error', () => ws.terminate());
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
        for (const client of wss.clients) client.terminate();
        wss.close();
        http.close(() => resolve());
      }),
  };
}

function handleHttp(req: IncomingMessage, res: ServerResponse, devRooms: DevRooms | null): void {
  const path = new URL(req.url ?? '/', 'http://localhost').pathname;
  if (req.method === 'GET' && path === '/health') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ status: 'ok', devRooms: devRooms !== null }));
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not-found' }));
}
