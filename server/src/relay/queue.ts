/**
 * Short-lived, RAM-only holding area for envelopes addressed to someone who is
 * not connected yet (for example a phone being woken up). Envelopes are
 * dropped after `ttlMs`.
 *
 * The queue is bounded three ways, so no single sender can fill it for
 * everyone: per recipient, per source address (the client's network address)
 * and in total.
 *
 * Expiry follows insertion order, so the oldest entries are always at the
 * front. Every operation is O(1) amortised: nothing scans the whole queue.
 */
export interface QueuedMessage {
  from: string;
  body: string;
  expiresAt: number;
}

export interface QueueLimits {
  ttlMs: number;
  maxPerRecipient: number;
  maxTotalBytes: number;
  /** Most bytes that envelopes from one source address may occupy at once. */
  maxBytesPerSource: number;
}

interface Entry extends QueuedMessage {
  readonly to: string;
  readonly source: string;
  /** Connections (by serial number) that have already been sent this envelope. */
  readonly seenBy: Set<number>;
  live: boolean;
}

export class MessageQueue {
  private readonly byRecipient = new Map<string, Entry[]>();
  /** Every entry in the order it was queued, which is also their expiry order. */
  private fifo: Entry[] = [];
  private head = 0;
  private readonly bytesBySource = new Map<string, number>();
  private totalBytes = 0;
  private count = 0;
  private latest = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly limits: QueueLimits,
    private readonly now: () => number = Date.now,
  ) {}

  get size(): number {
    return this.count;
  }

  /**
   * Holds an envelope for `to`, sent by the address `source`. Returns false
   * when it can't be held: the recipient, the source or the whole queue is
   * full.
   */
  push(to: string, from: string, body: string, source: string): boolean {
    const now = this.expire();
    const list = this.byRecipient.get(to) ?? [];
    if (list.length >= this.limits.maxPerRecipient) return false;
    if (this.totalBytes + body.length > this.limits.maxTotalBytes) return false;
    const sourceBytes = this.bytesBySource.get(source) ?? 0;
    if (sourceBytes + body.length > this.limits.maxBytesPerSource) return false;

    const entry: Entry = {
      to,
      source,
      from,
      body,
      expiresAt: now + this.limits.ttlMs,
      seenBy: new Set(),
      live: true,
    };
    list.push(entry);
    this.byRecipient.set(to, list);
    this.fifo.push(entry);
    this.totalBytes += body.length;
    this.bytesBySource.set(source, sourceBytes + body.length);
    this.count += 1;
    return true;
  }

  /**
   * The envelopes for `to` that connection `serial` has not been sent yet, and
   * marks them as sent to it. Each connection gets each envelope once, so a
   * second device that logs in while an envelope waits receives it too, as
   * live envelopes reach every connected device.
   */
  undelivered(to: string, serial: number): QueuedMessage[] {
    this.expire();
    const list = this.byRecipient.get(to);
    if (list === undefined) return [];
    const out: QueuedMessage[] = [];
    for (const entry of list) {
      if (entry.seenBy.has(serial)) continue;
      entry.seenBy.add(serial);
      out.push({ from: entry.from, body: entry.body, expiresAt: entry.expiresAt });
    }
    return out;
  }

  /** Drops everything that has expired. */
  prune(): void {
    this.expire();
  }

  /** Removes the expired entries at the front of the queue; returns the time used. */
  private expire(): number {
    // Time never runs backwards inside the queue, so a clock that steps back
    // can't give an envelope a longer life than the limit.
    const now = Math.max(this.now(), this.latest);
    this.latest = now;
    while (this.head < this.fifo.length) {
      const entry = this.fifo[this.head];
      if (entry === undefined || entry.expiresAt > now) break;
      this.head += 1;
      if (entry.live) this.remove(entry);
    }
    // Keep the array from growing without bound: drop the dead prefix once it
    // is half the array (amortised O(1) per entry).
    if (this.head > 1024 && this.head * 2 > this.fifo.length) {
      this.fifo = this.fifo.slice(this.head);
      this.head = 0;
    }
    return now;
  }

  private remove(entry: Entry): void {
    entry.live = false;
    const list = this.byRecipient.get(entry.to);
    if (list !== undefined) {
      const index = list.indexOf(entry);
      if (index >= 0) list.splice(index, 1);
      if (list.length === 0) this.byRecipient.delete(entry.to);
    }
    this.totalBytes -= entry.body.length;
    const sourceBytes = (this.bytesBySource.get(entry.source) ?? 0) - entry.body.length;
    if (sourceBytes > 0) this.bytesBySource.set(entry.source, sourceBytes);
    else this.bytesBySource.delete(entry.source);
    this.count -= 1;
  }
}
