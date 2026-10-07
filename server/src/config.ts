export interface Config {
  host: string;
  port: number;
  /**
   * Phase 1 only: plaintext rooms used for the WebRTC proof of concept.
   * They are replaced by the encrypted relay in Phase 3 and must stay
   * disabled in production.
   */
  enableDevRooms: boolean;
  /** Largest WebSocket message accepted, in bytes. */
  maxMessageBytes: number;
  /** Interval between heartbeat pings, in milliseconds. */
  heartbeatMs: number;
  maxRooms: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    host: env.HOST ?? '0.0.0.0',
    port: parseIntOr(env.PORT, 8080),
    enableDevRooms: env.SOTTO_DEV_ROOMS === '1',
    maxMessageBytes: parseIntOr(env.SOTTO_MAX_MESSAGE_BYTES, 64 * 1024),
    heartbeatMs: parseIntOr(env.SOTTO_HEARTBEAT_MS, 25_000),
    maxRooms: parseIntOr(env.SOTTO_MAX_ROOMS, 10_000),
  };
}

function parseIntOr(value: string | undefined, fallback: number): number {
  if (value === undefined || value === '') return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`Invalid numeric setting: ${value}`);
  }
  return parsed;
}
