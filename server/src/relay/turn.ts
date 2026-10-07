import { createHmac, randomBytes } from 'node:crypto';

/** One entry of RTCConfiguration.iceServers. */
export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface IceConfig {
  /** e.g. `stun:sotto.example:3478` */
  stunUrls: string[];
  /** e.g. `turn:sotto.example:3478?transport=udp`, `turns:sotto.example:5349?transport=tcp` */
  turnUrls: string[];
  /** Shared with coturn (`static-auth-secret`). Empty disables TURN. */
  turnSecret: string;
  /** Credential lifetime. */
  turnTtlSec: number;
}

/**
 * Time-limited TURN credentials (the "TURN REST API" scheme coturn supports
 * with `use-auth-secret`):
 *
 *     username   = "<unix expiry>:<random>"
 *     credential = base64(HMAC-SHA1(secret, username))
 *
 * Nothing is stored, and the username deliberately contains no Sotto ID, so
 * coturn can't tell which person a relayed call belongs to.
 */
export function turnCredentials(
  secret: string,
  ttlSec: number,
  nowMs: number = Date.now(),
): { username: string; credential: string; expiresAt: number } {
  const expiresAt = Math.floor(nowMs / 1000) + ttlSec;
  const username = `${expiresAt}:${randomBytes(9).toString('base64url')}`;
  const credential = createHmac('sha1', secret).update(username).digest('base64');
  return { username, credential, expiresAt };
}

/** ICE servers for one client, with fresh TURN credentials. */
export function iceServersFor(config: IceConfig, nowMs: number = Date.now()): IceServer[] {
  const servers: IceServer[] = [];
  if (config.stunUrls.length > 0) servers.push({ urls: config.stunUrls });
  if (config.turnUrls.length > 0 && config.turnSecret !== '') {
    const { username, credential } = turnCredentials(config.turnSecret, config.turnTtlSec, nowMs);
    servers.push({ urls: config.turnUrls, username, credential });
  }
  return servers;
}
