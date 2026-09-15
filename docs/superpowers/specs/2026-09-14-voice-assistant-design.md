# Voice in, voice out — design

*2026-09-14. Approved in conversation, section by section; this is the written
form. Builds on the floating assistant
(`2026-09-13-floating-ai-assistant-design.md`), which it does not change.*

## 1. The request, in the user's words

> the user hits the record button, which could be a microphone only … we'll
> start recording, and he could say whatever he wants … when he confirms with
> the check mark button, the transcript function will convert what he said into
> text … and then he could click enter to send. And also, optional, when [the
> assistant] replies back with the recap, maybe an AI voice will read the recap
> out loud — but only if there is a real good AI voice for free. And at the top
> of the chat box, on the left of the minimize button, another button for
> muting, so that if the user doesn't want the AI to speak, he just wants to
> record the prompt.

## 2. Decisions

| Question | Decision |
|---|---|
| Where is speech turned into text? | **Server-side, Groq Whisper** (`whisper-large-v3-turbo`), a new `POST /ai/transcribe`. |
| How does a recording count against the daily allowance? | **200 tokens per minute of audio, rounded up.** One quota, one indicator; a free-plan writer cannot record. |
| What is read aloud, and with what? | **Every assistant message** (answer or recap), with **Gemini TTS** (`gemini-2.5-flash-preview-tts`). **No browser-voice fallback**: if the key has no TTS, the mute button is not rendered and nothing pretends to speak. |
| Does speech-out cost tokens, and its default? | **Free to the writer, default ON**, mute persisted per browser. |
| Maximum recording | **5 minutes**; the recording stops itself at the cap and proceeds as confirmed. |

Assumptions stated rather than asked:

- The transcript lands in the input **editable**; nothing is sent until Enter.
- No live transcript while speaking; no choice of voice; the article itself is
  never read aloud; voice-to-article generation stays descoped.
- Recording obeys the input's own disabled rule (streaming, exhausted, a write
  awaiting Keep/Discard).
- Mobile microphones work the same way through `MediaRecorder`; layout is not a
  focus.

## 3. Backend

A `VoiceService` beside `AiService`, reusing its provider handles (`groq`,
`gemini()`), and three routes on `AiController`.

### 3.1 `POST /ai/transcribe`

- Guards: `JwtAuthGuard`, `AiQuotaGuard` (the existing `> 0` check; the client
  additionally refuses to start recording below one minute's cost, so a
  recording never ends in a 403 after the writer has spoken).
- Body: multipart, one field `audio`. Accepted types: `audio/webm`,
  `audio/ogg`, `audio/mp4`, `audio/mpeg`, `audio/wav` (what `MediaRecorder`
  produces across browsers). Limits: **5 minutes** of audio and **10 MB**;
  beyond either → `413` with "Recording too long (max 5 minutes)". The client
  sends its measured `seconds` alongside the file; the server rejects
  `seconds > 300` up front and bills on the transcription result's
  `durationInSeconds` when the provider reports it, else on the client's
  figure — the provider's number is the one that cannot be gamed.
- Work: `transcribe({ model: groq.transcription('whisper-large-v3-turbo'), audio })`.
- Billing: `ceil(seconds / 60) × 200` tokens through the existing `settleUsage`
  as action `voice_transcribe` (already in the `ai_action_type` enum — no
  migration), `input_text = "[voice] <seconds>s"`, `output_text` = the
  transcript. Silence is billed too: `text: ""` comes back as `200`.
- Response: `{ text: string; seconds: number; tokensUsed: number }`.
- Provider failure → `503` with "Couldn't transcribe — try again"; the client
  keeps the audio in memory so one retry needs no re-recording.

### 3.2 `POST /ai/speak`

- Guard: `JwtAuthGuard` only — no quota, per the decision.
- Body: `{ text: string }`, `@MaxLength(1000)`; the client strips Markdown
  first (see §5) so the model never reads "asterisk asterisk".
- Work: `generateSpeech({ model: gemini.speech('gemini-2.5-flash-preview-tts'), text, voice: 'Kore' })`
  → `audio/wav` bytes, streamed back with `Cache-Control: no-store`.
- Throttle: 20 requests per minute per user (`@nestjs/throttler`, already
  configured globally) so a loop cannot spend Google's daily limit.
- Not logged to `ai_interactions`: it costs the writer nothing and would put a
  zero-token row beside every reply.
- Any failure → `503`; the client is silent about it (§5).

### 3.3 `GET /ai/speech-availability`

`{ available: boolean }`. `true` only when `GEMINI_API_KEY` is set **and** a
one-time lazy probe — `generateSpeech` on the word "ready" — succeeded. The
result is cached in process memory for its lifetime (a second probe only
after a restart), so a key that answers 429 for the day does not get asked
again on every panel open. This flag is the only thing that decides whether
the mute button exists. The implementation plan's first task is running this
probe against the project's key: the free tier once reported a quota of 0 for
`generateContent` on new projects, and TTS may or may not be granted.

### 3.4 Unchanged

The chat stream, `AiQuotaGuard`, the allowance constant, `/ai/inline`, the
`ai_interactions` schema. `5-ai-design.md` §10.1 gains the 200-tokens-a-minute
rule beside the allowance.

## 4. Recording, in the dock's input row

A microphone button left of the input. `useVoiceInput()` owns the recorder
and exposes `{ state, seconds, start, confirm, cancel, transcript, error }`;
`VoiceRecorderControl` renders it; the dock only wires `transcript` into its
input value. `useAiAssistant` is untouched.

