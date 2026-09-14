# Voice Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a writer record a prompt with a microphone in the assistant dock (transcribed server-side by Groq Whisper into the editable input), and have every assistant reply read aloud by Gemini TTS behind a mute button — hidden entirely when the key has no TTS.

**Architecture:** Two new routes beside the chat stream — `POST /ai/transcribe` (multipart audio → text, billed 200 tokens/min through the existing `billAction`) and `POST /ai/speak` (text → WAV, free) — plus `GET /ai/speech-availability` backed by a memoised probe. A `VoiceService` owns the provider calls. On the client, `useVoiceInput` + `VoiceRecorderControl` sit in the dock's input row; `useSpeechOut` watches the chat's messages and plays replies through one `<audio>`; a persisted mute button sits left of the minimize chevron. The chat stream and `useAiAssistant` are untouched.

**Tech Stack:** NestJS 11 + `ai@7` (`transcribe`, `generateSpeech`) + `@ai-sdk/groq` (`whisper-large-v3-turbo`) + `@ai-sdk/google` (`gemini-2.5-flash-preview-tts`) + `@nestjs/platform-express` `FileInterceptor` (multer is nested in pnpm, no `@types/multer`) + `@nestjs/throttler`; Next.js + React 19 + `MediaRecorder` + Axios client + TanStack Query; jest (backend) and `node --test` (frontend pure modules).

**Spec:** `docs/superpowers/specs/2026-09-14-voice-assistant-design.md` (superproject). Read it first.

## Global Constraints

- **Nothing runs on the host.** Backend: `docker exec -w /app inkwell-api-1 …`; frontend: `docker exec -w /app inkwell-web-1 …`.
- **Never bare `npx jest`** — `npm test -- <path>`.
- **`ai`/`@ai-sdk/*` are ESM-only and jest cannot load them.** Backend modules that jest tests import them with `import type` only and take the provider call as an injected function.
- **Frontend pure modules** (`*.check.ts` targets): relative imports with `.ts` extension, no `@/`, no enums; run with `docker exec -w /app inkwell-web-1 node --test src/features/ai/<name>.check.ts`.
- **No attribution** in any commit, PR or comment (hook-enforced). Conventional subject + prose body on *why*.
- **Branches:** `feat/voice-assistant` (backend, frontend), `docs/voice-assistant` (spec), from up-to-date `origin/main`. Never commit to `main`.
- **Gates before every commit:** backend `npx tsc --noEmit; echo "exit: $?"`, `npm run lint`, `npm test`; frontend `npx tsc --noEmit`, `npx eslint . --max-warnings=0` (React-compiler rules on: no setState in effects, no ref reads in render; restructure, never disable). Exit codes captured explicitly.
- **Comment everything** in the house voice — *why*, not what.
- **Fixed values:** `VOICE_TOKENS_PER_MINUTE = 200`, `VOICE_MAX_SECONDS = 300`, `VOICE_MAX_BYTES = 10 * 1024 * 1024`, `SPEECH_MAX_CHARS = 1000`, speak throttle 20/min, transcription model `whisper-large-v3-turbo`, speech model `gemini-2.5-flash-preview-tts`, voice `Kore`, `ai_action_type` value `voice_transcribe` (exists; no migration).
- **Fixed copy:** "Recording too long (max 5 minutes)", "Couldn't transcribe — try again", "Microphone access was refused", "Not enough tokens to record", "Listening… speak your prompt", "Nothing heard", aria-labels "Mute the assistant's voice" / "Unmute the assistant's voice", `localStorage` key `inkwell.ai-dock.muted`.
- **Routes:** `POST /ai/transcribe` (multipart field `audio` + text field `seconds`), `POST /ai/speak` (`{ text }`), `GET /ai/speech-availability` (`{ available }`).

---

## File structure

