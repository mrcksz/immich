import { AttemptLimiter } from 'src/utils/rate-limit';

describe(AttemptLimiter.name, () => {
  const now = Date.now();

  it('should allow attempts below the limit', () => {
    const sut = new AttemptLimiter(3, 1000);

    sut.recordFailure('key', now);
    sut.recordFailure('key', now);

    expect(sut.retryAfter('key', now)).toBe(0);
  });

  it('should block once the limit is reached', () => {
    const sut = new AttemptLimiter(3, 1000);

    for (let i = 0; i < 3; i++) {
      sut.recordFailure('key', now);
    }

    expect(sut.retryAfter('key', now)).toBeGreaterThan(0);
  });

  it('should track keys independently', () => {
    const sut = new AttemptLimiter(1, 1000);

    sut.recordFailure('one', now);

    expect(sut.retryAfter('one', now)).toBeGreaterThan(0);
    expect(sut.retryAfter('two', now)).toBe(0);
  });

  it('should unblock after the window expires', () => {
    const sut = new AttemptLimiter(1, 1000);

    sut.recordFailure('key', now);

    expect(sut.retryAfter('key', now + 999)).toBeGreaterThan(0);
    expect(sut.retryAfter('key', now + 1000)).toBe(0);
  });

  it('should start a fresh window after the previous one expires', () => {
    const sut = new AttemptLimiter(2, 1000);

    sut.recordFailure('key', now);
    sut.recordFailure('key', now);
    sut.recordFailure('key', now + 1000);

    expect(sut.retryAfter('key', now + 1000)).toBe(0);
  });

  it('should reset the count on success', () => {
    const sut = new AttemptLimiter(2, 1000);

    sut.recordFailure('key', now);
    sut.recordSuccess('key');
    sut.recordFailure('key', now);

    expect(sut.retryAfter('key', now)).toBe(0);
  });

  it('should round the wait up to whole seconds', () => {
    const sut = new AttemptLimiter(1, 1500);

    sut.recordFailure('key', now);

    expect(sut.retryAfter('key', now)).toBe(2);
    expect(sut.retryAfter('key', now + 1400)).toBe(1);
  });

  it('should drop expired windows instead of growing forever', () => {
    const sut = new AttemptLimiter(1, 1000);

    sut.recordFailure('stale', now);
    sut.recordFailure('fresh', now + 2000);

    expect(sut.size).toBe(1);
  });
});
