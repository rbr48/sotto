/**
 * Short-lived, RAM-only holding area for envelopes addressed to someone who is
 * not connected yet (for example a phone being woken up). Envelopes are
 * dropped after `ttlMs`, and the queue is bounded per recipient and in total.
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
}

export class MessageQueue {
  private readonly byRecipient = new Map<string, QueuedMessage[]>();
  private totalBytes = 0;

  constructor(
    private readonly limits: QueueLimits,
    private readonly now: () => number = Date.now,
  ) {}

  get size(): number {
    let count = 0;
    for (const messages of this.byRecipient.values()) count += messages.length;
    return count;
  }

  /** Returns false when the message can't be held (queue full). */
  push(to: string, from: string, body: string): boolean {
    this.prune();
    const messages = this.byRecipient.get(to) ?? [];
    if (messages.length >= this.limits.maxPerRecipient) return false;
    if (this.totalBytes + body.length > this.limits.maxTotalBytes) return false;
    messages.push({ from, body, expiresAt: this.now() + this.limits.ttlMs });
    this.byRecipient.set(to, messages);
    this.totalBytes += body.length;
    return true;
  }

  /** Removes and returns everything still valid for `to`. */
  take(to: string): QueuedMessage[] {
    const messages = this.byRecipient.get(to) ?? [];
    this.byRecipient.delete(to);
    for (const message of messages) this.totalBytes -= message.body.length;
    const now = this.now();
    return messages.filter((m) => m.expiresAt > now);
  }

  prune(): void {
    const now = this.now();
    for (const [to, messages] of this.byRecipient) {
      const live = messages.filter((m) => m.expiresAt > now);
      for (const m of messages) if (m.expiresAt <= now) this.totalBytes -= m.body.length;
      if (live.length === 0) this.byRecipient.delete(to);
      else this.byRecipient.set(to, live);
    }
  }
}
