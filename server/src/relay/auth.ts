import { randomBytes, verify } from 'node:crypto';
import { decodeBase64Url, isValidId, publicKeyForId } from './ids.js';

/**
 * Challenge-response login. The client proves it holds the private key for
 * its Sotto ID by signing:
 *
 *     "sotto-relay-auth-v1\0" || nonce (32 bytes) || UTF-8(host)
 *
 * `host` is the Host header the client connected with, so a malicious relay
 * can't forward a challenge from this server to a victim and reuse the
 * signature here.
 */
export const AUTH_DOMAIN = Buffer.from('sotto-relay-auth-v1\0', 'utf8');
export const NONCE_BYTES = 32;

export function newChallenge(): Buffer {
  return randomBytes(NONCE_BYTES);
}

export function authMessage(nonce: Buffer, host: string): Buffer {
  return Buffer.concat([AUTH_DOMAIN, nonce, Buffer.from(host.toLowerCase(), 'utf8')]);
}

export function verifyAuth(id: unknown, signature: unknown, nonce: Buffer, host: string): boolean {
  if (!isValidId(id) || typeof signature !== 'string') return false;
  const sig = decodeBase64Url(signature);
  if (sig === null || sig.length !== 64) return false;
  try {
    return verify(null, authMessage(nonce, host), publicKeyForId(id), sig);
  } catch {
    return false;
  }
}
