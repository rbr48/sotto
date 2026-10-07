import { createPublicKey, type KeyObject } from 'node:crypto';

/** A Sotto ID: unpadded base64url of a 32-byte Ed25519 public key (43 chars). */
const ID_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** Returns true for canonical Sotto IDs only (one valid text form per key). */
export function isValidId(id: unknown): id is string {
  if (typeof id !== 'string' || !ID_PATTERN.test(id)) return false;
  const bytes = Buffer.from(id, 'base64url');
  return bytes.length === 32 && bytes.toString('base64url') === id;
}

export function decodeBase64Url(text: string): Buffer | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const bytes = Buffer.from(text, 'base64url');
  return bytes.toString('base64url') === text ? bytes : null;
}

/** Ed25519 public key object for a (valid) Sotto ID. */
export function publicKeyForId(id: string): KeyObject {
  return createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: id }, format: 'jwk' });
}
