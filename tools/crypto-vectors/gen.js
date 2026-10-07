// Independent implementation of the Sotto crypto spec (docs/PROTOCOL.md) using
// libsodium-wrappers, used to produce known-answer test vectors for the Dart code.
const s = require('libsodium-wrappers');
(async () => {
  await s.ready;
  const b64 = (b) => s.to_base64(b, s.base64_variants.URLSAFE_NO_PADDING);
  const hex = (b) => s.to_hex(b);
  const cat = (...a) => { const n = a.reduce((x, y) => x + y.length, 0); const o = new Uint8Array(n); let i = 0; for (const p of a) { o.set(p, i); i += p.length; } return o; };
  const utf8 = (t) => s.from_string(t);
  const NUL = new Uint8Array([0]);
  const identity = (master) => {
    const signSeed = s.crypto_kdf_derive_from_key(32, 1, 'sottoid1', master);
    const boxSeed = s.crypto_kdf_derive_from_key(32, 2, 'sottoid1', master);
    const sign = s.crypto_sign_seed_keypair(signSeed);
    const box = s.crypto_box_seed_keypair(boxSeed);
    return { sign, box };
  };
  const masterA = Uint8Array.from({ length: 32 }, (_, i) => i);
  const masterB = Uint8Array.from({ length: 32 }, (_, i) => i + 32);
  const A = identity(masterA), B = identity(masterB);

  const cardSig = s.crypto_sign_detached(cat(utf8('sotto-card-v1'), NUL, A.sign.publicKey, A.box.publicKey), A.sign.privateKey);
  const card = JSON.stringify({ v: 1, sign: b64(A.sign.publicKey), box: b64(A.box.publicKey), sig: b64(cardSig) });

  const [lo, hi] = [A.sign.publicKey, B.sign.publicKey].sort((x, y) => s.compare(x, y));
  const h = s.crypto_generichash(64, cat(utf8('sotto-safety-v1'), NUL, lo, hi));
  const groups = [];
  for (let i = 0; i < 12; i++) {
    let v = 0n;
    for (let j = 0; j < 5; j++) v = (v << 8n) | BigInt(h[i * 5 + j]);
    groups.push(String(v % 100000n).padStart(5, '0'));
  }

  const inner = `{"v":1,"from":"${b64(A.sign.publicKey)}","fromBox":"${b64(A.box.publicKey)}","to":"${b64(B.sign.publicKey)}","ts":1791360000000,"n":"AAECAwQFBgcICQoLDA0ODw","type":"test.hello","body":{"text":"hello"}}`;
  const msgSig = s.crypto_sign_detached(cat(utf8('sotto-msg-v1'), NUL, utf8(inner)), A.sign.privateKey);
  const sealed = s.crypto_box_seal(cat(msgSig, utf8(inner)), B.box.publicKey);
  // Sanity: open it again here.
  const opened = s.crypto_box_seal_open(sealed, B.box.publicKey, B.box.privateKey);
  if (s.to_string(opened.slice(64)) !== inner) throw new Error('self-check failed');

  console.log(JSON.stringify({
    masterA: hex(masterA), masterB: hex(masterB),
    aSign: b64(A.sign.publicKey), aBox: b64(A.box.publicKey),
    bSign: b64(B.sign.publicKey), bBox: b64(B.box.publicKey),
    aCard: card,
    safetyNumber: groups.join(' '),
    inner, innerSignature: b64(msgSig), sealedAtoB: b64(sealed),
  }, null, 2));
})();
