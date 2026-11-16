import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  generateRelease,
  publicKeyFromSeed,
  signFile,
  verifyFile,
} from './sign-sums.mjs';

// RFC 8032, section 7.1, test 1: an Ed25519 key and the empty message.
const RFC_SEED = Buffer.from(
  '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
  'hex',
);
const RFC_PUBLIC = 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';
const RFC_SIGNATURE =
  'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b';

function tempFile(name, text) {
  const dir = mkdtempSync(join(tmpdir(), 'sign-sums-'));
  const file = join(dir, name);
  writeFileSync(file, text);
  return file;
}

test('matches the RFC 8032 known answer', () => {
  const empty = tempFile('empty', '');
  assert.equal(publicKeyFromSeed(RFC_SEED).toString('hex'), RFC_PUBLIC);
  const signature = signFile(RFC_SEED, empty);
  assert.equal(signature.toString('hex'), RFC_SIGNATURE);
});

test('a generated release signs its checksum list, and the list cannot be changed', () => {
  const release = generateRelease();
  const sums = tempFile('SHA256SUMS.txt', `${'a'.repeat(64)}  sotto-windows-x64-setup.exe\n`);
  const sig = tempFile('SHA256SUMS.txt.sig', signFile(Buffer.from(release.seed, 'base64url'), sums));
  assert.equal(verifyFile(release.publicKey, sums, sig), true);

  // Any change to the list breaks the signature.
  const tampered = tempFile('SHA256SUMS.txt', `${'b'.repeat(64)}  sotto-windows-x64-setup.exe\n`);
  assert.equal(verifyFile(release.publicKey, tampered, sig), false);
});

test('a signature file must hold the 64 raw bytes, not their text', () => {
  const release = generateRelease();
  const sums = tempFile('SHA256SUMS.txt', `${'a'.repeat(64)}  sotto-setup.exe\n`);
  const raw = signFile(Buffer.from(release.seed, 'base64url'), sums);
  assert.equal(raw.length, 64);
  const asText = tempFile('SHA256SUMS.txt.sig', `${raw.toString('base64url')}\n`);
  assert.equal(verifyFile(release.publicKey, sums, asText), false);
});

test('the command line signs and verifies as the release workflow does', () => {
  const release = generateRelease();
  const dir = mkdtempSync(join(tmpdir(), 'sign-sums-cli-'));
  const sums = join(dir, 'SHA256SUMS.txt');
  writeFileSync(sums, `${'c'.repeat(64)}  sotto-linux-amd64.deb\n`);
  const script = fileURLToPath(new URL('./sign-sums.mjs', import.meta.url));
  const run = (args, env = {}) =>
    spawnSync(process.execPath, [script, ...args], {
      env: { ...process.env, ...env },
      encoding: 'buffer',
    });

  // The workflow redirects the signing output into SHA256SUMS.txt.sig.
  const signed = run([sums], { UPDATE_SIGNING_KEY: release.seed });
  assert.equal(signed.status, 0, String(signed.stderr));
  assert.equal(signed.stdout.length, 64);
  const sig = join(dir, 'SHA256SUMS.txt.sig');
  writeFileSync(sig, signed.stdout);

  assert.equal(run(['--verify', release.publicKey, sums, sig]).status, 0);
  writeFileSync(sums, `${'d'.repeat(64)}  sotto-linux-amd64.deb\n`);
  assert.equal(run(['--verify', release.publicKey, sums, sig]).status, 1);
});

test('the public key of a seed is the one the release publishes', () => {
  const release = generateRelease();
  assert.equal(
    publicKeyFromSeed(Buffer.from(release.seed, 'base64url')).toString('base64url'),
    release.publicKey,
  );
  // Unpadded base64url, as the app's decoder requires.
  assert.equal(release.publicKey.length, 43);
  assert.equal(release.seed.length, 43);
});

test('a seed of the wrong length is refused', () => {
  assert.throws(() => publicKeyFromSeed(Buffer.alloc(31)), /32 bytes/);
});