| State | What the writer sees |
|---|---|
| `idle` | Mic icon. Disabled exactly when the input is, and additionally when the balance is below 200 tokens (tooltip: the placeholder reason, or "Not enough tokens to record"). |
| `recording` | Red pulsing dot, running `m:ss` timer, placeholder "Listening… speak your prompt". Where Send was: a **check mark** (confirm) and an **×** (cancel — discards the audio, no request). At 5:00 the recorder stops itself and proceeds as confirmed. |
| `transcribing` | Timer frozen, spinner on the check mark, both controls disabled. |
| `done` | Transcript placed in the input, editable, cursor at the end, input focused. Appended after a space if the input already held text. Nothing is sent until Enter. |
| `error` | Toast with the server's message; audio kept for one retry (confirm again) except on 413/403. |

Mechanics: `getUserMedia({ audio: true })` on the first click only (no prompt
on page load) → `MediaRecorder` with the browser's default container (Opus in
WebM on Chrome/Firefox, AAC in MP4 on Safari) → one `Blob` on stop → `POST
/ai/transcribe` through the Axios client, so the 401 refresh interceptor
applies (the chat transport has none). Permission refused → toast "Microphone
access was refused", state back to `idle`. The balance query is invalidated
after the response.

## 5. Speech out, and the mute button

- **When:** after an assistant message settles — `onFinish` with `!isAbort`,
  `!isError`, non-empty text — **and** the writer is unmuted **and**
  availability is `true` **and** the message was produced in this session
  (nothing plays for restored history; there is none today, but the rule is
  stated).
- **What:** the message's text with Markdown stripped to plain sentences
  (`markdownToSpeech(md)`: headings/emphasis/links/code markers removed, list
  items joined with pauses, at most 1,000 characters — the recap is one
  sentence, an answer a paragraph).
- **How:** `POST /ai/speak` → `Blob` → one `<audio>` element the dock owns.
  A new send, Stop, or muting stops playback at once. Minimizing does **not**
  stop it — the point is to keep working while it talks.
- **Mute button:** in the header, immediately left of the minimize chevron;
  `Volume2` / `VolumeX` icons, `aria-pressed`, `aria-label` "Mute the
  assistant's voice" / "Unmute the assistant's voice"; state in `localStorage`
  (`inkwell.ai-dock.muted`), **default unmuted**. Not rendered when
  availability is `false`.
- **Failure is silent:** a `503` or a network error simply does not speak —
  the text is on screen already. The one exception is a browser autoplay
  block: the speaker button then shows a "play" state, and clicking it plays
  the pending audio.

## 6. Errors and edge cases

| Case | Behaviour |
|---|---|
| Recording longer than 5:00 | Stopped by the client at 5:00 and confirmed; the server's 413 is the backstop. |
| Recording while a write awaits Keep/Discard | Mic disabled with the input; same reason shown. |
| Balance drops below 200 mid-recording (another tab spent it) | The request still goes; the guard's `> 0` passes; the balance clamps to 0 as with any overdraft. |
| Tab closed while recording | Nothing was sent; nothing to clean up. |
| `/ai/speak` slow (> 8 s) | The client aborts it and stays silent; a late voice reading an old answer is worse than none. |
| Two assistant messages in quick succession | The second stops the first's audio before requesting its own. |
| Availability `true` at load, TTS fails later (daily limit) | Silent per message; the button stays (the probe is cached) — acceptable, the failure costs nothing. |

## 7. Verification

- **Backend (jest, in `inkwell-api-1`):** billing arithmetic (`secondsToTokens`:
  0 → 200 — a confirmed recording always costs at least a minute; 1 → 200;
  60 → 200; 61 → 400; 300 → 1000), the availability
  cache (probe called once, result memoised, failure memoised too), DTO limits
  (`text` > 1,000 rejected). The provider calls are behind small functions
  injected for tests, since `ai` cannot load in jest.
- **Frontend (`node --test`):** `markdownToSpeech` cases (heading, bold,
  list, link, code span, 1,000-char cap), `formatSeconds` (`m:ss`).
- **Browser pass:** record → confirm → transcript in the input → Enter →
  reply spoken; mute stops it; unmute; cancel discards; the 5:00 auto-stop
  (with the cap temporarily lowered in dev); mic permission refused; balance
  decreases by the minute rate; `ai_interactions` row as `voice_transcribe`.
- **Spike first (plan Task 0):** `generateSpeech` and `transcribe` against the
  project's keys from inside the API container — both must answer before any
  UI is built. If TTS answers with a quota error, the feature ships as voice
  input only, with the button hidden by the availability flag; that is a
  legitimate outcome, not a failure.

## 8. Out of scope

Live transcript while speaking; choosing a voice; reading the article aloud;
voice-to-article generation (still descoped); a browser-voice fallback.

## 9. Repos touched

backend (`ai/voice.service.ts`, `ai/ai.controller.ts`, `ai/dto/*`, one
constant) · frontend (`features/ai/use-voice-input.ts`,
`voice-recorder-control.tsx`, `use-speech-out.ts`, `markdown-to-speech.ts`,
`ai-assistant-dock.tsx`, `ai-token-indicator` unchanged) · spec
(`5-ai-design.md` §5.2 + §10.1, `2-features.md` §3.2 rewritten,
`10-requirements.md` FR-82/83, US-68/69).
