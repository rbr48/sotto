#!/usr/bin/env node
// Signs a release's checksums for in-app updates. The app (desktop, see
// app/lib/desktop/update_verifier.dart) installs an update only when the
// release's SHA256SUMS.txt is signed by the release key and the installer's
// digest is in it.
//
//   node tools/release/sign-sums.mjs --generate
//       prints a new release key: the seed (keep it secret: store it as the
//       UPDATE_SIGNING_KEY secret) and the public key (store it as the
//       UPDATE_PUBLIC_KEY repository variable)
//
//   UPDATE_SIGNING_KEY=<seed> node tools/release/sign-sums.mjs <SHA256SUMS.txt> > SHA256SUMS.txt.sig
//       writes the signature to stdout: the 64 raw bytes of SHA256SUMS.txt.sig
//
//   node tools/release/sign-sums.mjs --verify <public key> <SHA256SUMS.txt> <SHA256SUMS.txt.sig>
//       checks a signature file the way the app does; exits 1 when it is wrong
//
// The seed is read from the environment, not the command line, so it stays out
// of process listings and shell history.

import { createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// DER prefixes: a PKCS#8 Ed25519 private key holds a 32-byte seed after this,
// and an SPKI public key holds the 32-byte key after that.
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

export function privateKeyFromSeed(seed) {
  if (seed.length !== 32) throw new Error('the signing seed must be 32 bytes');
  return createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  });
}

export function publicKeyFromSeed(seed) {
  const publicKey = createPublicKey(privateKeyFromSeed(seed));
  return publicKey.export({ format: 'der', type: 'spki' }).subarray(SPKI_PREFIX.length);
}

export function generateRelease() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const der = privateKey.export({ format: 'der', type: 'pkcs8' });
  const seed = der.subarray(der.length - 32);
  return {
    seed: seed.toString('base64url'),
    publicKey: publicKey
      .export({ format: 'der', type: 'spki' })
      .subarray(SPKI_PREFIX.length)
      .toString('base64url'),
  };
}

// The signature is the 64 bytes Ed25519 produces, unencoded: the app reads
// SHA256SUMS.txt.sig as bytes and refuses anything that is not 64 of them.
export function signFile(seed, file) {
  return sign(null, readFileSync(file), privateKeyFromSeed(seed));
}

export function verifyFile(publicKeyB64, file, signatureFile) {
  const key = createPublicKey({
    key: Buffer.concat([SPKI_PREFIX, Buffer.from(publicKeyB64, 'base64url')]),
    format: 'der',
    type: 'spki',
  });
  const signature = readFileSync(signatureFile);
  return signature.length === 64 && verify(null, readFileSync(file), key, signature);
}

function main(argv) {
  if (argv[0] === '--generate') {
    const release = generateRelease();
    process.stdout.write(
      `UPDATE_SIGNING_KEY (secret): ${release.seed}\n` +
        `UPDATE_PUBLIC_KEY (variable): ${release.publicKey}\n`,
    );
    return 0;
  }
  if (argv[0] === '--verify') {
    const [, publicKey, file, signatureFile] = argv;
    if (!publicKey || !file || !signatureFile) {
      throw new Error('usage: --verify <public key> <SHA256SUMS.txt> <SHA256SUMS.txt.sig>');
    }
    const ok = verifyFile(publicKey, file, signatureFile);
    process.stdout.write(ok ? 'signature ok\n' : 'signature does NOT match\n');
    return ok ? 0 : 1;
  }
  const [file] = argv;
  const seedB64 = process.env.UPDATE_SIGNING_KEY;
  if (!file || !seedB64) {
    throw new Error('usage: UPDATE_SIGNING_KEY=<seed> node sign-sums.mjs <SHA256SUMS.txt>');
  }
  // Raw bytes, no newline: the workflow redirects them into SHA256SUMS.txt.sig.
  process.stdout.write(signFile(Buffer.from(seedB64, 'base64url'), file));
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`sign-sums: ${error.message}\n`);
    process.exitCode = 2;
  }
}
