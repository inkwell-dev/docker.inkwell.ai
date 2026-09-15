/**
 * How a recording is charged against the daily allowance.
 *
 * Whisper is metered in audio minutes, the allowance in tokens. Rather than a
 * second quota with its own indicator and its own reset, a minute of audio is
 * priced in tokens — roughly what a chat turn of the same length costs — so
 * the one number in the panel header keeps governing everything AI does.
 */
export const VOICE_TOKENS_PER_MINUTE = 200;
/** Five minutes: long enough to dictate a section, short enough to bound one call. */
export const VOICE_MAX_SECONDS = 300;
/** Opus at five minutes is ~1.5 MB; 10 MB is headroom for Safari's AAC, not a target. */
export const VOICE_MAX_BYTES = 10 * 1024 * 1024;
/** A recap is a sentence, an answer a paragraph; anything longer is not worth speaking. */
export const SPEECH_MAX_CHARS = 1000;

export const TRANSCRIPTION_MODEL = 'whisper-large-v3-turbo';
export const SPEECH_MODEL = 'gemini-2.5-flash-preview-tts';
export const SPEECH_VOICE = 'Kore';

/**
 * Tokens for a recording of `seconds`, rounded UP to whole minutes and never
 * below one minute: a confirmed recording cost a Whisper call whether or not
 * anything was said, and a free probe of the endpoint is the thing to avoid.
 */
export function secondsToTokens(seconds: number): number {
  const s = Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  return Math.max(1, Math.ceil(s / 60)) * VOICE_TOKENS_PER_MINUTE;
}
