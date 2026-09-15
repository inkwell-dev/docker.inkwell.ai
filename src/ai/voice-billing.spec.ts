import { secondsToTokens, VOICE_TOKENS_PER_MINUTE } from './voice-billing.js';

describe('secondsToTokens', () => {
  it('bills a confirmed recording at least one minute, silence included', () => {
    // A recording that was confirmed cost a Whisper call; zero would let a
    // writer probe the endpoint for free.
    expect(secondsToTokens(0)).toBe(VOICE_TOKENS_PER_MINUTE);
    expect(secondsToTokens(1)).toBe(VOICE_TOKENS_PER_MINUTE);
  });
  it('rounds up to whole minutes', () => {
    expect(secondsToTokens(60)).toBe(200);
    expect(secondsToTokens(61)).toBe(400);
    expect(secondsToTokens(300)).toBe(1000);
  });
  it('treats non-finite or negative durations as one minute', () => {
    expect(secondsToTokens(Number.NaN)).toBe(200);
    expect(secondsToTokens(-5)).toBe(200);
  });
});
