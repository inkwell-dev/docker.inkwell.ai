import { SpeechAvailability } from './speech-availability.js';

describe('SpeechAvailability', () => {
  it('probes once and memoises success', async () => {
    let calls = 0;
    const a = new SpeechAvailability(() => {
      calls++;
      return Promise.resolve();
    });
    expect(await a.check()).toBe(true);
    expect(await a.check()).toBe(true);
    expect(calls).toBe(1);
  });
  it('memoises failure too — a key that says no is not asked again', async () => {
    let calls = 0;
    const a = new SpeechAvailability(() => {
      calls++;
      return Promise.reject(new Error('429'));
    });
    expect(await a.check()).toBe(false);
    expect(await a.check()).toBe(false);
    expect(calls).toBe(1);
  });
  it('coalesces concurrent checks into one probe', async () => {
    let calls = 0;
    const a = new SpeechAvailability(
      () => new Promise((r) => setTimeout(() => (calls++, r()), 10)),
    );
    const [x, y] = await Promise.all([a.check(), a.check()]);
    expect([x, y]).toEqual([true, true]);
    expect(calls).toBe(1);
  });
  it('is false without a probe (no key configured)', async () => {
    expect(await new SpeechAvailability(null).check()).toBe(false);
  });
});
