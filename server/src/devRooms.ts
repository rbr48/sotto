import type { WebSocket } from 'ws';

/**
 * Phase 1 proof-of-concept signaling: two peers join a room by code and the
 * server forwards their messages to each other. Messages are plaintext and
 * nothing is authenticated, so this exists only for local experiments and is
 * replaced by the encrypted relay in Phase 3.
 *
 * Everything lives in memory and is dropped as soon as a room empties.
 */

export const ROOM_CODE_PATTERN = /^[A-Za-z0-9_-]{4,64}$/;
const MAX_PEERS_PER_ROOM = 2;

export type ClientMessage =
  { type: 'join'; room: string } | { type: 'signal'; data: unknown } | { type: 'leave' };

export type ServerMessage =
  | { type: 'joined'; peers: number }
  | { type: 'peer-joined' }
  | { type: 'peer-left' }
  | { type: 'signal'; data: unknown }
  | { type: 'error'; code: ErrorCode };

export type ErrorCode =
  'bad-message' | 'bad-room' | 'room-full' | 'too-many-rooms' | 'already-joined' | 'not-in-room';

export class DevRooms {
  private readonly rooms = new Map<string, Set<WebSocket>>();
  private readonly roomOf = new Map<WebSocket, string>();

  constructor(private readonly maxRooms: number) {}

  get roomCount(): number {
    return this.rooms.size;
  }

  handle(socket: WebSocket, raw: string): void {
    const message = parseClientMessage(raw);
    if (message === null) {
      send(socket, { type: 'error', code: 'bad-message' });
      return;
    }
    switch (message.type) {
      case 'join':
        this.join(socket, message.room);
        break;
      case 'signal':
        this.forward(socket, message.data);
        break;
      case 'leave':
        this.leave(socket);
        break;
    }
  }

  leave(socket: WebSocket): void {
    const code = this.roomOf.get(socket);
    if (code === undefined) return;
    this.roomOf.delete(socket);
    const peers = this.rooms.get(code);
    if (peers === undefined) return;
    peers.delete(socket);
    if (peers.size === 0) {
      this.rooms.delete(code);
      return;
    }
    for (const peer of peers) send(peer, { type: 'peer-left' });
  }

  private join(socket: WebSocket, code: string): void {
    if (this.roomOf.has(socket)) {
      send(socket, { type: 'error', code: 'already-joined' });
      return;
    }
    if (!ROOM_CODE_PATTERN.test(code)) {
      send(socket, { type: 'error', code: 'bad-room' });
      return;
    }
    let peers = this.rooms.get(code);
    if (peers === undefined) {
      if (this.rooms.size >= this.maxRooms) {
        send(socket, { type: 'error', code: 'too-many-rooms' });
        return;
      }
      peers = new Set();
      this.rooms.set(code, peers);
    }
    if (peers.size >= MAX_PEERS_PER_ROOM) {
      send(socket, { type: 'error', code: 'room-full' });
      return;
    }
    for (const peer of peers) send(peer, { type: 'peer-joined' });
    // The peer that joins second sees peers: 1 and makes the WebRTC offer.
    send(socket, { type: 'joined', peers: peers.size });
    peers.add(socket);
    this.roomOf.set(socket, code);
  }

  private forward(socket: WebSocket, data: unknown): void {
    const code = this.roomOf.get(socket);
    const peers = code === undefined ? undefined : this.rooms.get(code);
    if (peers === undefined) {
      send(socket, { type: 'error', code: 'not-in-room' });
      return;
    }
    for (const peer of peers) {
      if (peer !== socket) send(peer, { type: 'signal', data });
    }
  }
}

export function parseClientMessage(raw: string): ClientMessage | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null) return null;
  const message = value as Record<string, unknown>;
  switch (message.type) {
    case 'join':
      return typeof message.room === 'string' ? { type: 'join', room: message.room } : null;
    case 'signal':
      return 'data' in message ? { type: 'signal', data: message.data } : null;
    case 'leave':
      return { type: 'leave' };
    default:
      return null;
  }
}

function send(socket: WebSocket, message: ServerMessage): void {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message));
}
