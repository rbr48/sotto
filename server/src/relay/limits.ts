import { createHmac, randomBytes } from 'node:crypto';

/** Classic token bucket: `ratePerSec` sustained, bursts up to `burst`. */
export class TokenBucket {
  private tokens: number;
  private last: number;

  constructor(
    private readonly ratePerSec: number,
    private readonly burst: number,
    private readonly now: () => number = Date.now,
  ) {
    this.tokens = burst;
    this.last = now();
  }

  take(): boolean {
    const now = this.now();
    this.tokens = Math.min(this.burst, this.tokens + ((now - this.last) / 1000) * this.ratePerSec);
    this.last = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}

/**
 * Counts open connections per client address. Addresses are only kept as an
 * HMAC under a random key created at startup and never written anywhere, so
 * even a memory dump does not list raw IP addresses.
 */
export class ConnectionCounter {
  private readonly key = randomBytes(32);
  private readonly counts = new Map<string, number>();

  constructor(private readonly maxPerAddress: number) {}

  /** Returns an opaque handle, or null if the address is over its limit. */
  acquire(address: string): string | null {
    const handle = createHmac('sha256', this.key).update(address).digest('base64url');
    const count = this.counts.get(handle) ?? 0;
    if (count >= this.maxPerAddress) return null;
    this.counts.set(handle, count + 1);
    return handle;
  }

  release(handle: string): void {
    const count = (this.counts.get(handle) ?? 1) - 1;
    if (count <= 0) this.counts.delete(handle);
    else this.counts.set(handle, count);
  }
}
