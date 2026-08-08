type Window = { count: number; expiresAt: number };

/**
 * Counts failed attempts per key within a fixed window.
 *
 * State is held in memory, so each API worker enforces the limit independently. Running
 * multiple workers multiplies the effective allowance by the worker count, which still
 * bounds an attacker to a tiny fraction of the attempts a brute force needs.
 */
export class AttemptLimiter {
  private windows = new Map<string, Window>();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  /** Number of tracked keys, used to assert that expired windows are dropped. */
  get size(): number {
    return this.windows.size;
  }

  /** Seconds the caller must wait, or 0 when the attempt may proceed. */
  retryAfter(key: string, now = Date.now()): number {
    const window = this.windows.get(key);
    if (!window || window.expiresAt <= now || window.count < this.limit) {
      return 0;
    }

    return Math.max(1, Math.ceil((window.expiresAt - now) / 1000));
  }

  recordFailure(key: string, now = Date.now()): void {
    this.prune(now);

    const window = this.windows.get(key);
    if (window && window.expiresAt > now) {
      window.count++;
      return;
    }

    this.windows.set(key, { count: 1, expiresAt: now + this.windowMs });
  }

  recordSuccess(key: string): void {
    this.windows.delete(key);
  }

  private prune(now: number): void {
    for (const [key, { expiresAt }] of this.windows) {
      if (expiresAt <= now) {
        this.windows.delete(key);
      }
    }
  }
}