**Backend (`src/backend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/ai/voice-billing.ts` *(new, pure)* | constants above + `secondsToTokens(seconds)` |
| `src/ai/voice-billing.spec.ts` *(new)* | jest |
| `src/ai/speech-availability.ts` *(new, pure)* | `SpeechAvailability` — memoised one-time probe around an injected `probe(): Promise<void>` |
| `src/ai/speech-availability.spec.ts` *(new)* | jest |
| `src/ai/voice.service.ts` *(new)* | `VoiceService`: own Groq/Gemini handles, `transcribe(userId, file, clientSeconds)`, `speak(text)`, `isSpeechAvailable()` |
| `src/ai/dto/speak.dto.ts` *(new)* | `SpeakDto { text }` with `@MaxLength(1000)` |
| `src/ai/ai.controller.ts` *(modify)* | three routes |
| `src/ai/ai.module.ts` *(modify)* | provide `VoiceService` |

**Frontend (`src/frontend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/features/ai/markdown-to-speech.ts` *(new, pure)* | `markdownToSpeech(md, max = 1000)` |
| `src/features/ai/markdown-to-speech.check.ts` *(new)* | node:test |
| `src/features/ai/format-seconds.ts` *(new, pure)* | `formatSeconds(n) → "m:ss"`, `VOICE_MAX_SECONDS`, `VOICE_TOKENS_PER_MINUTE` |
| `src/features/ai/format-seconds.check.ts` *(new)* | node:test |
| `src/features/ai/use-voice-input.ts` *(new)* | recorder state machine + `POST /ai/transcribe` |
| `src/features/ai/voice-recorder-control.tsx` *(new)* | mic / recording / transcribing controls |
| `src/features/ai/use-speech-out.ts` *(new)* | availability query, mute state, plays replies |
| `src/features/ai/ai-assistant-dock.tsx` *(modify)* | wire the recorder into the input row and the mute button into the header |
| `src/lib/api/query-keys.ts` *(modify)* | `qk.ai.speechAvailability()` |

**Spec (`spec.inkwell.ai`)** — Task 9.

---

### Task 0: Spike — do both providers answer on the project's keys?

Throwaway; the output is a decision. If TTS fails with a quota/permission error, the feature ships as voice input only (Tasks 6's speech half is still built — the availability flag hides it — but the browser pass records that TTS was not exercised).

**Files:** create temporarily `src/backend.inkwell.ai/probe-voice.mjs`; delete after.

- [ ] **Step 1: Write the probe**

```js
// probe-voice.mjs — THROWAWAY. Delete before committing anything.
import { transcribe, generateSpeech } from 'ai';
import { createGroq } from '@ai-sdk/groq';
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { writeFileSync } from 'node:fs';

const groq = createGroq({ apiKey: process.env.GROQ_API_KEY });
const gemini = createGoogleGenerativeAI({ apiKey: process.env.GEMINI_API_KEY });

// 1. TTS: one sentence, Kore voice.
try {
  const t0 = Date.now();
  const speech = await generateSpeech({
    model: gemini.speech('gemini-2.5-flash-preview-tts'),
    text: 'Added a heading and two short paragraphs about why Hello World matters.',
    voice: 'Kore',
  });
  writeFileSync('/tmp/probe-speech.wav', speech.audio.uint8Array);
  console.log('TTS OK', speech.audio.format, speech.audio.uint8Array.length, 'bytes', Date.now() - t0, 'ms', 'warnings:', speech.warnings.length);
} catch (e) {
  console.log('TTS FAIL', e?.statusCode ?? '', String(e?.message ?? e).slice(0, 300));
}

// 2. STT: round-trip the WAV we just made (if TTS worked) — Whisper should
//    transcribe the sentence back. If TTS failed, synthesize 1 s of silence.
let audio;
try { audio = (await import('node:fs')).readFileSync('/tmp/probe-speech.wav'); }
catch { audio = Buffer.concat([Buffer.from('RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80>\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00', 'latin1'), Buffer.alloc(16000)]); }
try {
  const t0 = Date.now();
  const r = await transcribe({ model: groq.transcription('whisper-large-v3-turbo'), audio });
  console.log('STT OK', JSON.stringify(r.text), 'duration:', r.durationInSeconds, 'lang:', r.language, Date.now() - t0, 'ms');
} catch (e) {
  console.log('STT FAIL', e?.statusCode ?? '', String(e?.message ?? e).slice(0, 300));
}
```

- [ ] **Step 2: Run it**

Run: `docker exec -w /app inkwell-api-1 node probe-voice.mjs`
Expected: `TTS OK wav <bytes> …` and `STT OK "Added a heading and two short paragraphs about why Hello World matters." duration: ~4 …`. Record the exact output.

- [ ] **Step 3: Decide and record**

- Both OK → continue as planned.
- STT FAIL → stop; the feature cannot ship. Report the error verbatim.
- TTS FAIL (429 / quota / model not found) → continue; the availability flag will be `false` on this key. Note it for the PR body and the browser pass. Try `gemini-3.1-flash-tts-preview` once as an alternative model id and record whether it differs.

- [ ] **Step 4: Delete the probe and the WAV**

Run: `rm src/backend.inkwell.ai/probe-voice.mjs; docker exec inkwell-api-1 rm -f /tmp/probe-speech.wav; git -C src/backend.inkwell.ai status --short`
Expected: clean.

---

### Task 1: Branches and baselines

- [ ] **Step 1:** For `src/backend.inkwell.ai` and `src/frontend.inkwell.ai`: `git fetch -q origin && git checkout -q -b feat/voice-assistant origin/main`. For `spec.inkwell.ai`: `git checkout -q -b docs/voice-assistant origin/main`.
- [ ] **Step 2:** Baselines with explicit exit codes: api `npx tsc --noEmit`, `npm run lint`; web `npx tsc --noEmit`, `npx eslint . --max-warnings=0`. Expected all 0.

---

### Task 2: Backend pure modules — billing and availability

**Files:**
- Create: `src/ai/voice-billing.ts`, `src/ai/voice-billing.spec.ts`, `src/ai/speech-availability.ts`, `src/ai/speech-availability.spec.ts`

**Interfaces:**
- Produces: `VOICE_TOKENS_PER_MINUTE`, `VOICE_MAX_SECONDS`, `VOICE_MAX_BYTES`, `SPEECH_MAX_CHARS`, `TRANSCRIPTION_MODEL`, `SPEECH_MODEL`, `SPEECH_VOICE`, `secondsToTokens(seconds: number): number`; `class SpeechAvailability { constructor(probe: () => Promise<void>); check(): Promise<boolean> }`.

- [ ] **Step 1: Failing specs**

`src/ai/voice-billing.spec.ts`:
```ts
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
```

`src/ai/speech-availability.spec.ts`:
```ts
import { SpeechAvailability } from './speech-availability.js';

describe('SpeechAvailability', () => {
  it('probes once and memoises success', async () => {
    let calls = 0;
    const a = new SpeechAvailability(async () => void calls++);
    expect(await a.check()).toBe(true);
    expect(await a.check()).toBe(true);
    expect(calls).toBe(1);
  });
  it('memoises failure too — a key that says no is not asked again', async () => {
    let calls = 0;
    const a = new SpeechAvailability(async () => {
      calls++;
      throw new Error('429');
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
```

- [ ] **Step 2:** `docker exec -w /app inkwell-api-1 npm test -- src/ai/voice-billing.spec.ts src/ai/speech-availability.spec.ts` → FAIL (modules missing).

- [ ] **Step 3: Implement**

`src/ai/voice-billing.ts`:
```ts
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
```

`src/ai/speech-availability.ts`:
```ts
/**
 * Whether the configured key can synthesise speech — asked once per process.
 *
 * The Gemini free tier has granted this project a quota of zero before
 * (`ai.service.ts` records the history), and a key that answers 429 for the
 * day should not be asked again on every panel open. So the probe runs on the
 * first check, and both outcomes are remembered until the process restarts.
 * Concurrent first checks share one in-flight probe.
 *
 * The probe itself is injected: it calls `generateSpeech` in production, which
 * jest cannot load (ESM-only), and a stub in the spec.
 */
export class SpeechAvailability {
  private result: boolean | null = null;
  private inflight: Promise<boolean> | null = null;

  constructor(private readonly probe: (() => Promise<void>) | null) {}

  check(): Promise<boolean> {
    if (this.result !== null) return Promise.resolve(this.result);
    if (!this.probe) return Promise.resolve((this.result = false));
    if (!this.inflight) {
      this.inflight = this.probe()
        .then(() => true)
        .catch(() => false)
        .then((ok) => {
          this.result = ok;
          this.inflight = null;
          return ok;
        });
    }
    return this.inflight;
  }
}
```

- [ ] **Step 4:** Re-run the two specs → PASS (7 tests).
- [ ] **Step 5:** Gates (`tsc`, `lint`) 0; commit:
```
feat(ai): voice billing rule and a memoised speech-availability probe

A minute of audio is priced in tokens so the one daily allowance keeps
governing everything the assistant does, and a key that cannot speak is asked
once per process rather than on every panel open. Both are pure so jest can
cover them without loading the ESM-only ai package.
```

---

### Task 3: `VoiceService`, DTO, routes

**Files:**
- Create: `src/ai/voice.service.ts`, `src/ai/dto/speak.dto.ts`
- Modify: `src/ai/ai.controller.ts`, `src/ai/ai.module.ts`

**Interfaces:**
- Consumes: Task 2 exports; `AiService.billAction(userId, actionType, input, output, tokensUsed, model)` (public, existing); `requireNonEmpty(config, 'GROQ_API_KEY')`; `ConfigService`.
- Produces: `VoiceService.transcribe(userId: string, file: UploadedAudio, clientSeconds: number): Promise<{ text: string; seconds: number; tokensUsed: number }>`, `VoiceService.speak(text: string): Promise<{ bytes: Uint8Array; mediaType: string }>`, `VoiceService.isSpeechAvailable(): Promise<boolean>`; type `UploadedAudio = { buffer: Buffer; mimetype: string; size: number }`.

- [ ] **Step 1: DTO**

`src/ai/dto/speak.dto.ts`:
```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsString, MaxLength, MinLength } from 'class-validator';
import { SPEECH_MAX_CHARS } from '../voice-billing.js';

// What the dock asks to have read aloud: the assistant's text with Markdown
// already stripped client-side. Capped because a recap is a sentence and an
// answer a paragraph — a whole article read aloud is a different feature.
export class SpeakDto {
  @ApiProperty({ example: 'Added a heading and two short paragraphs about why Hello World matters.' })
  @IsString()
  @MinLength(1)
  @MaxLength(SPEECH_MAX_CHARS)
  text!: string;
}
```

- [ ] **Step 2: The service**

`src/ai/voice.service.ts`:
```ts
import {
  Injectable,
  Logger,
  PayloadTooLargeException,
  ServiceUnavailableException,
  BadRequestException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { transcribe, generateSpeech } from 'ai';
import { createGroq } from '@ai-sdk/groq';
import { createGoogleGenerativeAI, type GoogleGenerativeAIProvider } from '@ai-sdk/google';
import { requireNonEmpty } from '../common/utils/require-non-empty.js';
import { AiService } from './ai.service.js';
import { SpeechAvailability } from './speech-availability.js';
import {
  secondsToTokens,
  SPEECH_MODEL,
  SPEECH_VOICE,
  TRANSCRIPTION_MODEL,
  VOICE_MAX_BYTES,
  VOICE_MAX_SECONDS,
} from './voice-billing.js';

/** The slice of multer's file object this service reads. Typed structurally
 *  because `@types/multer` is not installed and one field shape is not worth
 *  a dependency. */
export interface UploadedAudio {
  buffer: Buffer;
  mimetype: string;
  size: number;
}

const ACCEPTED_AUDIO = ['audio/webm', 'audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/wav', 'audio/x-wav'];

export const RECORDING_TOO_LONG = 'Recording too long (max 5 minutes)';
export const TRANSCRIBE_FAILED = "Couldn't transcribe — try again";

/**
 * Voice in, voice out: Whisper for the writer's recording, Gemini TTS for the
 * assistant's reply.
 *
 * Its own provider handles rather than AiService's private ones, built by the
 * same rules that file explains at length: Groq is required at boot, Gemini is
 * optional and read per call so a missing key can never stop the process.
 */
@Injectable()
export class VoiceService {
  private readonly logger = new Logger(VoiceService.name);
  private readonly groq;
  private geminiClient: GoogleGenerativeAIProvider | null = null;
  private readonly availability: SpeechAvailability;

  constructor(
    private readonly config: ConfigService,
    private readonly ai: AiService,
  ) {
    this.groq = createGroq({ apiKey: requireNonEmpty(config, 'GROQ_API_KEY') });
    // The probe is the smallest real call: if the key cannot say "ready", it
    // cannot read a recap either, and the mute button should not exist.
    const gemini = this.gemini();
    this.availability = new SpeechAvailability(
      gemini
        ? async () => {
            await generateSpeech({ model: gemini.speech(SPEECH_MODEL), text: 'ready', voice: SPEECH_VOICE });
          }
        : null,
    );
  }

  private gemini(): GoogleGenerativeAIProvider | null {
    if (this.geminiClient) return this.geminiClient;
    const apiKey = this.config.get<string>('GEMINI_API_KEY');
    if (!apiKey?.trim()) return null;
    this.geminiClient = createGoogleGenerativeAI({ apiKey });
    return this.geminiClient;
  }

  isSpeechAvailable(): Promise<boolean> {
    return this.availability.check();
  }

  /**
   * Transcribes one recording and bills it.
   *
   * The client's `seconds` is checked up front so an over-long recording is
   * refused before a Whisper call is spent; billing prefers the provider's own
   * duration when it reports one, because that is the figure a client cannot
   * shade. Silence is billed: the call happened.
   */
  async transcribe(userId: string, file: UploadedAudio, clientSeconds: number) {
    if (!file?.buffer?.length) throw new BadRequestException('No audio received');
    if (!ACCEPTED_AUDIO.some((t) => file.mimetype.startsWith(t))) {
      throw new BadRequestException(`Unsupported audio type: ${file.mimetype}`);
    }
    if (file.size > VOICE_MAX_BYTES || clientSeconds > VOICE_MAX_SECONDS) {
      throw new PayloadTooLargeException(RECORDING_TOO_LONG);
    }

    let text: string;
    let seconds = clientSeconds;
    try {
      const result = await transcribe({
        model: this.groq.transcription(TRANSCRIPTION_MODEL),
        audio: file.buffer,
      });
      text = result.text.trim();
      if (typeof result.durationInSeconds === 'number' && result.durationInSeconds > 0) {
        seconds = Math.min(result.durationInSeconds, VOICE_MAX_SECONDS);
      }
    } catch (error) {
      this.logger.error(
        `Transcription failed (userId=${userId}, ${file.size} bytes): ${error instanceof Error ? error.message : String(error)}`,
      );
      throw new ServiceUnavailableException(TRANSCRIBE_FAILED);
    }

    const tokensUsed = secondsToTokens(seconds);
    await this.ai.billAction(
      userId,
      'voice_transcribe',
      `[voice] ${Math.round(seconds)}s`,
      text,
      tokensUsed,
      TRANSCRIPTION_MODEL,
    );
    return { text, seconds: Math.round(seconds), tokensUsed };
  }

  /** One sentence to WAV. Free to the writer; throttled at the route. */
  async speak(text: string): Promise<{ bytes: Uint8Array; mediaType: string }> {
    const gemini = this.gemini();
    if (!gemini || !(await this.availability.check())) {
      throw new ServiceUnavailableException('Speech is not available');
    }
    try {
      const result = await generateSpeech({ model: gemini.speech(SPEECH_MODEL), text, voice: SPEECH_VOICE });
      return { bytes: result.audio.uint8Array, mediaType: result.audio.mediaType ?? 'audio/wav' };
    } catch (error) {
      this.logger.warn(`Speech failed: ${error instanceof Error ? error.message : String(error)}`);
      throw new ServiceUnavailableException('Speech is not available');
    }
  }
}
```
If `GeneratedAudioFile` has no `mediaType` in the installed typings, use `result.audio.format === 'mp3' ? 'audio/mpeg' : 'audio/wav'`.

- [ ] **Step 3: Routes**

In `ai.controller.ts`, add imports `UploadedFile, UseInterceptors, Res, HttpCode, Post, Get, Body` (those not already there), `FileInterceptor` from `@nestjs/platform-express`, `Throttle` from `@nestjs/throttler`, `VoiceService`, `SpeakDto`, `VOICE_MAX_BYTES` from `./voice-billing.js`, and inject `private voice: VoiceService` in the constructor. Add, after the `tokens` route:

```ts
  // A recording in, its transcript out. Quota-guarded like every action that
  // spends tokens; multer keeps the file in memory (a five-minute recording is
  // a couple of megabytes) and refuses anything above the byte cap before the
  // handler runs.
  @Post('transcribe')
  @UseGuards(JwtAuthGuard, AiQuotaGuard)
  @UseInterceptors(FileInterceptor('audio', { limits: { fileSize: VOICE_MAX_BYTES, files: 1 } }))
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Transcribe a recorded prompt (Whisper); billed per minute' })
  async transcribe(
    @CurrentUser() user: JwtPayload,
    @UploadedFile() file: UploadedAudio,
    @Body('seconds') seconds: string,
  ) {
    return this.voice.transcribe(user.sub, file, Number(seconds) || 0);
  }

  // The assistant's reply as audio. Free to the writer, so it carries a
  // per-user rate limit instead of the quota guard: a loop must not be able
  // to spend the key's daily speech allowance.
  @Post('speak')
  @UseGuards(JwtAuthGuard)
  @Throttle({ default: { ttl: 60_000, limit: 20 } })
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Read a short assistant reply aloud (Gemini TTS)' })
  async speak(@Body() dto: SpeakDto, @Res() res: Response) {
    const { bytes, mediaType } = await this.voice.speak(dto.text);
    res.setHeader('content-type', mediaType);
    res.setHeader('cache-control', 'no-store');
    res.end(Buffer.from(bytes));
  }

  // Whether the mute button should exist at all.
  @Get('speech-availability')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: 'Whether speech output is configured and answering' })
  async speechAvailability() {
    return { available: await this.voice.isSpeechAvailable() };
  }
```
Import `UploadedAudio` from `./voice.service.js`. In `ai.module.ts` add `VoiceService` to `providers`.

- [ ] **Step 4: Gates**

`npx tsc --noEmit; echo "exit: $?"` — if `FileInterceptor` typing complains about `UploadedAudio`, keep the structural type and cast at the decorator boundary (`@UploadedFile() file: UploadedAudio` is a parameter type only; Nest passes multer's object). `npm run lint`, then full `npm test` — all 0. `docker logs --tail 5 inkwell-api-1` clean.

- [ ] **Step 5: Live check (controller runs it — needs a bearer token from the signed-in page; never handled by a subagent).** From the browser page: `POST /api/ai/speech-availability` → `{ available: true|false }` consistent with Task 0; `POST /api/ai/speak` with `{ text: "ready" }` → 200 and `audio/wav` bytes (or 503 if unavailable); `POST /api/ai/transcribe` with a 1-second silent WAV blob built in the page → 200 `{ text: "", seconds, tokensUsed: 200 }`, `ai_interactions` row `voice_transcribe`, balance −200. Restore the balance; delete the row.

- [ ] **Step 6: Commit**
```
feat(ai): transcribe a recorded prompt and speak a reply

POST /ai/transcribe takes the dock's recording, runs Whisper and bills it at
the minute rate through the same path every AI action uses; POST /ai/speak
turns a reply into audio, free to the writer and rate-limited instead;
GET /ai/speech-availability says whether the key can speak at all, so the
client can hide the mute button rather than ship a voice that fails.
```

---

### Task 4: Frontend pure modules — `markdownToSpeech`, `formatSeconds`

**Files:** create `src/features/ai/markdown-to-speech.ts`, `markdown-to-speech.check.ts`, `format-seconds.ts`, `format-seconds.check.ts`.

**Interfaces:** `markdownToSpeech(md: string, max?: number): string`; `formatSeconds(n: number): string`; `VOICE_MAX_SECONDS = 300`, `VOICE_TOKENS_PER_MINUTE = 200`.

- [ ] **Step 1: Failing checks**

`markdown-to-speech.check.ts`:
```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/markdown-to-speech.check.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { markdownToSpeech } from './markdown-to-speech.ts';

test('strips heading markers and emphasis', () => {
  assert.equal(markdownToSpeech('## Why it matters\n\nIt **really** does, *a lot*.'), 'Why it matters. It really does, a lot.');
});
test('reads a list as sentences', () => {
  assert.equal(markdownToSpeech('- first point\n- second point'), 'first point. second point.');
});
test('drops link targets and code marks', () => {
  assert.equal(markdownToSpeech('See [the docs](https://x.y) and `print()`.'), 'See the docs and print().');
});
test('collapses whitespace and caps the length on a word boundary', () => {
  const long = 'word '.repeat(400);
  const out = markdownToSpeech(long, 50);
  assert.ok(out.length <= 50, out.length.toString());
  assert.ok(!out.endsWith(' '));
});
test('empty in, empty out', () => {
  assert.equal(markdownToSpeech('   '), '');
});
```

`format-seconds.check.ts`:
```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/format-seconds.check.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatSeconds, VOICE_MAX_SECONDS, VOICE_TOKENS_PER_MINUTE } from './format-seconds.ts';

test('m:ss with zero padding', () => {
  assert.equal(formatSeconds(0), '0:00');
  assert.equal(formatSeconds(9), '0:09');
  assert.equal(formatSeconds(65), '1:05');
  assert.equal(formatSeconds(300), '5:00');
});
test('constants match the API', () => {
  assert.equal(VOICE_MAX_SECONDS, 300);
  assert.equal(VOICE_TOKENS_PER_MINUTE, 200);
});
```

- [ ] **Step 2:** Run both → import failures.

- [ ] **Step 3: Implement**

`markdown-to-speech.ts`:
```ts
/**
 * Turns the assistant's Markdown into something a voice can read.
 *
 * A TTS model reads what it is given: "asterisk asterisk really asterisk
 * asterisk" is the failure this exists to prevent. Structure becomes sentence
 * breaks — a heading or a list item ends with a period — and everything that
 * is markup rather than words is dropped.
 *
 * No `@/` imports and no enums: exercised by `node --test`.
 */
export function markdownToSpeech(md: string, max = 1000): string {
  const lines = md
    .replace(/```[\s\S]*?```/g, ' ')
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0)
    .map((l) =>
      l
        .replace(/^#{1,6}\s+/, '')
        .replace(/^(?:[-*+]|\d+[.)])\s+/, '')
        .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
        .replace(/`([^`]*)`/g, '$1')
        .replace(/(\*\*|__)(.*?)\1/g, '$2')
        .replace(/(\*|_)(.*?)\1/g, '$2')
        .replace(/^>\s?/, '')
        .trim(),
    )
    .filter((l) => l.length > 0)
    .map((l) => (/[.!?…:]$/.test(l) ? l : `${l}.`));

  let text = lines.join(' ').replace(/\s+/g, ' ').trim();
  if (text.length > max) {
    text = text.slice(0, max);
    const cut = text.lastIndexOf(' ');
    if (cut > 0) text = text.slice(0, cut);
  }
  return text;
}
```

`format-seconds.ts`:
```ts
/** Mirrors the API's voice-billing constants; the check above pins them. */
export const VOICE_MAX_SECONDS = 300;
export const VOICE_TOKENS_PER_MINUTE = 200;

/** `m:ss` for the recording timer. */
export function formatSeconds(n: number): string {
  const s = Math.max(0, Math.floor(n));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
```

- [ ] **Step 4:** Run both checks → 7 pass. Adjust the emphasis regexes only if a listed case fails; do not change the cases.
- [ ] **Step 5:** Gates (web `tsc`, `eslint`) 0; commit:
```
feat(ai): markdown-to-speech and a recording timer formatter

A voice reads what it is given, so the assistant's Markdown becomes plain
sentences before it is spoken. Pure, so node --test covers it.
```

---

### Task 5: Voice input — hook, control, dock wiring

**Files:**
- Create: `src/features/ai/use-voice-input.ts`, `src/features/ai/voice-recorder-control.tsx`
- Modify: `src/features/ai/ai-assistant-dock.tsx` (input row)

**Interfaces:**
- Consumes: `formatSeconds`, `VOICE_MAX_SECONDS`, `VOICE_TOKENS_PER_MINUTE` (Task 4); `api` (Axios client, `@/lib/api/client`); `qk.ai.tokens()`; `useAiQuota()` (`remaining`, `exhausted`); `toast` (sonner).
- Produces: `useVoiceInput({ onTranscript }) → { state: 'idle'|'recording'|'transcribing', seconds, start(), confirm(), cancel(), retry(): boolean }`; `<VoiceRecorderControl disabled disabledReason onTranscript />`.

- [ ] **Step 1: The hook**

`use-voice-input.ts`:
```ts
'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { api } from '@/lib/api/client';
import { qk } from '@/lib/api/query-keys';
import { VOICE_MAX_SECONDS } from './format-seconds';

export type VoiceInputState = 'idle' | 'recording' | 'transcribing';

interface TranscribeResponse {
  text: string;
  seconds: number;
  tokensUsed: number;
}

/**
 * The recorder behind the microphone button.
 *
 * One `MediaRecorder` per recording, one Blob on stop, one POST. The audio is
 * kept in memory after a provider failure so "try again" does not mean
 * "say it again"; it is dropped on cancel, on success, and on the two errors
 * that a retry cannot fix (too long, no tokens). Goes through the Axios client
 * so the 401 refresh interceptor applies — the chat transport has none.
 */
export function useVoiceInput({ onTranscript }: { onTranscript: (text: string) => void }) {
  const queryClient = useQueryClient();
  const [state, setState] = useState<VoiceInputState>('idle');
  const [seconds, setSeconds] = useState(0);
  const recorder = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);
  const lastAudio = useRef<{ blob: Blob; seconds: number } | null>(null);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  const startedAt = useRef(0);

  const stopTracks = () => {
    recorder.current?.stream.getTracks().forEach((t) => t.stop());
    recorder.current = null;
    if (timer.current) clearInterval(timer.current);
    timer.current = null;
  };

  const send = useCallback(
    async (blob: Blob, secs: number) => {
      setState('transcribing');
      const form = new FormData();
      form.append('audio', blob, `prompt.${blob.type.includes('mp4') ? 'm4a' : 'webm'}`);
      form.append('seconds', String(secs));
      try {
        const { data } = await api.post<TranscribeResponse>('/ai/transcribe', form);
        lastAudio.current = null;
        if (data.text) onTranscript(data.text);
        else toast.message('Nothing heard');
      } catch (error: unknown) {
        const status = (error as { response?: { status?: number; data?: { message?: string } } }).response?.status;
        const message =
          (error as { response?: { data?: { message?: string } } }).response?.data?.message ??
          "Couldn't transcribe — try again";
        // 413 and 403 cannot be fixed by retrying the same audio.
        if (status === 413 || status === 403) lastAudio.current = null;
        else lastAudio.current = { blob, seconds: secs };
        toast.error(message);
      } finally {
        void queryClient.invalidateQueries({ queryKey: qk.ai.tokens() });
        setState('idle');
        setSeconds(0);
      }
    },
    [onTranscript, queryClient],
  );

  const finish = useCallback(
    (confirm: boolean) => {
      const r = recorder.current;
      if (!r) return;
      const secs = Math.round((Date.now() - startedAt.current) / 1000);
      r.onstop = () => {
        const blob = new Blob(chunks.current, { type: r.mimeType || 'audio/webm' });
        chunks.current = [];
        stopTracks();
        if (confirm) void send(blob, secs);
        else {
          setState('idle');
          setSeconds(0);
        }
      };
      r.stop();
    },
    [send],
  );

  const start = useCallback(async () => {
    if (recorder.current) return;
    let stream: MediaStream;
    try {
      // Asked on the first click only — never on page load.
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      toast.error('Microphone access was refused');
      return;
    }
    const r = new MediaRecorder(stream);
    recorder.current = r;
    chunks.current = [];
    r.ondataavailable = (e) => {
      if (e.data.size > 0) chunks.current.push(e.data);
    };
    startedAt.current = Date.now();
    setSeconds(0);
    setState('recording');
    r.start(1000);
    timer.current = setInterval(() => {
      const s = Math.round((Date.now() - startedAt.current) / 1000);
      setSeconds(s);
      // The cap is enforced here, not only on the server: a 413 after five
      // minutes of speaking would throw the words away.
      if (s >= VOICE_MAX_SECONDS) finish(true);
    }, 250);
  }, [finish]);

  const confirm = useCallback(() => finish(true), [finish]);
  const cancel = useCallback(() => finish(false), [finish]);

  /** Re-sends the last failed audio; false when there is nothing to retry. */
  const retry = useCallback((): boolean => {
    const last = lastAudio.current;
    if (!last || state !== 'idle') return false;
    void send(last.blob, last.seconds);
    return true;
  }, [send, state]);

  // Unmount mid-recording: release the microphone; nothing was sent.
  useEffect(() => () => stopTracks(), []);

  return { state, seconds, start, confirm, cancel, retry };
}
```
The React-compiler lint rules: `stopTracks` reads refs inside callbacks/effects only; the cleanup effect returning `stopTracks` is fine. If `useEffect(() => () => stopTracks(), [])` is flagged for a missing dep, wrap `stopTracks` in `useCallback` with `[]`.

- [ ] **Step 2: The control**

`voice-recorder-control.tsx`:
```tsx
'use client';

import { Check, Loader2, Mic, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { formatSeconds } from './format-seconds';
import { useVoiceInput } from './use-voice-input';

interface VoiceRecorderControlProps {
  /** Same rule as the input: streaming, exhausted, or a write awaiting a decision. */
  disabled: boolean;
  /** Why, for the tooltip — the input's placeholder reason or "Not enough tokens to record". */
  disabledReason?: string;
  onTranscript: (text: string) => void;
  /** Lets the dock swap its Send button for the confirm/cancel pair while recording. */
  onStateChange?: (recording: boolean) => void;
}

/**
 * The microphone and its two recording-time controls.
 *
 * Idle: a mic. Recording: a red pulsing dot with the timer, plus a check mark
 * (confirm → transcribe) and an × (cancel → nothing sent). Transcribing: the
 * check mark spins and both are disabled. The transcript never goes anywhere
 * but the input, editable — the writer presses Enter, not the recorder.
 */
export function VoiceRecorderControl({ disabled, disabledReason, onTranscript, onStateChange }: VoiceRecorderControlProps) {
  const { state, seconds, start, confirm, cancel } = useVoiceInput({ onTranscript });
  onStateChange?.(state !== 'idle');

  if (state === 'idle') {
    return (
      <Button
        type="button"
        size="icon"
        variant="outline"
        aria-label="Record a prompt"
        title={disabled ? disabledReason : 'Record a prompt'}
        disabled={disabled}
        onClick={() => void start()}
      >
        <Mic className="h-4 w-4" />
      </Button>
    );
  }

  const transcribing = state === 'transcribing';
  return (
    <div className="flex items-center gap-1" role="group" aria-label="Recording">
      <span className="flex items-center gap-1.5 px-2 text-xs tabular-nums text-muted-foreground">
        <span
          aria-hidden="true"
          className={cn('h-2 w-2 rounded-full bg-destructive', !transcribing && 'animate-pulse')}
        />
        {formatSeconds(seconds)}
      </span>
      <Button type="button" size="icon" aria-label="Use this recording" disabled={transcribing} onClick={confirm}>
        {transcribing ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />}
      </Button>
      <Button type="button" size="icon" variant="ghost" aria-label="Discard this recording" disabled={transcribing} onClick={cancel}>
        <X className="h-4 w-4" />
      </Button>
    </div>
  );
}
```
`onStateChange?.(…)` during render is a parent callback, not setState; if the lint rule flags calling a prop during render, move it to `useEffect(() => onStateChange?.(state !== 'idle'), [state, onStateChange])` — that is a prop callback in an effect, which is allowed.

- [ ] **Step 3: Dock wiring**

In `ai-assistant-dock.tsx`:
- `import { VoiceRecorderControl } from './voice-recorder-control';` and `import { VOICE_TOKENS_PER_MINUTE } from './format-seconds';`
- `const { exhausted, remaining } = useAiQuota();` (already destructures `exhausted`).
- State `const [recording, setRecording] = useState(false);`
- `const canRecord = !inputDisabled && (remaining ?? 0) >= VOICE_TOKENS_PER_MINUTE;` and `const recordReason = inputDisabled ? placeholder : 'Not enough tokens to record';`
- The input's placeholder while recording: `recording ? 'Listening… speak your prompt' : placeholder`; the input is `readOnly` while `recording`.
- In the form, before `<Input>`: `<VoiceRecorderControl disabled={!canRecord} disabledReason={recordReason} onStateChange={setRecording} onTranscript={(text) => setInput((prev) => (prev.trim() ? `${prev.trimEnd()} ${text}` : text))} />`. After a transcript lands, focus the input and put the cursor at the end: keep a `ref` on the `Input` and in `onTranscript` call `requestAnimationFrame(() => { const el = inputRef.current; if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length); } })`.
- While `recording`, do not render the Send/Stop button (the recorder shows check/×); otherwise unchanged.

- [ ] **Step 4:** Gates 0; `docker logs --tail 5 inkwell-web-1` clean. Commit:
```
feat(ai): record a prompt with the microphone and transcribe it into the input

A mic beside the input records through MediaRecorder; the check mark sends
the audio to Whisper and the transcript lands in the input, editable — the
writer still presses Enter. Refused below one minute's worth of tokens so a
recording never ends in a quota error after the writer has spoken.
```

---

### Task 6: Speech out — availability, mute button, playback

**Files:**
- Create: `src/features/ai/use-speech-out.ts`
- Modify: `src/lib/api/query-keys.ts`, `src/features/ai/ai-assistant-dock.tsx` (header + effect)

**Interfaces:**
- Consumes: `markdownToSpeech` (Task 4); `api`; the dock's `messages` and `status` from `useAiAssistant`.
- Produces: `useSpeechOut({ messages, status }) → { available: boolean; muted: boolean; toggleMuted(): void; pending: boolean; playPending(): void; stop(): void }`.

- [ ] **Step 1:** In `query-keys.ts` under `ai`: `speechAvailability: () => [...qk.ai.all, 'speech-availability'] as const,` with a comment.

- [ ] **Step 2: The hook**

`use-speech-out.ts`:
```ts
'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { UIMessage } from 'ai';
import { api } from '@/lib/api/client';
import { qk } from '@/lib/api/query-keys';
import { markdownToSpeech } from './markdown-to-speech';

const MUTED_KEY = 'inkwell.ai-dock.muted';

function readMuted(): boolean {
  try {
    return typeof window !== 'undefined' && localStorage.getItem(MUTED_KEY) === '1';
  } catch {
    return false;
  }
}

function messageText(m: UIMessage): string {
  return m.parts
    .filter((p): p is { type: 'text'; text: string } => p.type === 'text')
    .map((p) => p.text)
    .join('');
}

/**
 * Reads each new assistant reply aloud, unless muted or unavailable.
 *
 * Watches the chat's messages rather than hooking the transport: when `status`
 * returns to 'ready' and the last message is an assistant one we have not
 * spoken yet, it asks `/ai/speak` and plays the result through one `<audio>`
 * it owns. A new reply, a Stop, or muting ends playback at once. Minimizing
 * does not — the point is to keep working while it talks.
 *
 * Silence on failure is deliberate: the text is already on screen. The one
 * exception is a browser refusing autoplay, which is surfaced as `pending`
 * so the speaker button can offer a click to play.
 */
export function useSpeechOut({ messages, status }: { messages: UIMessage[]; status: string }) {
  const { data } = useQuery({
    queryKey: qk.ai.speechAvailability(),
    queryFn: async () => (await api.get<{ available: boolean }>('/ai/speech-availability')).data,
    staleTime: Infinity,
  });
  const available = data?.available === true;

  const [muted, setMuted] = useState(readMuted);
  const [pending, setPending] = useState(false);
  const audio = useRef<HTMLAudioElement | null>(null);
  const spoken = useRef<Set<string>>(new Set());
  const controller = useRef<AbortController | null>(null);
  const pendingUrl = useRef<string | null>(null);

  const stop = useCallback(() => {
    controller.current?.abort();
    controller.current = null;
    if (audio.current) {
      audio.current.pause();
      audio.current.src = '';
    }
    if (pendingUrl.current) URL.revokeObjectURL(pendingUrl.current);
    pendingUrl.current = null;
    setPending(false);
  }, []);

  const play = useCallback(async (url: string) => {
    if (!audio.current) audio.current = new Audio();
    audio.current.src = url;
    try {
      await audio.current.play();
      setPending(false);
    } catch {
      // Autoplay refused: keep the audio and let the button offer it.
      pendingUrl.current = url;
      setPending(true);
    }
  }, []);

  // Speak the newest settled reply once. `status` is a dependency so the effect
  // fires when streaming ends; the Set keeps a re-render from speaking twice.
  useEffect(() => {
    if (status !== 'ready' || muted || !available) return;
    const last = messages[messages.length - 1];
    if (!last || last.role !== 'assistant' || spoken.current.has(last.id)) return;
    const text = markdownToSpeech(messageText(last));
    if (!text) return;
    spoken.current.add(last.id);

    stop();
    const ac = new AbortController();
    controller.current = ac;
    const timeout = setTimeout(() => ac.abort(), 8000);
    void api
      .post<Blob>('/ai/speak', { text }, { responseType: 'blob', signal: ac.signal })
      .then(({ data: blob }) => {
        if (ac.signal.aborted) return;
        void play(URL.createObjectURL(blob));
      })
      .catch(() => {
        /* silent by design */
      })
      .finally(() => clearTimeout(timeout));
  }, [messages, status, muted, available, stop, play]);

  const toggleMuted = useCallback(() => {
    setMuted((m) => {
      const next = !m;
      try {
        localStorage.setItem(MUTED_KEY, next ? '1' : '0');
      } catch {
        /* ignore */
      }
      if (next) stop();
      return next;
    });
  }, [stop]);

  const playPending = useCallback(() => {
    if (pendingUrl.current) void play(pendingUrl.current);
  }, [play]);

  // Release the audio element with the dock.
  useEffect(() => () => stop(), [stop]);

  return { available, muted, toggleMuted, pending, playPending, stop };
}
```
`setPending` inside `play` is called from a promise continuation, not synchronously in an effect; `spoken.current` is read only inside the effect. If `useState(readMuted)` is flagged for a ref-like read, keep it — it is a lazy initializer, the sanctioned form.

- [ ] **Step 3: Dock wiring**

In `ai-assistant-dock.tsx`:
- `const speech = useSpeechOut({ messages, status });`
- In the header's button group, **before** the Minimize button: when `speech.available`, render
  ```tsx
  <Button
    variant="ghost"
    size="icon-sm"
    aria-pressed={speech.muted}
    aria-label={speech.muted ? "Unmute the assistant's voice" : "Mute the assistant's voice"}
    title={speech.pending ? 'Click to play the reply' : undefined}
    onClick={speech.pending ? speech.playPending : speech.toggleMuted}
  >
    {speech.muted ? <VolumeX /> : speech.pending ? <Play /> : <Volume2 />}
  </Button>
  ```
  (`Volume2`, `VolumeX`, `Play` from `lucide-react` — verify the names exist in the installed version.)
- Call `speech.stop()` at the top of `handleSubmit` when a send goes out, and in the Stop button's `onClick` before `stop()`.

- [ ] **Step 4:** Gates 0; dev log clean. Commit:
```
feat(ai): read each reply aloud behind a mute button

A new reply is spoken by Gemini TTS when the key can speak and the writer has
not muted; the button beside the minimize control remembers the choice. When
the key cannot speak, the button is not rendered at all — a robotic fallback
would fail the bar the feature was set.
```

---

### Task 7: Gates, live check, browser pass

- [ ] **Step 1:** All gates both repos (api tsc/lint/test; web tsc/eslint; `node --test` on `article-blocks`, `assistant-run`, `article-writer`, `markdown-to-speech`, `format-seconds`). All 0.
- [ ] **Step 2: Browser (controller, Chrome extension, signed-in premium account; balance restored afterwards):**
  1. Open the dock: the mic renders beside the input; the mute button renders left of Minimize iff `/ai/speech-availability` is `true`.
  2. Click the mic → permission prompt (first time) → red dot + timer + check/× ; input placeholder "Listening… speak your prompt".
  3. Speak "Write two short paragraphs about why Hello World matters", click ✓ → spinner → transcript in the input, editable, focus at the end. Balance −200 (one minute). `ai_interactions` row `voice_transcribe`.
  4. Enter → the write happens as before; when the reply settles, the recap is spoken (if available). Mute mid-sentence → silence; unmute; the next reply speaks.
  5. Record, then × → nothing sent, no row, balance unchanged.
  6. Balance set to 150 via SQL → mic disabled with "Not enough tokens to record". Restore.
  7. Refuse the permission once (if the browser allows re-prompting) → toast "Microphone access was refused".
  8. Cap: temporarily set `VOICE_MAX_SECONDS` to 5 in the frontend constant only, record 6 s → auto-confirm at 0:05. Revert before committing.
  9. If TTS was unavailable in Task 0: confirm the mute button is absent and nothing else changed.
- [ ] **Step 3:** Fix what the pass finds; re-run affected gates; commit each fix with its reason.

---

### Task 8: Final whole-branch review (SDD)

Dispatch per superpowers:subagent-driven-development — both repos' branch diffs, the spec, the ledger's deferred minors. One fix wave at most.

---

### Task 9: Spec reconcile

**Files:** `spec.inkwell.ai/5-ai-design.md` (§5.2 new; §10.1 the minute rule), `spec.inkwell.ai/2-features.md` (§3.2 rewritten from the descoped voice-to-article into the shipped voice prompt + spoken replies; keep a one-line note that voice-to-article stays descoped), `spec.inkwell.ai/10-requirements.md` (FR-82 record a prompt and transcribe it into the input, billed per minute; FR-83 hear each reply read aloud, mutable, hidden when unavailable; US-68, US-69 — next free ids, append-only), `spec.inkwell.ai/4-system-architecture.md` (the "Voice Processing" pipeline line rewritten: audio → Whisper → transcript into the prompt box, no article generation; "Text Processing" line corrected for the previous ticket too), and `docs/superpowers/specs/2026-09-14-voice-assistant-design.md` corrections section if anything deviated.

- [ ] **Step 1:** `grep -n -i "voice\|whisper\|speech\|transcri" spec.inkwell.ai/*.md` — rewrite every hit that describes the descoped feature as shipped, or the shipped one incorrectly.
- [ ] **Step 2:** Commit on `docs/voice-assistant`: `docs(ai): voice in, voice out — the recorded prompt and the spoken reply`.

---

### Task 10: Ship

- [ ] Attribution grep 0 per repo (separate commands). Push. PRs: backend, frontend, spec (bodies: what, decisions incl. the Task 0 outcome, verified with exit codes + the browser list, not verified). Hold the merge; ask once. Then `chore/bump-voice-assistant` moving all three pointers.

---

## Self-review against the spec

§3.1 → Tasks 2, 3 (multipart, limits, 413 copy, billing on provider duration, `billAction` as `voice_transcribe`, 503 copy). §3.2 → Task 3 (`SpeakDto` 1,000, throttle 20/min, WAV, no log). §3.3 → Tasks 2, 3 (memoised probe, key absent → false). §4 → Task 5 (states, cap at 5:00 client-side, permission toast, append after a space, focus, Axios path, balance refresh, mic disabled below 200). §5 → Task 6 (every settled reply, markdown stripped, one `<audio>`, stop on send/Stop/mute, minimize keeps playing, button hidden when unavailable, autoplay-refused → play state, 8 s timeout). §6 → Tasks 5, 6, 7. §7 → Tasks 2, 4, 7, 0. §8 out of scope untouched. §9 repos → Tasks 3, 5, 6, 9.

Names used consistently: `secondsToTokens`, `SpeechAvailability.check`, `VoiceService.transcribe/speak/isSpeechAvailable`, `UploadedAudio`, `useVoiceInput` (`state/seconds/start/confirm/cancel/retry`), `VoiceRecorderControl` (`disabled/disabledReason/onTranscript/onStateChange`), `useSpeechOut` (`available/muted/toggleMuted/pending/playPending/stop`), `markdownToSpeech`, `formatSeconds`. No placeholders.
