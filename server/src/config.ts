import type { IceConfig } from './relay/turn.js';

export interface Config {
  host: string;
  port: number;
  /** Largest WebSocket message accepted, in bytes. */
  maxMessageBytes: number;
  /** Interval between heartbeat pings, in milliseconds. */
  heartbeatMs: number;
  /**
   * Behind a reverse proxy (Caddy), take the client address from the last
   * X-Forwarded-For entry. Only used for per-address connection limits.
   */
  trustProxy: boolean;
  /** STUN/TURN servers handed to logged-in clients. */
  ice: IceConfig;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    host: env.HOST ?? '0.0.0.0',
    port: parseIntOr(env.PORT, 8080, 0),
    maxMessageBytes: parseIntOr(env.SOTTO_MAX_MESSAGE_BYTES, 96 * 1024),
    heartbeatMs: parseIntOr(env.SOTTO_HEARTBEAT_MS, 25_000),
    trustProxy: env.SOTTO_TRUST_PROXY === '1',
    ice: {
      stunUrls: parseList(env.SOTTO_STUN_URLS),
      turnUrls: parseList(env.SOTTO_TURN_URLS),
      turnSecret: env.SOTTO_TURN_SECRET ?? '',
      turnTtlSec: parseIntOr(env.SOTTO_TURN_TTL_SEC, 6 * 60 * 60),
    },
  };
}

function parseIntOr(value: string | undefined, fallback: number, min = 1): number {
  if (value === undefined || value === '') return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed < min) {
    throw new Error(`Invalid numeric setting: ${value}`);
  }
  return parsed;
}

function parseList(value: string | undefined): string[] {
  return (value ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}
