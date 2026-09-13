# Floating AI Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the side-sheet AI chat with a bottom-right floating dock whose replies either stream straight into the TipTap document (with Stop, Keep, Discard) or answer in the panel, while the panel shows the pipeline's real steps and the model's one-line recap.

**Architecture:** `POST /ai/chat` switches from a plain text stream to an AI SDK v7 UI-message stream carrying typed `data-*` parts. The outer model call gets a `write_to_article` tool; its `execute` runs the existing generation path as an inner call and forwards chunks as `data-article-delta`. On the client, one `onData` handler feeds a pure run reducer (panel state) and an `ArticleWriter` (TipTap mutations, block-by-block Markdown parsing, protected/decorated range).

**Tech Stack:** NestJS 11 + `ai@7` + `@ai-sdk/groq`/`@ai-sdk/google` + zod 4 (backend); Next.js + `@ai-sdk/react@4` + `ai@7` + TipTap 3.29 + `@tiptap/markdown@3.29.0` + ProseMirror plugins (frontend); jest (backend) and `node --test` with Node's built-in type stripping (frontend pure modules).

**Spec:** `docs/superpowers/specs/2026-09-13-floating-ai-assistant-design.md` (superproject). Read it first; this plan argues from it.

## Global Constraints

- **Nothing runs on the host.** Every gate and every install goes through `docker exec` (`.claude/skills/inkwell-ticket/references/environment.md`). Backend: `docker exec -w /app inkwell-api-1 …`; frontend: `docker exec -w /app inkwell-web-1 …`.
- **Never bare `npx jest`** — `npm test` (or `npm test -- <path>`), which loads `.env.test`.
- **`ai`, `@ai-sdk/*` are ESM-only and jest cannot load them.** Backend modules that jest tests must import from `ai` with `import type` only, and depend on structural interfaces (defined in this plan) for the stream writer. Do not attempt `transformIgnorePatterns`.
- **Frontend pure modules** (`*.check.ts` targets) must use relative imports only (no `@/`), no enums, no parameter properties — Node's type stripping runs them: `docker exec -w /app inkwell-web-1 node --test src/features/ai/<name>.check.ts`.
- **No attribution** in any commit, PR, or comment (hook-enforced). Commit messages: short conventional subject + prose on *why*.
- **Branches:** `feat/floating-ai-assistant` in backend and frontend, `docs/floating-ai-assistant` in spec, all from up-to-date `origin/main`. Never commit to `main`.
- **Gates before every commit:** backend `npx tsc --noEmit; echo "exit: $?"`, `npm run lint`, `npm test`; frontend `npx tsc --noEmit`, `npx eslint . --max-warnings=0`. Capture exit codes explicitly.
- **Comment everything** in the house voice — *why*, not what. Match the density of the surrounding file.
- **Pin `@tiptap/*` additions to `3.29.0`** (installed core). No new frontend dependencies are needed for this plan.
- **Wire-format names are fixed:** `data-status`, `data-article-start`, `data-article-delta`, `data-article-done`, tool name `write_to_article`. Copy them exactly.
- **Copy strings are fixed** where the spec gives them: "That reply used the last of today's tokens. Chat resumes at 00:00 UTC.", "Finish or discard the AI text first", "AI is temporarily unavailable".

---

## File structure

**Backend (`src/backend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/ai/chat-status.ts` *(new, pure)* | Step ids, order, labels-free payload types, `statusPart()` builder |
| `src/ai/article-stats.ts` *(new, pure)* | `countWords`, `extractHeadings` |
| `src/ai/article-write-stream.ts` *(new, pure)* | `pipeArticleWrite()` — forwards chunks as article parts and returns the stats; `withStatus()` — wraps a stage in active/done/failed parts |
| `src/ai/*.spec.ts` for the three above | jest unit specs (no `ai` import at runtime) |
| `src/ai/dto/chat.dto.ts` *(modify)* | `SelectionDto`, `ChatDto.selection?` |
| `src/ai/prompts/chat.prompt.ts` *(modify)* | `buildRoutingSystemPrompt()` (outer), `buildArticleWriteSystemPrompt()` (inner) |
| `src/ai/ai.service.ts` *(modify)* | `chat()` rewritten on `createUIMessageStream`; new `firstAnsweringModel()` probe; `streamWithFallback` untouched for inline |
| `src/ai/ai.controller.ts` *(modify)* | Swagger summary only |

**Frontend (`src/frontend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/features/ai/article-blocks.ts` *(new, pure)* | `splitCompleteBlocks`, `countWords` |
| `src/features/ai/article-blocks.check.ts` *(new)* | node:test for the above |
| `src/features/ai/assistant-run.ts` *(new, pure)* | `RunState` + reducers for every stream part |
| `src/features/ai/assistant-run.check.ts` *(new)* | node:test for the reducer |
| `src/features/editor/ai-write-range.ts` *(new)* | TipTap extension: ProseMirror plugin holding the protected range, decorations, `filterTransaction` |
| `src/features/ai/article-writer.ts` *(new)* | `createArticleWriter(editor, opts)` — append/finish/keep/discard against the range extension |
| `src/features/ai/use-ai-assistant.ts` *(new)* | `useChat` + `DefaultChatTransport` + `onData`; owns runs, writer, selection snapshot |
| `src/features/ai/ai-run-card.tsx` *(new)* | Step list, writing counter, recap |
| `src/features/ai/ai-keep-discard-bar.tsx` *(new)* | Floating Keep/Discard strip under the range |
| `src/features/ai/ai-assistant-pill.tsx` *(new)* | Minimized button / live pill |
| `src/features/ai/ai-assistant-dock.tsx` *(new)* | The floating card; replaces `ai-chat-panel.tsx` |
| `src/features/ai/ai-chat-message.tsx` *(modify)* | Drop `onInsert`/`sources`; user bubbles only |
| `src/features/editor/use-autosave.ts` *(modify)* | `suspended` option |
| `src/features/editor/tiptap-editor.tsx` *(modify)* | Register `AiWriteRange` |
| `src/features/editor/editor-shell.tsx` *(modify)* | Mount the dock; pass writer state to autosave; `beforeunload` |
| `src/app/globals.css` *(modify)* | `.ai-writing` decoration styles |
| **Delete** `src/features/ai/ai-chat-panel.tsx`, `src/features/ai/use-ai-chat.ts` | Replaced |

**Spec (`spec.inkwell.ai`)** — `5-ai-design.md`, `2-features.md`, `10-requirements.md` (Task 16).

---

## Cost model (state it in the PR)

A plain question: one model call with the lean outer prompt (guidelines + article + memory) — cheaper than today (no retrieval). A write: the lean outer prompt twice (route, then recap with the tool result) plus one full inner call (article + memory + retrieved passages + brief). Retrieval's embedding call happens only for writes.

---

### Task 0: Spike — does the model route via the tool?

Throwaway. Nothing from this task is kept; its output is a paragraph in the PR body.

**Files:**
- Create (temporarily): `src/backend.inkwell.ai/probe-routing.mjs`

- [ ] **Step 1: Write the probe**

```js
// probe-routing.mjs — THROWAWAY. Delete before committing anything.
// Runs inside inkwell-api-1 so it sees GROQ_API_KEY / GEMINI_API_KEY.
import { streamText, tool, stepCountIs } from 'ai';
import { createGroq } from '@ai-sdk/groq';
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { z } from 'zod';

const groq = createGroq({ apiKey: process.env.GROQ_API_KEY });
const gemini = process.env.GEMINI_API_KEY
  ? createGoogleGenerativeAI({ apiKey: process.env.GEMINI_API_KEY })
  : null;

const models = [
  ['openai/gpt-oss-120b', groq('openai/gpt-oss-120b')],
  ...(gemini ? [['gemini-3.5-flash', gemini('gemini-3.5-flash')]] : []),
];

const prompts = [
  ['WRITE', 'Create an article about the Huddle project we worked on last month.'],
  ['ANSWER', 'Is my introduction too long?'],
  ['WRITE', 'Rewrite this paragraph to be more formal.'],
  ['ANSWER', 'What tone would suit a piece about remote work?'],
];

const system = `You are Inkwell AI, a writing assistant embedded in an article editor.
Routing rule: if the writer asks you to produce, add, rewrite or change article text,
call write_to_article. Never paste article text into the chat. Answer questions in chat.
The writer is working on this article:
---
Remote work changed how teams meet. This piece looks at what Huddle taught us.
---`;

for (const [id, model] of models) {
  for (const [expect, text] of prompts) {
    let called = null;
    let answer = '';
    const result = streamText({
      model,
      system,
      messages: [{ role: 'user', content: text }],
      stopWhen: stepCountIs(2),
      tools: {
        write_to_article: tool({
          description:
            "Write or rewrite article text directly in the writer's document. Call this whenever the writer asks you to produce or change article text. Never paste article text into the chat instead.",
          inputSchema: z.object({
            placement: z.enum(['cursor', 'replace_selection']),
            brief: z.string().describe('One line: what you are about to write'),
          }),
          execute: async (input) => {
            called = input;
            return { words: 480, headings: ['A', 'B'] };
          },
        }),
      },
    });
    for await (const part of result.fullStream) {
      if (part.type === 'text-delta') answer += part.text;
    }
    const got = called ? 'WRITE' : 'ANSWER';
    console.log(
      `${got === expect ? 'OK  ' : 'FAIL'} ${id.padEnd(22)} ${expect.padEnd(6)} "${text}"`,
      called ? JSON.stringify(called) : `→ ${answer.slice(0, 60).replace(/\n/g, ' ')}…`,
    );
  }
}
```

- [ ] **Step 2: Run it**

Run: `docker exec -w /app inkwell-api-1 node probe-routing.mjs`
Expected: 8 lines, all `OK`. Record the exact output.

- [ ] **Step 3: Decide**

All `OK` → continue. Any `FAIL` on the WRITE cases → strengthen the routing sentence in the prompt (Task 4 uses the same text) and re-run once. Still failing on a model → stop and report; the spec's Approach 1 assumption does not hold for that model and the user decides.

- [ ] **Step 4: Delete the probe**

Run: `rm src/backend.inkwell.ai/probe-routing.mjs && git -C src/backend.inkwell.ai status --short`
Expected: clean.

---

### Task 1: Branches and baselines

**Files:** none.

- [ ] **Step 1: Branch all three repos**

```bash
cd /home/oussama/Desktop/PFE/PFE-ING/inkwell.ai/docker.inkwell.ai
for r in src/backend.inkwell.ai src/frontend.inkwell.ai; do
  git -C $r fetch -q origin && git -C $r checkout -q -b feat/floating-ai-assistant origin/main
done
git -C spec.inkwell.ai fetch -q origin && git -C spec.inkwell.ai checkout -q -b docs/floating-ai-assistant origin/main
```

Note: if the previous ticket's PRs (backend #35, frontend #36, spec #25) are not yet merged, branch from those branches instead — this work depends on `@tiptap/markdown` and the panel changes they carry. Say which base was used in the PR.

- [ ] **Step 2: Baseline gates, record exit codes**

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "api tsc: $?"
docker exec -w /app inkwell-api-1 npm run lint >/dev/null 2>&1; echo "api lint: $?"
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "web tsc: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "web eslint: $?"
```

Expected: all `0`. If not, note which and continue; a pre-existing red is not yours to fix.

---

### Task 2: Backend pure modules — status parts and article stats

**Files:**
- Create: `src/backend.inkwell.ai/src/ai/chat-status.ts`
- Create: `src/backend.inkwell.ai/src/ai/chat-status.spec.ts`
- Create: `src/backend.inkwell.ai/src/ai/article-stats.ts`
- Create: `src/backend.inkwell.ai/src/ai/article-stats.spec.ts`

**Interfaces:**
- Produces: `CHAT_STEPS`, `ChatStep`, `ChatStepState`, `ChatStatusData`, `StatusPart`, `statusPart(step, state, detail?, chunks?)`; `countWords(text): number`, `extractHeadings(markdown): string[]`.

- [ ] **Step 1: Write the failing specs**

`src/ai/chat-status.spec.ts`:
```ts
import { CHAT_STEPS, statusPart } from './chat-status.js';

describe('chat status parts', () => {
  it('orders the steps as the pipeline actually runs them', () => {
    // Retrieval sits AFTER thinking: it only runs inside the write tool, so a
    // question never pays for an embedding call. The client renders rows in
    // this order regardless of arrival.
    expect(CHAT_STEPS).toEqual([
      'draft',
      'profile',
      'thinking',
      'retrieval',
      'writing',
      'done',
    ]);
  });

  it('builds a transient data part the UI stream can carry', () => {
    // `transient` keeps status out of message.parts — the panel keeps its own
    // run state, and persisting forty status parts per reply would bloat
    // every later request's history.
    expect(statusPart('retrieval', 'done', '4 passages from 2 articles')).toEqual({
      type: 'data-status',
      data: { step: 'retrieval', state: 'done', detail: '4 passages from 2 articles' },
      transient: true,
    });
  });

  it('omits detail and chunks when absent rather than sending undefined', () => {
    expect(statusPart('thinking', 'active')).toEqual({
      type: 'data-status',
      data: { step: 'thinking', state: 'active' },
      transient: true,
    });
  });
});
```

`src/ai/article-stats.spec.ts`:
```ts
import { countWords, extractHeadings } from './article-stats.js';

describe('countWords', () => {
  it('counts whitespace-separated words', () => {
    expect(countWords('one two  three\nfour')).toBe(4);
  });
  it('is zero for empty or whitespace-only text', () => {
    expect(countWords('')).toBe(0);
    expect(countWords('  \n ')).toBe(0);
  });
  it('does not count markdown heading markers as words', () => {
    expect(countWords('## Title\n\nBody text here')).toBe(4);
  });
});

describe('extractHeadings', () => {
  it('returns ATX heading text in document order', () => {
    expect(extractHeadings('# A\n\ntext\n\n## B\n### C')).toEqual(['A', 'B', 'C']);
  });
  it('ignores hashes inside prose and code fences', () => {
    expect(extractHeadings('use #tag here\n\n```\n# not a heading\n```\n\n# Real')).toEqual([
      'Real',
    ]);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `docker exec -w /app inkwell-api-1 npm test -- src/ai/chat-status.spec.ts src/ai/article-stats.spec.ts`
Expected: FAIL — cannot find module `./chat-status.js` / `./article-stats.js`.

- [ ] **Step 3: Implement**

`src/ai/chat-status.ts`:
```ts
import type { RetrievedChunk } from './retrieval.service.js';

/**
 * The stages of a chat turn, in the order the panel renders them.
 *
 * This is the pipeline as it actually runs, not as it is nicest to present.
 * `retrieval` comes AFTER `thinking` because the embedding search only runs
 * inside the write tool: a plain question never needs passages, so it never
 * pays for them. A step that never fires is simply never rendered.
 *
 * Only real work gets a row. There is no "researching the web" step because
 * there is no web research; adding one here without building it would make
 * the panel lie.
 */
export const CHAT_STEPS = [
  'draft',
  'profile',
  'thinking',
  'retrieval',
  'writing',
  'done',
] as const;

export type ChatStep = (typeof CHAT_STEPS)[number];
export type ChatStepState = 'active' | 'done' | 'failed';

export interface ChatStatusData {
  step: ChatStep;
  state: ChatStepState;
  /** Short human line for the row, e.g. "4 passages from 2 articles". */
  detail?: string;
  /** Retrieval only: the passages, so the row can expand to show them. */
  chunks?: RetrievedChunk[];
}

/**
 * A `data-status` part as the UI message stream carries it.
 *
 * `transient: true` means the SDK delivers it to the client's `onData` and
 * does NOT append it to the message's parts. The panel keeps its own run
 * state; persisting status into the message would send the whole step
 * history back up with every later request.
 */
export interface StatusPart {
  type: 'data-status';
  data: ChatStatusData;
  transient: true;
}

export function statusPart(
  step: ChatStep,
  state: ChatStepState,
  detail?: string,
  chunks?: RetrievedChunk[],
): StatusPart {
  // Built field by field so absent values are absent, not `undefined` —
  // the part is JSON on the wire and a test comparing with toEqual would
  // otherwise pass on one side and fail on the other.
  const data: ChatStatusData = { step, state };
  if (detail !== undefined) data.detail = detail;
  if (chunks !== undefined) data.chunks = chunks;
  return { type: 'data-status', data, transient: true };
}
```

`src/ai/article-stats.ts`:
```ts
/**
 * Facts about a generated article, computed rather than asked of the model.
 *
 * The write tool returns these to the outer model so the recap it writes is
 * grounded in what was actually inserted ("5 sections, 640 words"), and the
 * client shows the same numbers. They are computed here, once, so the two
 * cannot disagree.
 */

/** Words as a writer would count them: runs of non-whitespace, markdown
 *  heading markers excluded so "## Title" is one word, not two. */
export function countWords(text: string): number {
  const stripped = text.replace(/^#{1,6}\s+/gm, '');
  const matches = stripped.match(/\S+/g);
  return matches ? matches.length : 0;
}

/**
 * ATX headings (`# …` through `###### …`) in order, ignoring fenced code.
 *
 * Setext headings (underlined with `===`) are not detected; the chat prompt
 * asks for Markdown and the models emit ATX. A missed heading costs a number
 * in the recap, nothing more.
 */
export function extractHeadings(markdown: string): string[] {
  const headings: string[] = [];
  let inFence = false;
  for (const line of markdown.split('\n')) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const m = /^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$/.exec(line);
    if (m) headings.push(m[1]);
  }
  return headings;
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `docker exec -w /app inkwell-api-1 npm test -- src/ai/chat-status.spec.ts src/ai/article-stats.spec.ts`
Expected: PASS, 8 tests.

- [ ] **Step 5: Gates and commit**

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-api-1 npm run lint; echo "exit: $?"
cd src/backend.inkwell.ai && git add src/ai/chat-status.ts src/ai/chat-status.spec.ts src/ai/article-stats.ts src/ai/article-stats.spec.ts
git commit -m "feat(ai): status step vocabulary and article stats for the assistant stream

The panel is about to show the pipeline's real steps, and the recap the model
writes after inserting an article needs facts it did not make up. Both live
here as pure modules so they can be tested without loading the ESM-only ai
package, which jest cannot."
```

---

### Task 3: Backend pure module — article write stream and status wrapper

**Files:**
- Create: `src/backend.inkwell.ai/src/ai/article-write-stream.ts`
- Create: `src/backend.inkwell.ai/src/ai/article-write-stream.spec.ts`

**Interfaces:**
- Consumes: `statusPart`, `ChatStep`, `StatusPart` (Task 2); `countWords`, `extractHeadings` (Task 2).
- Produces: `AssistantPart` union, `PartWriter` interface, `ArticleWriteResult`, `pipeArticleWrite(writer, id, chunks)`, `withStatus(writer, step, work)`.

- [ ] **Step 1: Write the failing spec**

`src/ai/article-write-stream.spec.ts`:
```ts
import {
  pipeArticleWrite,
  withStatus,
  type AssistantPart,
  type PartWriter,
} from './article-write-stream.js';

/** A writer that records instead of streaming — the whole contract is the
 *  ordered list of parts, so that list is what the tests assert on. */
function recorder(): PartWriter & { parts: AssistantPart[] } {
  const parts: AssistantPart[] = [];
  return { parts, write: (p) => void parts.push(p) };
}

async function* chunks(...items: string[]): AsyncGenerator<string> {
  for (const item of items) yield item;
}

describe('pipeArticleWrite', () => {
  it('announces the write, forwards every chunk in order, then reports stats', async () => {
    const w = recorder();
    const result = await pipeArticleWrite(
      w,
      { id: 'w1', placement: 'cursor', brief: 'an intro' },
      chunks('## Hello\n\n', 'one two ', 'three'),
    );

    expect(w.parts).toEqual([
      { type: 'data-article-start', data: { id: 'w1', placement: 'cursor', brief: 'an intro' }, transient: true },
      { type: 'data-article-delta', data: { id: 'w1', text: '## Hello\n\n' }, transient: true },
      { type: 'data-article-delta', data: { id: 'w1', text: 'one two ' }, transient: true },
      { type: 'data-article-delta', data: { id: 'w1', text: 'three' }, transient: true },
      { type: 'data-article-done', data: { id: 'w1', words: 4, headings: ['Hello'] }, transient: true },
    ]);
    expect(result).toEqual({ text: '## Hello\n\none two three', words: 4, headings: ['Hello'] });
  });

  it('still reports done when the stream is empty, so the client can close the range', async () => {
    const w = recorder();
    const result = await pipeArticleWrite(w, { id: 'w2', placement: 'cursor', brief: 'x' }, chunks());
    expect(w.parts.at(-1)).toEqual({
      type: 'data-article-done',
      data: { id: 'w2', words: 0, headings: [] },
      transient: true,
    });
    expect(result.text).toBe('');
  });
});

describe('withStatus', () => {
  it('brackets the work with active and done, carrying the detail', async () => {
    const w = recorder();
    const value = await withStatus(w, 'retrieval', async () => ({
      value: 42,
      detail: '4 passages from 2 articles',
    }));
    expect(value).toBe(42);
    expect(w.parts).toEqual([
      { type: 'data-status', data: { step: 'retrieval', state: 'active' }, transient: true },
      {
        type: 'data-status',
        data: { step: 'retrieval', state: 'done', detail: '4 passages from 2 articles' },
        transient: true,
      },
    ]);
  });

  it('marks the step failed with the error message and rethrows', async () => {
    const w = recorder();
    await expect(
      withStatus(w, 'profile', async () => {
        throw new Error('db down');
      }),
    ).rejects.toThrow('db down');
    expect(w.parts[1]).toEqual({
      type: 'data-status',
      data: { step: 'profile', state: 'failed', detail: 'db down' },
      transient: true,
    });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -w /app inkwell-api-1 npm test -- src/ai/article-write-stream.spec.ts`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Implement**

`src/ai/article-write-stream.ts`:
```ts
import { statusPart, type ChatStep, type StatusPart } from './chat-status.js';
import { countWords, extractHeadings } from './article-stats.js';
import type { RetrievedChunk } from './retrieval.service.js';

/**
 * The parts this module writes onto the UI message stream, beyond what the
 * SDK writes itself (text, tool, reasoning). All transient: the client keeps
 * run state, and the document holds the article — neither belongs in the
 * message history that gets sent back with the next request.
 */
export interface ArticleStartPart {
  type: 'data-article-start';
  data: { id: string; placement: 'cursor' | 'replace_selection'; brief: string };
  transient: true;
}
export interface ArticleDeltaPart {
  type: 'data-article-delta';
  data: { id: string; text: string };
  transient: true;
}
export interface ArticleDonePart {
  type: 'data-article-done';
  data: { id: string; words: number; headings: string[] };
  transient: true;
}
export type AssistantPart = StatusPart | ArticleStartPart | ArticleDeltaPart | ArticleDonePart;

/**
 * The slice of the SDK's `UIMessageStreamWriter` this module needs.
 *
 * Structural on purpose. The real writer comes from `createUIMessageStream`
 * in the ESM-only `ai` package, which jest cannot load — so the module that
 * produces the wire contract must not import it at runtime. The service
 * passes the SDK writer, which satisfies this shape; the specs pass a
 * recorder.
 */
export interface PartWriter {
  write(part: AssistantPart): void;
}

export interface ArticleWriteResult {
  text: string;
  words: number;
  headings: string[];
}

/**
 * Forwards a generation to the client as it happens, then reports what it was.
 *
 * `start` goes first so the client can open its insertion range before the
 * first word arrives; `done` goes last even for an empty stream so the range
 * is always closed. The stats are computed here and returned to the caller —
 * the tool hands them to the outer model, which is how the recap it writes
 * stays grounded in what the document actually received.
 */
export async function pipeArticleWrite(
  writer: PartWriter,
  write: { id: string; placement: 'cursor' | 'replace_selection'; brief: string },
  chunks: AsyncIterable<string>,
): Promise<ArticleWriteResult> {
  writer.write({ type: 'data-article-start', data: write, transient: true });

  let text = '';
  for await (const chunk of chunks) {
    if (!chunk) continue;
    text += chunk;
    writer.write({ type: 'data-article-delta', data: { id: write.id, text: chunk }, transient: true });
  }

  const words = countWords(text);
  const headings = extractHeadings(text);
  writer.write({ type: 'data-article-done', data: { id: write.id, words, headings }, transient: true });
  return { text, words, headings };
}

/**
 * Runs one pipeline stage between an `active` and a `done` status part.
 *
 * A failure becomes a `failed` part carrying the message and is rethrown:
 * the row in the panel should say what broke, and the turn should still
 * abort the way it does today rather than continue on a half-built prompt.
 */
export async function withStatus<T>(
  writer: PartWriter,
  step: ChatStep,
  work: () => Promise<{ value: T; detail?: string; chunks?: RetrievedChunk[] }>,
): Promise<T> {
  writer.write(statusPart(step, 'active'));
  try {
    const { value, detail, chunks } = await work();
    writer.write(statusPart(step, 'done', detail, chunks));
    return value;
  } catch (error) {
    writer.write(
      statusPart(step, 'failed', error instanceof Error ? error.message : String(error)),
    );
    throw error;
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec -w /app inkwell-api-1 npm test -- src/ai/article-write-stream.spec.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Gates and commit**

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-api-1 npm run lint; echo "exit: $?"
cd src/backend.inkwell.ai && git add src/ai/article-write-stream.ts src/ai/article-write-stream.spec.ts
git commit -m "feat(ai): stream an article write as typed parts, and bracket stages with status

The wire contract for the floating assistant is an ordered list of parts, so
it is produced by a module that takes a structural writer and can be handed a
recorder in tests. The SDK writer satisfies the same shape at runtime."
```

---

### Task 4: DTO and prompts

**Files:**
- Modify: `src/backend.inkwell.ai/src/ai/dto/chat.dto.ts`
- Modify: `src/backend.inkwell.ai/src/ai/prompts/chat.prompt.ts`

**Interfaces:**
- Produces: `ChatDto.selection?: SelectionDto` with `text: string`; `buildRoutingSystemPrompt(articleContext?, memoryBlock?)`, `buildArticleWriteSystemPrompt(articleContext, retrieved, memoryBlock, brief, selectionText?)`. `buildChatSystemPrompt` is **removed** (its only caller is rewritten in Task 5).

- [ ] **Step 1: Add the selection to the DTO**

In `chat.dto.ts`, after `ChatMessageDto`:
```ts
// What the writer had selected in the editor when they sent the message. Only
// the text travels: the document positions stay on the client, which hands
// them to the writer if the model decides to replace the selection. Sending
// positions would make the server a party to editor state it cannot verify.
export class SelectionDto {
  @ApiProperty({ example: 'The phrase first appeared in the 1972 C tutorial.' })
  @IsString()
  text!: string;
}
```
and in `ChatDto`, after `articleId`:
```ts
  @ApiPropertyOptional({
    description: 'The editor selection at send time, if any',
    type: SelectionDto,
  })
  @IsOptional()
  @ValidateNested()
  @Type(() => SelectionDto)
  selection?: SelectionDto;
```

- [ ] **Step 2: Replace `buildChatSystemPrompt` with the two prompts**

In `chat.prompt.ts`, keep `MAX_ARTICLE_CONTEXT_CHARS`, `buildArticleBlock`, `buildVoiceBlock` as they are. Replace the `buildChatSystemPrompt` function (and its docblock) with:

```ts
/**
 * The shared identity and guidelines, used by both calls below.
 *
 * "Prose, not bullet points" and "Markdown" are one rule, not two: the reply
 * is Markdown because it is rendered and inserted with its formatting, and
 * it is prose because that is what an article is.
 */
const GUIDELINES = `You are Inkwell AI, a professional writing assistant embedded in a content creation platform.

Guidelines:
- Match the writer's tone and style when they have existing content
- Be concise — writers want actionable help, not lengthy explanations
- Never mention that you are an AI unless directly asked
- Respond in the same language the writer uses
- Write in Markdown: headings and emphasis where they help; lists only when asked; never tables or checklists, which the editor cannot hold`;

/**
 * The OUTER call: decides whether to write into the document or answer.
 *
 * Deliberately lean — the article and the style profile, but NOT the
 * retrieved passages. Routing does not need them, a question about the draft
 * does not need them, and the embedding search they cost is the slowest
 * stage of the pipeline. They are fetched only once the model has chosen to
 * write, inside the tool (see `buildArticleWriteSystemPrompt`). This is the
 * second time the outer prompt is sent per write (route, then recap), so
 * keeping it small is worth real tokens.
 *
 * The routing rule is stated twice — here and in the tool description —
 * because Task 0 of the plan showed the models follow it reliably only when
 * the instruction is unmissable.
 */
export function buildRoutingSystemPrompt(
  articleContext?: string,
  memoryBlock = '',
): string {
  return `${GUIDELINES}

Routing rule — follow it every time:
- If the writer asks you to produce, add, rewrite, expand, shorten or otherwise change article text, call the write_to_article tool. Put the actual text in the document, never in the chat.
- Use placement "replace_selection" only when the writer's request is about the text they have selected; otherwise "cursor".
- If the writer asks a question or wants an opinion, answer in chat, briefly.
- After the tool returns, reply with ONE short sentence: what you added, and if useful one suggestion. Do not repeat the text.

${buildArticleBlock(articleContext)}${memoryBlock}`;
}

/**
 * The INNER call: writes the article text itself.
 *
 * This is the "write like me" half, so it carries everything: the draft, the
 * style profile, and the passages retrieved for THIS brief. The output is
 * the text and nothing else — no preamble, no "here is your article" — because
 * it streams straight into the document and a preamble would be inserted too.
 */
export function buildArticleWriteSystemPrompt(
  articleContext: string | undefined,
  retrieved: RetrievedChunk[],
  memoryBlock: string,
  brief: string,
  selectionText?: string,
): string {
  const selectionBlock = selectionText
    ? `\n\nThe writer selected this text, and your output replaces it:\n---\n${selectionText}\n---`
    : '';

  return `${GUIDELINES}

You are now writing directly into the writer's document. Output ONLY the article text in Markdown — no introduction, no commentary, no closing remark. Start with the first line of content.

What to write: ${brief}${selectionBlock}

${buildArticleBlock(articleContext)}${memoryBlock}${buildVoiceBlock(retrieved)}`;
}
```

- [ ] **Step 3: Typecheck (expect one error)**

Run: `docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"`
Expected: exactly one error — `ai.service.ts` imports `buildChatSystemPrompt`, which no longer exists. Task 5 fixes it. Do not commit yet; Task 5 commits both.

---

### Task 5: `AiService.chat` on the UI message stream

**Files:**
- Modify: `src/backend.inkwell.ai/src/ai/ai.service.ts` (imports, `chat()`, new `firstAnsweringModel()`)
- Modify: `src/backend.inkwell.ai/src/ai/ai.controller.ts:52-54` (summary text)

**Interfaces:**
- Consumes: `pipeArticleWrite`, `withStatus`, `PartWriter` (Task 3); `statusPart` (Task 2); `buildRoutingSystemPrompt`, `buildArticleWriteSystemPrompt` (Task 4); `ChatDto.selection` (Task 4).
- Produces: the wire behaviour the frontend (Tasks 8–12) consumes. No new exports.

- [ ] **Step 1: Update the imports**

Replace the `ai` import line at the top of `ai.service.ts` with:
```ts
import {
  streamText,
  pipeTextStreamToResponse,
  createUIMessageStream,
  pipeUIMessageStreamToResponse,
  stepCountIs,
  tool,
  type ModelMessage,
  type StreamTextResult,
  type ToolSet,
} from 'ai';
import { z } from 'zod';
```
Replace `import { buildChatSystemPrompt } from './prompts/chat.prompt.js';` with:
```ts
import {
  buildRoutingSystemPrompt,
  buildArticleWriteSystemPrompt,
} from './prompts/chat.prompt.js';
import { statusPart } from './chat-status.js';
import {
  pipeArticleWrite,
  withStatus,
  type PartWriter,
} from './article-write-stream.js';
```

- [ ] **Step 2: Add the probe that generalises the failover to any stream**

Add this private method right after `chain()`:

```ts
  /**
   * The first model in the chain that actually starts answering.
   *
   * The same idea as the hand-pulled first chunk in `streamWithFallback`, for
   * the tool-capable calls the assistant now makes: `streamText` defers the
   * provider call until consumed, so pulling parts until one proves the model
   * is producing (`text-delta`, `reasoning-delta`, `tool-input-start`,
   * `tool-call`) is the moment a 401/429/unavailable surfaces — and a model
   * that errors or finishes with nothing is skipped for the next.
   *
   * Why this does not lose the probed parts: every accessor on the result
   * (`fullStream`, `textStream`, `toUIMessageStream()`) tees the underlying
   * stream, so the branch consumed here is separate from the one the caller
   * goes on to read. The probe's branch is released with `return()` so it
   * stops buffering. Verified against `ai/dist/index.js` (`teeStream`), not
   * assumed.
   */
  private async firstAnsweringModel<TOOLS extends ToolSet>(
    action: string,
    userId: string,
    build: (model: LanguageModel) => StreamTextResult<TOOLS, never>,
  ): Promise<{ id: string; result: StreamTextResult<TOOLS, never> } | null> {
    for (const { id, model } of this.chain()) {
      const result = build(model);
      const probe = result.fullStream[Symbol.asyncIterator]();
      let answered = false;
      let failure: unknown;
      try {
        for (;;) {
          const next = await probe.next();
          if (next.done) break;
          const part = next.value;
          if (part.type === 'error') {
            failure = part.error;
            break;
          }
          if (
            part.type === 'text-delta' ||
            part.type === 'reasoning-delta' ||
            part.type === 'tool-input-start' ||
            part.type === 'tool-call'
          ) {
            answered = true;
            break;
          }
        }
      } catch (error) {
        failure = error;
      } finally {
        void probe.return?.(undefined);
      }
      if (answered) return { id, result };
      this.logStreamFailure(
        action,
        userId,
        failure ?? new Error(`${id} produced no output`),
        id,
      );
    }
    return null;
  }
```

- [ ] **Step 3: Rewrite `chat()`**

Replace the whole `chat` method (from its `// Contextual chat` comment through the closing brace of the method) with:

```ts
  /**
   * The assistant turn: route, and either answer in chat or write into the
   * document — one request, one typed stream.
   *
   * ## Shape
   *
   * The response is an AI SDK UI-message stream rather than raw text, because
   * the panel now needs more than words: which stage is running, that a write
   * has started, each chunk of it, and the facts about it when it ends. Those
   * travel as `data-*` parts alongside the model's own text and tool parts
   * (`article-write-stream.ts` holds the vocabulary).
   *
   * The outer model call carries a `write_to_article` tool. When the model
   * calls it, the tool's `execute` runs the existing generation path as a
   * SECOND call and forwards its chunks; the tool returns word and heading
   * counts, and the outer loop continues so the model writes a one-line recap
   * grounded in them. A plain question never calls the tool: one lean call.
   *
   * ## Why the response opens before the model is known to answer
   *
   * `streamWithFallback` holds the status line back until a model produces a
   * token, so an outage can be a real 503. Here the first bytes are status
   * parts about stages that happen BEFORE any model call, and holding them
   * back would hide exactly the live progress this stream exists to show. The
   * UI-message protocol has an `error` part for the post-headers case, so an
   * outage arrives as a failed step with the §11.2 copy instead — which is
   * more than the text stream could ever say after its headers were gone.
   *
   * ## Billing
   *
   * Both calls' usage is summed and settled once, at the end. `onFinish` does
   * not fire on abort, so `onAbort` bills an estimate from the text produced —
   * a Stop pressed one sentence before the end must not make the article free.
   */
  async chat(userId: string, dto: ChatDto, res: ServerResponse): Promise<void> {
    // Cancels both model calls when the client goes away. Without it the
    // outer loop, the inner generation and the recap all run to completion
    // for a socket nobody is reading, and the tokens are spent regardless.
    const abort = new AbortController();
    res.on('close', () => abort.abort());

    const lastUserMessage = this.lastUserText(dto);
    const messages: ModelMessage[] = dto.messages.map((msg) => ({
      role: msg.role,
      content: msg.parts
        .filter((p) => p.type === 'text' && p.text)
        .map((p) => p.text)
        .join(''),
    }));

    // Everything the inner write produces, so the outer `onFinish` can bill
    // the sum and log the article rather than the recap. Closed over rather
    // than passed around: there is exactly one write per turn in practice,
    // and the id on the parts keeps a second one from interleaving if a model
    // ever tries.
    let innerTokens = 0;
    let innerText = '';
    let innerModel: string | null = null;
    // The model that answered the outer (routing/recap) call. Assigned once
    // `firstAnsweringModel` returns, which is before any of the callbacks
    // below that read it can fire — they run as the stream is consumed.
    let outerModelId: string | null = null;
    let writeCount = 0;

    const stream = createUIMessageStream({
      execute: async ({ writer }) => {
        const parts: PartWriter = writer;

        // ── Stage: draft ──────────────────────────────────────────────────
        // SECURITY: the author check is not optional. This query used to match
        // on id alone, so any authenticated user could pass any article's id —
        // someone else's unpublished draft included — and have its full text
        // injected into their own prompt, then read it straight back out of
        // the model's reply.
        const articleContext = await withStatus(parts, 'draft', async () => {
          if (!dto.articleId) return { value: undefined, detail: 'no article yet' };
          const [article] = await this.db
            .select({ content: schema.articles.content })
            .from(schema.articles)
            .where(
              and(
                eq(schema.articles.id, dto.articleId),
                eq(schema.articles.authorId, userId),
                isNull(schema.articles.deletedAt),
              ),
            )
            .limit(1);
          const text = article?.content ? extractFullText(article.content) : '';
          const words = text.trim() ? text.trim().split(/\s+/).length : 0;
          return {
            value: text || undefined,
            detail: words ? `${words.toLocaleString('en-US')} words read` : 'empty draft',
          };
        });

        // ── Stage: profile ────────────────────────────────────────────────
        const memoryBlock = await withStatus(parts, 'profile', async () => {
          const memory = await this.writerMemory.get(userId);
          const block = renderMemoryBlock(memory);
          return {
            value: block,
            detail: block ? 'style profile loaded' : 'no profile yet',
          };
        });

        // ── The tool: the model's decision to write ───────────────────────
        const tools = {
          write_to_article: tool({
            description:
              "Write or rewrite article text directly in the writer's document. " +
              'Call this whenever the writer asks you to produce or change article text. ' +
              'Never paste article text into the chat instead.',
            inputSchema: z.object({
              placement: z.enum(['cursor', 'replace_selection']),
              brief: z.string().describe('One line: what you are about to write'),
            }),
            execute: async ({ placement, brief }) => {
              // A selection the client never sent cannot be replaced; degrade
              // to the cursor rather than fail the whole turn on a routing
              // nuance the writer never sees.
              const selectionText = dto.selection?.text;
              const effectivePlacement =
                placement === 'replace_selection' && !selectionText ? 'cursor' : placement;
              const id = `w${++writeCount}`;

              // ── Stage: retrieval — only now, only for a write ───────────
              // Keyed on the brief plus the newest user message: the brief is
              // the model's own statement of what it is about to write, which
              // is a better retrieval query than the raw request alone.
              const retrieved = await withStatus(parts, 'retrieval', async () => {
                const chunks = await this.retrieval.findSimilarChunks(
                  `${brief}\n${lastUserMessage}`,
                  { authorId: userId, excludeArticleId: dto.articleId },
                );
                const articles = new Set(chunks.map((c) => c.articleId)).size;
                return {
                  value: chunks,
                  detail: chunks.length
                    ? `${chunks.length} passage${chunks.length === 1 ? '' : 's'} from ${articles} article${articles === 1 ? '' : 's'}`
                    : 'nothing close enough in your published work',
                  chunks,
                };
              });
              this.lastRetrieval.set(userId, retrieved);

              // ── Stage: writing ──────────────────────────────────────────
              parts.write(statusPart('writing', 'active', brief));
              const answering = await this.firstAnsweringModel('chat', userId, (model) =>
                streamText({
                  model,
                  system: buildArticleWriteSystemPrompt(
                    articleContext,
                    retrieved,
                    memoryBlock,
                    brief,
                    effectivePlacement === 'replace_selection' ? selectionText : undefined,
                  ),
                  messages,
                  abortSignal: abort.signal,
                  onFinish: ({ usage }) => {
                    innerTokens += usage.totalTokens ?? 0;
                  },
                  onError: ({ error }) => this.logStreamFailure('chat', userId, error, 'write'),
                }),
              );
              if (!answering) {
                parts.write(statusPart('writing', 'failed', AI_UNAVAILABLE_MESSAGE));
                throw new Error(AI_UNAVAILABLE_MESSAGE);
              }
              innerModel = answering.id;

              const result = await pipeArticleWrite(
                parts,
                { id, placement: effectivePlacement, brief },
                answering.result.textStream,
              );
              innerText = result.text;
              parts.write(
                statusPart(
                  'writing',
                  'done',
                  `${result.words.toLocaleString('en-US')} words, ${result.headings.length} section${result.headings.length === 1 ? '' : 's'}`,
                ),
              );
              return { words: result.words, headings: result.headings };
            },
          }),
        };

        // ── Stage: thinking → the outer call ──────────────────────────────
        // "Thinking" is the honest span from sending the request to the first
        // visible token or tool call. gpt-oss's reasoning arrives as separate
        // parts the UI stream is told not to forward; Gemini exposes none.
        // Either way the label covers real waiting, not a spinner for show.
        parts.write(statusPart('thinking', 'active'));
        let thinkingDone = false;
        const markThinkingDone = () => {
          if (thinkingDone) return;
          thinkingDone = true;
          parts.write(statusPart('thinking', 'done'));
        };

        const answering = await this.firstAnsweringModel('chat', userId, (model) =>
          streamText({
            model,
            system: buildRoutingSystemPrompt(articleContext, memoryBlock),
            messages,
            tools,
            // decide → tool → recap. The third step is headroom for a model
            // that emits a text part before its tool call, not a plan to
            // write twice.
            stopWhen: stepCountIs(3),
            abortSignal: abort.signal,
            onChunk: ({ chunk }) => {
              if (chunk.type === 'text-delta' || chunk.type === 'tool-call') {
                markThinkingDone();
              }
            },
            onFinish: ({ totalUsage, text }) => {
              const tokens = (totalUsage.totalTokens ?? 0) + innerTokens;
              void this.settleUsage(
                userId,
                dto.articleId,
                'chat',
                lastUserMessage,
                innerText || text,
                tokens,
                innerModel ?? outerModelId ?? 'unknown',
              );
            },
            onAbort: ({ steps }) => {
              // No usage on abort. Estimate from what was produced — ~4
              // characters per token is the usual rule of thumb — so a Stop
              // near the end of a long write is still paid for. Overcounting
              // by a few tokens is the cheaper error.
              const outerText = steps.map((s) => s.text).join('');
              const estimate = Math.ceil((innerText.length + outerText.length) / 4);
              void this.settleUsage(
                userId,
                dto.articleId,
                'chat',
                lastUserMessage,
                innerText || outerText,
                estimate,
                innerModel ?? outerModelId ?? 'unknown',
              );
            },
            onError: ({ error }) => this.logStreamFailure('chat', userId, error, 'route'),
          }),
        );

        if (!answering) {
          parts.write(statusPart('thinking', 'failed', AI_UNAVAILABLE_MESSAGE));
          writer.write({ type: 'error', errorText: AI_UNAVAILABLE_MESSAGE });
          return;
        }
        outerModelId = answering.id;

        writer.merge(
          answering.result.toUIMessageStream({
            sendReasoning: false,
            sendStart: true,
            sendFinish: true,
          }),
        );
        // `merge` returns before the merged stream ends; wait for the model
        // to finish so the closing status lands after the recap, not before.
        await answering.result.finishReason;
        markThinkingDone();
        parts.write(statusPart('done', 'done'));
      },
      onError: (error) => {
        this.logStreamFailure('chat', userId, error, 'stream');
        return error instanceof Error && error.message === AI_UNAVAILABLE_MESSAGE
          ? AI_UNAVAILABLE_MESSAGE
          : 'Something went wrong. Please try again.';
      },
    });

    await pipeUIMessageStreamToResponse({ response: res, stream });
  }
```

Then delete the old `// Contextual chat` docblock and the retrieval/lastRetrieval code that lived in the old `chat` (the new method covers it). Keep `lastUserText`, `getLastRetrieval`, `streamWithFallback` (inline still uses it), `logStreamFailure`, `settleUsage`, `logAndDecrement` untouched.

- [ ] **Step 4: Controller summary**

In `ai.controller.ts`, change `@ApiOperation({ summary: 'AI chat assistant (SSE stream)' })` to `@ApiOperation({ summary: 'AI assistant turn (UI message stream: status, article write, answer/recap)' })`.

- [ ] **Step 5: Typecheck and lint until green**

Run: `docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"`
Expected: `0`. Likely fix if not: `StreamTextResult<TOOLS, never>` generic mismatch — use `StreamTextResult<TOOLS, string>` or widen `build` to return `StreamTextResult<TOOLS, any>` with an eslint-disable comment explaining the SDK's output generic is irrelevant to the probe.

Run: `docker exec -w /app inkwell-api-1 npm run lint; echo "exit: $?"` — Expected `0`.

- [ ] **Step 6: Run the full backend suite**

Run: `docker exec -w /app inkwell-api-1 npm test 2>&1 | tail -6; echo "exit: $?"`
Expected: all suites pass (39 + the 3 new).

- [ ] **Step 7: Live smoke with a probe script (delete after)**

Create `src/backend.inkwell.ai/probe-chat.mjs`:
```js
// THROWAWAY — delete before committing. Needs a real access token: read one
// from the browser's localStorage `access_token` and paste it into TOKEN.
const TOKEN = process.env.TOKEN;
const res = await fetch('http://localhost:3000/ai/chat', {
  method: 'POST',
  headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` },
  body: JSON.stringify({
    messages: [{ role: 'user', parts: [{ type: 'text', text: process.argv[2] ?? 'Is my intro too long?' }] }],
  }),
});
console.log(res.status, res.headers.get('content-type'));
for await (const chunk of res.body) process.stdout.write(Buffer.from(chunk).toString());
```
Run twice (ask the user for the token; never read it from the DB):
`docker exec -w /app -e TOKEN=… inkwell-api-1 node probe-chat.mjs "Is my intro too long?"` — Expected: SSE lines including `data-status` for draft, profile, thinking (active then done), then `text-delta` parts, then `data-status` done. No `data-article-*`.
`docker exec -w /app -e TOKEN=… inkwell-api-1 node probe-chat.mjs "Write two paragraphs about why Hello World matters"` — Expected: the above plus `tool-input-available` for `write_to_article`, `data-article-start`, many `data-article-delta`, `data-article-done`, a `data-status` retrieval and writing, then `text-delta` (the recap).
Then `rm src/backend.inkwell.ai/probe-chat.mjs`. Check `ai_interactions` got one row with `tokens_used` > the outer call alone: `docker exec inkwell-db-1 psql -U inkwell -d inkwell -c "SELECT tokens_used, model, left(output_text, 40) FROM ai_interactions ORDER BY created_at DESC LIMIT 2;"`. Delete the probe rows and restore the balance if you used the user's account, and say so.

- [ ] **Step 8: Commit**

```bash
cd src/backend.inkwell.ai && git add src/ai/ai.service.ts src/ai/ai.controller.ts src/ai/dto/chat.dto.ts src/ai/prompts/chat.prompt.ts
git commit -m "feat(ai): route replies through a write_to_article tool on a typed stream

The assistant turn is now one request that either answers in chat or writes
into the document, and the client can tell which from the stream itself.
The response is a UI-message stream: status parts for each real stage,
article parts for a write in progress, and the model's text for the answer
or the recap. The outer call carries the tool and a lean prompt; the inner
call — the existing generation path, passages included — runs inside the
tool and only then, so a question never pays for an embedding search.

The failover now probes the full stream rather than the text stream, which
lets it see a tool call as proof of life. An outage arrives as an error part
with the same copy the 503 used to carry, because the response has to be open
before any model is chosen or the pre-model stages could not be shown live.

Abort bills an estimate from the text produced. onFinish does not fire on
abort, and a Stop pressed one sentence before the end must not make the
article free."
```

---

### Task 6: Frontend pure module — block splitting and word count

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/article-blocks.ts`
- Create: `src/frontend.inkwell.ai/src/features/ai/article-blocks.check.ts`

**Interfaces:**
- Produces: `splitCompleteBlocks(buffer: string): { complete: string[]; rest: string }`, `countWords(text: string): number`.

- [ ] **Step 1: Write the failing check**

`article-blocks.check.ts`:
```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/article-blocks.check.ts
// Node's built-in type stripping runs this; keep the module free of enums,
// parameter properties and `@/` aliases.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { splitCompleteBlocks, countWords } from './article-blocks.ts';

test('a blank line closes a block; the tail stays in rest', () => {
  assert.deepEqual(splitCompleteBlocks('## Title\n\nfirst para\n\nsecond, still going'), {
    complete: ['## Title', 'first para'],
    rest: 'second, still going',
  });
});

test('no blank line means nothing is complete yet', () => {
  assert.deepEqual(splitCompleteBlocks('one line so far'), { complete: [], rest: 'one line so far' });
});

test('a trailing blank line completes the last block and leaves rest empty', () => {
  assert.deepEqual(splitCompleteBlocks('done\n\n'), { complete: ['done'], rest: '' });
});

test('runs of blank lines and surrounding whitespace do not produce empty blocks', () => {
  assert.deepEqual(splitCompleteBlocks('\n\n  a  \n\n\n\nb\n\n'), { complete: ['a', 'b'], rest: '' });
});

test('a fenced code block is not split on its internal blank lines', () => {
  const md = '```js\nconst a = 1;\n\nconst b = 2;\n```\n\nafter';
  assert.deepEqual(splitCompleteBlocks(md), {
    complete: ['```js\nconst a = 1;\n\nconst b = 2;\n```'],
    rest: 'after',
  });
});

test('countWords ignores heading markers and empty text', () => {
  assert.equal(countWords('## Title\n\nfour words are here'), 5);
  assert.equal(countWords(''), 0);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -w /app inkwell-web-1 node --test src/features/ai/article-blocks.check.ts`
Expected: fails to import `./article-blocks.ts`.

- [ ] **Step 3: Implement**

`article-blocks.ts`:
```ts
/**
 * Pure helpers for streaming Markdown into the editor one block at a time.
 *
 * Markdown cannot be parsed mid-sentence — "## Ti" is not a heading yet, and
 * "1. first" might become a list or stay a paragraph — so the writer only
 * parses blocks that are demonstrably finished: a blank line after them. The
 * unfinished tail is shown as plain text until it completes.
 *
 * No `@/` imports and no enums: this file is exercised by `node --test` under
 * Node's built-in type stripping, outside the Next.js toolchain.
 */

/**
 * Splits `buffer` into the blocks that a blank line has closed, and the rest.
 *
 * Fenced code is the one construct with legitimate blank lines inside it, so
 * a fence that has been opened and not yet closed keeps everything after it
 * in `rest`, and a closed fence is one block however many blank lines it
 * contains.
 */
export function splitCompleteBlocks(buffer: string): { complete: string[]; rest: string } {
  const lines = buffer.split('\n');
  const complete: string[] = [];
  let current: string[] = [];
  let inFence = false;

  // Index of the first line that belongs to `rest`. Everything before it has
  // been assigned to a complete block or was a separating blank line.
  let restStart = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*```/.test(line)) inFence = !inFence;

    const isBlank = line.trim() === '';
    if (isBlank && !inFence) {
      if (current.length) {
        complete.push(current.join('\n').trim());
        current = [];
      }
      restStart = i + 1;
      continue;
    }
    current.push(line);
  }

  const rest = lines.slice(restStart).join('\n').replace(/^\n+/, '');
  return { complete, rest: rest.trim() === '' ? '' : rest };
}

/** Words as a writer would count them; heading markers are not words. */
export function countWords(text: string): number {
  const stripped = text.replace(/^#{1,6}\s+/gm, '');
  const matches = stripped.match(/\S+/g);
  return matches ? matches.length : 0;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec -w /app inkwell-web-1 node --test src/features/ai/article-blocks.check.ts`
Expected: `# pass 6`, `# fail 0`. If the fence test fails on the `rest` whitespace, fix the implementation, not the test.

- [ ] **Step 5: Gates and commit**

`tsc` must accept the `.ts` import extension: check `allowImportingTsExtensions` in `tsconfig.json`; if absent, change the check's import to `'./article-blocks'` and run node with `--experimental-strip-types` plus `--experimental-default-type=module` — whichever passes both `tsc` and `node --test`, record it in the check's header comment. eslint must not lint `*.check.ts` as browser code: if it complains about `node:test`, add `'**/*.check.ts'` to the ignores in `eslint.config.mjs` with a one-line comment.

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/ai/article-blocks.ts src/features/ai/article-blocks.check.ts eslint.config.mjs
git commit -m "feat(ai): block splitter for streaming markdown into the editor

Markdown cannot be parsed mid-sentence, so the writer inserts a block only
once a blank line has closed it. Pure and dependency-free so node --test can
exercise it directly — the frontend has no test runner, and this is the one
piece of the streaming path that is a function rather than a DOM behaviour."
```

---

### Task 7: Frontend pure module — the run reducer

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/assistant-run.ts`
- Create: `src/frontend.inkwell.ai/src/features/ai/assistant-run.check.ts`

**Interfaces:**
- Produces: `CHAT_STEPS`, `STEP_LABELS`, `ChatStep`, `RunStep`, `RunState`, `createRun()`, `applyStatus(run, data)`, `applyArticleStart(run, data)`, `applyArticleDelta(run, data)`, `applyArticleDone(run, data)`, `decideWrite(run)`, `failRun(run, message)`, `currentStepLabel(run)`. Types for the data payloads: `StatusData`, `ArticleStartData`, `ArticleDeltaData`, `ArticleDoneData`, `RetrievedChunkLite`.

- [ ] **Step 1: Write the failing check**

`assistant-run.check.ts`:
```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/assistant-run.check.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createRun,
  applyStatus,
  applyArticleStart,
  applyArticleDelta,
  applyArticleDone,
  decideWrite,
  failRun,
  currentStepLabel,
  CHAT_STEPS,
} from './assistant-run.ts';

test('steps render in the fixed order regardless of arrival', () => {
  let run = createRun();
  run = applyStatus(run, { step: 'profile', state: 'done', detail: 'style profile loaded' });
  run = applyStatus(run, { step: 'draft', state: 'done', detail: '120 words read' });
  const shown = CHAT_STEPS.filter((s) => run.steps[s].state !== 'pending');
  assert.deepEqual(shown, ['draft', 'profile']);
});

test('a status part updates one row and leaves the others', () => {
  let run = createRun();
  run = applyStatus(run, { step: 'thinking', state: 'active' });
  assert.equal(run.steps.thinking.state, 'active');
  run = applyStatus(run, { step: 'thinking', state: 'done' });
  assert.equal(run.steps.thinking.state, 'done');
  assert.equal(run.steps.draft.state, 'pending');
});

test('retrieval keeps its passages for the expandable row', () => {
  const chunks = [{ chunkId: 'c1', articleId: 'a1', articleTitle: 'T', articleSlug: 't', chunkIndex: 0, content: 'x', similarity: 0.9 }];
  const run = applyStatus(createRun(), { step: 'retrieval', state: 'done', detail: '1 passage from 1 article', chunks });
  assert.deepEqual(run.steps.retrieval.chunks, chunks);
});

test('a write accumulates a live word count and then the server facts', () => {
  let run = applyArticleStart(createRun(), { id: 'w1', placement: 'cursor', brief: 'an intro' });
  assert.deepEqual(run.writing, { id: 'w1', placement: 'cursor', brief: 'an intro', words: 0, done: false, decided: false });
  run = applyArticleDelta(run, { id: 'w1', text: '## Hi\n\none two ' });
  run = applyArticleDelta(run, { id: 'w1', text: 'three' });
  assert.equal(run.writing?.words, 4);
  run = applyArticleDone(run, { id: 'w1', words: 4, headings: ['Hi'] });
  assert.equal(run.writing?.done, true);
  assert.deepEqual(run.writing?.headings, ['Hi']);
  run = decideWrite(run);
  assert.equal(run.writing?.decided, true);
});

test('a delta for a different write id is ignored', () => {
  let run = applyArticleStart(createRun(), { id: 'w1', placement: 'cursor', brief: 'b' });
  run = applyArticleDelta(run, { id: 'w9', text: 'stray words here' });
  assert.equal(run.writing?.words, 0);
});

test('failRun marks the active step failed with the message', () => {
  let run = applyStatus(createRun(), { step: 'thinking', state: 'active' });
  run = failRun(run, 'AI is temporarily unavailable');
  assert.equal(run.steps.thinking.state, 'failed');
  assert.equal(run.steps.thinking.detail, 'AI is temporarily unavailable');
  assert.equal(run.error, 'AI is temporarily unavailable');
});

test('currentStepLabel names the active step for the minimized pill', () => {
  let run = applyStatus(createRun(), { step: 'retrieval', state: 'active' });
  assert.equal(currentStepLabel(run), 'Searching your published work…');
  run = applyArticleStart(run, { id: 'w1', placement: 'cursor', brief: 'b' });
  run = applyStatus(run, { step: 'retrieval', state: 'done' });
  run = applyStatus(run, { step: 'writing', state: 'active' });
  run = applyArticleDelta(run, { id: 'w1', text: 'one two three four five' });
  assert.equal(currentStepLabel(run), 'Writing… 5 words');
  assert.equal(currentStepLabel(createRun()), null);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `docker exec -w /app inkwell-web-1 node --test src/features/ai/assistant-run.check.ts`
Expected: import failure.

- [ ] **Step 3: Implement**

`assistant-run.ts`:
```ts
import { countWords } from './article-blocks.ts';

/**
 * The panel's model of one assistant turn: which stages ran, how a write is
 * going, and what went wrong. Pure — every transition is a function from a
 * run and a stream part to a new run — so the whole thing is testable with
 * node --test and the hook that owns it is nothing but plumbing.
 *
 * Mirrors `chat-status.ts` on the API. The step list and its order are
 * duplicated rather than shared because the two apps do not share a package;
 * if a step is added on one side, the check here and the spec there both
 * have to change, which is the intended friction.
 */

export const CHAT_STEPS = ['draft', 'profile', 'thinking', 'retrieval', 'writing', 'done'] as const;
export type ChatStep = (typeof CHAT_STEPS)[number];

/** Row labels. Present tense while active; the row's `detail` carries the
 *  past-tense fact once done ("4 passages from 2 articles"). */
export const STEP_LABELS: Record<ChatStep, string> = {
  draft: 'Reading your draft…',
  profile: 'Loading your style profile…',
  thinking: 'Thinking…',
  retrieval: 'Searching your published work…',
  writing: 'Writing…',
  done: 'Done',
};

export interface RetrievedChunkLite {
  chunkId: string;
  articleId: string;
  articleTitle: string;
  articleSlug: string;
  chunkIndex: number;
  content: string;
  similarity: number;
}

export interface StatusData {
  step: ChatStep;
  state: 'active' | 'done' | 'failed';
  detail?: string;
  chunks?: RetrievedChunkLite[];
}
export interface ArticleStartData {
  id: string;
  placement: 'cursor' | 'replace_selection';
  brief: string;
}
export interface ArticleDeltaData {
  id: string;
  text: string;
}
export interface ArticleDoneData {
  id: string;
  words: number;
  headings: string[];
}

export interface RunStep {
  state: 'pending' | 'active' | 'done' | 'failed';
  detail?: string;
  chunks?: RetrievedChunkLite[];
}

export interface RunWriting {
  id: string;
  placement: 'cursor' | 'replace_selection';
  brief: string;
  words: number;
  headings?: string[];
  /** The server said the write is finished (or the stream was stopped). */
  done: boolean;
  /** The writer pressed Keep or Discard. */
  decided: boolean;
}

export interface RunState {
  steps: Record<ChatStep, RunStep>;
  writing?: RunWriting;
  /** Accumulated article text, kept only to count words live. */
  text: string;
  error?: string;
}

export function createRun(): RunState {
  const steps = {} as Record<ChatStep, RunStep>;
  for (const step of CHAT_STEPS) steps[step] = { state: 'pending' };
  return { steps, text: '' };
}

export function applyStatus(run: RunState, data: StatusData): RunState {
  const step: RunStep = { state: data.state };
  if (data.detail !== undefined) step.detail = data.detail;
  if (data.chunks !== undefined) step.chunks = data.chunks;
  return { ...run, steps: { ...run.steps, [data.step]: step } };
}

export function applyArticleStart(run: RunState, data: ArticleStartData): RunState {
  return {
    ...run,
    text: '',
    writing: { ...data, words: 0, done: false, decided: false },
  };
}

export function applyArticleDelta(run: RunState, data: ArticleDeltaData): RunState {
  // A delta for another id is a second write starting on top of the first,
  // or a stray part; either way it is not this write's text.
  if (!run.writing || run.writing.id !== data.id) return run;
  const text = run.text + data.text;
  return { ...run, text, writing: { ...run.writing, words: countWords(text) } };
}

export function applyArticleDone(run: RunState, data: ArticleDoneData): RunState {
  if (!run.writing || run.writing.id !== data.id) return run;
  return {
    ...run,
    writing: { ...run.writing, words: data.words, headings: data.headings, done: true },
  };
}

/** Keep or Discard was pressed; the bar goes away, the row stays. */
export function decideWrite(run: RunState): RunState {
  if (!run.writing) return run;
  return { ...run, writing: { ...run.writing, decided: true } };
}

/** The stream errored: whichever step was active is the one that failed. */
export function failRun(run: RunState, message: string): RunState {
  const steps = { ...run.steps };
  const active = CHAT_STEPS.find((s) => steps[s].state === 'active');
  if (active) steps[active] = { ...steps[active], state: 'failed', detail: message };
  return { ...run, steps, error: message };
}

/** What the minimized pill shows; null when nothing is in flight. */
export function currentStepLabel(run: RunState): string | null {
  const active = CHAT_STEPS.find((s) => run.steps[s].state === 'active');
  if (!active) return null;
  if (active === 'writing' && run.writing) {
    return `Writing… ${run.writing.words.toLocaleString('en-US')} words`;
  }
  return STEP_LABELS[active];
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `docker exec -w /app inkwell-web-1 node --test src/features/ai/assistant-run.check.ts`
Expected: `# pass 7`.

- [ ] **Step 5: Gates and commit**

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/ai/assistant-run.ts src/features/ai/assistant-run.check.ts
git commit -m "feat(ai): pure run state for the assistant panel

One assistant turn is a run: which stages happened, how a write is going,
what failed. Every stream part is a transition on it, so the panel can be
reasoned about — and checked with node --test — without a browser."
```

---

### Task 8: TipTap extension — the protected, decorated write range

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/editor/ai-write-range.ts`
- Modify: `src/frontend.inkwell.ai/src/features/editor/tiptap-editor.tsx` (register)
- Modify: `src/frontend.inkwell.ai/src/app/globals.css` (styles)

**Interfaces:**
- Produces: `AiWriteRange` (TipTap `Extension`), `aiWriteRangeKey: PluginKey<AiWriteRangeState>`, `AiWriteRangeState = { from: number; to: number; streaming: boolean } | null`, meta shape `{ set: AiWriteRangeState } | { own: true }`, `getAiWriteRange(editor): AiWriteRangeState`.

- [ ] **Step 1: Implement the extension**

`ai-write-range.ts`:
```ts
import { Extension } from '@tiptap/core';
import { Plugin, PluginKey, type Transaction } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import type { Editor } from '@tiptap/react';
import { toast } from 'sonner';

/**
 * The range the assistant is writing into, or has written and not yet been
 * told to keep or discard.
 *
 * ## Why a plugin and not a pair of numbers in a hook
 *
 * Positions rot. If the writer types above the range while the assistant
 * streams into it, every position the hook remembered is off by what they
 * typed. ProseMirror's transaction mapping is the only correct way to follow
 * a range through concurrent edits, and mapping happens in a plugin's
 * `apply`. So the range lives here, is mapped on every transaction, and the
 * writer module reads it back each time it appends.
 *
 * ## What the plugin does with it
 *
 * - Decorates it: a tint on the AI-written text and a caret at the end while
 *   streaming. Decorations are view-only; they never reach `getJSON()` or
 *   autosave.
 * - Protects it: the writer's own edits inside the range are rejected until
 *   they Keep or Discard, with a toast saying so. Edits elsewhere pass. The
 *   assistant's own transactions carry `{ own: true }` in the meta and are
 *   always allowed.
 */
export type AiWriteRangeState = { from: number; to: number; streaming: boolean } | null;

type AiWriteRangeMeta = { set: AiWriteRangeState } | { own: true };

export const aiWriteRangeKey = new PluginKey<AiWriteRangeState>('aiWriteRange');

export function getAiWriteRange(editor: Editor): AiWriteRangeState {
  return aiWriteRangeKey.getState(editor.state) ?? null;
}

/** True when any step of `tr` touches the open interval (from, to). */
function touchesRange(tr: Transaction, from: number, to: number): boolean {
  let touched = false;
  for (const step of tr.steps) {
    step.getMap().forEach((oldStart, oldEnd) => {
      if (oldEnd > from && oldStart < to) touched = true;
    });
  }
  return touched;
}

export const AiWriteRange = Extension.create({
  name: 'aiWriteRange',

  addProseMirrorPlugins() {
    return [
      new Plugin<AiWriteRangeState>({
        key: aiWriteRangeKey,
        state: {
          init: () => null,
          apply(tr, value) {
            const meta = tr.getMeta(aiWriteRangeKey) as AiWriteRangeMeta | undefined;
            if (meta && 'set' in meta) return meta.set;
            if (!value || !tr.docChanged) return value;
            // Follow the range through whatever this transaction did. `-1`
            // and `1` bias the ends outward so an insertion exactly at an
            // edge lands inside the range (the assistant appends at `to`).
            return {
              ...value,
              from: tr.mapping.map(value.from, -1),
              to: tr.mapping.map(value.to, 1),
            };
          },
        },
        filterTransaction(tr, state) {
          const range = aiWriteRangeKey.getState(state);
          if (!range || !tr.docChanged) return true;
          const meta = tr.getMeta(aiWriteRangeKey) as AiWriteRangeMeta | undefined;
          if (meta && 'own' in meta) return true;
          if (!touchesRange(tr, range.from, range.to)) return true;
          toast.error('Finish or discard the AI text first');
          return false;
        },
        props: {
          decorations(state) {
            const range = aiWriteRangeKey.getState(state);
            if (!range || range.from === range.to) return DecorationSet.empty;
            const decorations = [
              Decoration.inline(range.from, range.to, { class: 'ai-writing' }),
            ];
            if (range.streaming) {
              decorations.push(
                Decoration.widget(range.to, () => {
                  const caret = document.createElement('span');
                  caret.className = 'ai-writing-caret';
                  caret.setAttribute('aria-hidden', 'true');
                  return caret;
                }, { side: 1 }),
              );
            }
            return DecorationSet.create(state.doc, decorations);
          },
        },
      }),
    ];
  },
});
```

- [ ] **Step 2: Register it**

In `tiptap-editor.tsx`, add `import { AiWriteRange } from './ai-write-range';` and, after the `Markdown,` entry in `extensions`:
```ts
      // The assistant's insertion range: mapped through every transaction,
      // decorated while streaming, protected from the writer's own edits
      // until they Keep or Discard. See ai-write-range.ts.
      AiWriteRange,
```

- [ ] **Step 3: Styles**

Append to `globals.css`, after the inline-code rules:
```css
/* ── AI write range ─────────────────────────────────────────────────────── */
/* Text the assistant is writing, or has written and not yet been kept. A tint,
   not a border: it has to read as "provisional" across headings, lists and
   paragraphs without changing their layout. */
.ai-writing {
  background: color-mix(in oklch, var(--primary) 10%, transparent);
  border-radius: 0.125rem;
  transition: background 200ms ease;
}
.dark .ai-writing {
  background: color-mix(in oklch, var(--primary) 18%, transparent);
}
/* The streaming caret: a blinking bar after the last inserted character. */
.ai-writing-caret {
  display: inline-block;
  width: 2px;
  height: 1em;
  vertical-align: text-bottom;
  margin-left: 1px;
  background: var(--primary);
  animation: ai-writing-blink 1s steps(2, start) infinite;
}
@keyframes ai-writing-blink {
  to {
    visibility: hidden;
  }
}
```

- [ ] **Step 4: Gates and commit**

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/editor/ai-write-range.ts src/features/editor/tiptap-editor.tsx src/app/globals.css
git commit -m "feat(editor): a mapped, decorated, protected range for assistant writes

Positions rot under concurrent edits; a plugin that maps the range through
every transaction is the only correct way to follow it. The same plugin tints
what the assistant wrote and rejects the writer's edits inside it until they
decide, so the streaming position stays predictable."
```

---

### Task 9: The article writer

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/article-writer.ts`

**Interfaces:**
- Consumes: `splitCompleteBlocks` (Task 6); `aiWriteRangeKey`, `getAiWriteRange` (Task 8); `@tiptap/markdown`'s `contentType: 'markdown'` (already registered).
- Produces: `createArticleWriter(editor, opts: { placement, selection?: { from: number; to: number } }): ArticleWriter` with `append(text)`, `finish()`, `keep()`, `discard()`, `isOpen(): boolean`.

- [ ] **Step 1: Implement**

`article-writer.ts`:
```ts
import type { Editor } from '@tiptap/react';
import { TextSelection } from '@tiptap/pm/state';
import { splitCompleteBlocks } from './article-blocks';
import { aiWriteRangeKey, getAiWriteRange } from '@/features/editor/ai-write-range';

export interface ArticleWriter {
  /** Feed a chunk of streamed Markdown. */
  append(text: string): void;
  /** The stream ended (normally or by Stop): parse the tail, stop the caret. */
  finish(): void;
  /** Accept: re-insert the range as one history event and release it. */
  keep(): void;
  /** Reject: delete exactly the range and release it. */
  discard(): void;
  /** True until keep() or discard() has run. */
  isOpen(): boolean;
}

/**
 * Drives the document while the assistant writes.
 *
 * ## Block by block
 *
 * Streamed Markdown is inserted only in blocks a blank line has closed
 * (`splitCompleteBlocks`), each parsed with `contentType: 'markdown'` so a
 * heading becomes a heading the moment it is complete. The unfinished tail
 * is a plain paragraph that is replaced in place as text arrives, so words
 * appear continuously. On `finish()` the tail is parsed the same way.
 *
 * ## Where the range lives
 *
 * Not here. The `aiWriteRange` plugin holds it and maps it through every
 * transaction; this module reads it back before each append, so the writer
 * typing elsewhere cannot make the assistant insert at a stale position.
 *
 * ## Undo as one step
 *
 * prosemirror-history groups changes by time AND adjacency, so a stream with
 * pauses would leave a dozen undo steps. Instead every append carries
 * `addToHistory: false` — invisible to undo — and `keep()` deletes the range
 * (still invisible) and re-inserts the same content as ONE recorded event.
 * The document does not visibly change; one Ctrl+Z afterwards removes the
 * whole write. Both dispatches happen in the same task, so nothing paints in
 * between.
 */
export function createArticleWriter(
  editor: Editor,
  opts: { placement: 'cursor' | 'replace_selection'; selection?: { from: number; to: number } },
): ArticleWriter {
  let buffer = '';
  /** Length of the plain-paragraph tail currently in the document, or 0. */
  let tailNodeSize = 0;
  let open = true;

  // ── Open the range ──────────────────────────────────────────────────────
  {
    const { state } = editor;
    let tr = state.tr;
    let from: number;
    if (opts.placement === 'replace_selection' && opts.selection) {
      const { from: f, to } = opts.selection;
      tr = tr.delete(f, to);
      from = f;
    } else {
      from = state.selection.to;
    }
    tr.setMeta(aiWriteRangeKey, { set: { from, to: from, streaming: true } });
    tr.setMeta('addToHistory', false);
    editor.view.dispatch(tr);
  }

  /**
   * Rewrites the end of the range: removes the plain tail if there is one,
   * inserts `blocks` (finished Markdown) and then `tail` (unfinished text) as
   * a plain paragraph. Invariant afterwards: the tail, if any, is the last
   * top-level node inside the range, and `tailNodeSize` is its size — so the
   * next call knows exactly what to delete.
   */
  const rewriteEnd = (blocks: string | null, tail: string | null) => {
    const range = getAiWriteRange(editor);
    if (!range) return;
    const at = range.to - tailNodeSize;
    let chain = editor.chain();
    if (tailNodeSize > 0) chain = chain.deleteRange({ from: at, to: range.to });
    if (blocks && blocks.trim()) chain = chain.insertContentAt(at, blocks, { contentType: 'markdown' });
    if (tail) {
      // After the blocks, if any: the range end has moved, so insert at the
      // mapped end rather than at `at`. `command` sees the transaction so far.
      chain = chain.command(({ tr, commands }) => {
        const end = tr.mapping.map(at);
        return commands.insertContentAt(end, {
          type: 'paragraph',
          content: [{ type: 'text', text: tail }],
        });
      });
    }
    chain
      .command(({ tr }) => {
        tr.setMeta(aiWriteRangeKey, { own: true });
        tr.setMeta('addToHistory', false);
        return true;
      })
      .run();
    if (tail) {
      const r = getAiWriteRange(editor);
      tailNodeSize = r ? editor.state.doc.resolve(r.to).nodeBefore?.nodeSize ?? 0 : 0;
    } else {
      tailNodeSize = 0;
    }
  };

  return {
    append(text) {
      if (!open) return;
      buffer += text;
      const { complete, rest } = splitCompleteBlocks(buffer);
      if (complete.length) {
        // Parsed blocks go in for good; the tail is rebuilt after them.
        rewriteEnd(complete.join('\n\n'), buffer = rest);
      } else {
        rewriteEnd(null, buffer);
      }
    },

    finish() {
      if (!open) return;
      if (buffer.trim()) rewriteEnd(buffer, null);
      else if (tailNodeSize) rewriteEnd(null, null);
      buffer = '';
      tailNodeSize = 0;
      const range = getAiWriteRange(editor);
      if (range) {
        const tr = editor.state.tr.setMeta(aiWriteRangeKey, { set: { ...range, streaming: false } });
        tr.setMeta('addToHistory', false);
        editor.view.dispatch(tr);
      }
    },

    keep() {
      if (!open) return;
      open = false;
      const range = getAiWriteRange(editor);
      if (!range) return;
      const slice = editor.state.doc.slice(range.from, range.to);
      // 1. Remove it invisibly. 2. Put it back as one recorded event. Same
      //    document before and after; one undo step from now on.
      const remove = editor.state.tr.delete(range.from, range.to);
      remove.setMeta(aiWriteRangeKey, { own: true });
      remove.setMeta('addToHistory', false);
      editor.view.dispatch(remove);
      const reinsert = editor.state.tr.replace(range.from, range.from, slice);
      reinsert.setMeta(aiWriteRangeKey, { set: null });
      reinsert.setSelection(TextSelection.near(reinsert.doc.resolve(range.from + slice.size)));
      editor.view.dispatch(reinsert);
    },

    discard() {
      if (!open) return;
      open = false;
      const range = getAiWriteRange(editor);
      if (!range) return;
      const tr = editor.state.tr.delete(range.from, range.to);
      tr.setMeta(aiWriteRangeKey, { set: null });
      tr.setMeta('addToHistory', false);
      tr.setSelection(TextSelection.near(tr.doc.resolve(range.from)));
      editor.view.dispatch(tr);
      editor.commands.focus();
    },

    isOpen: () => open,
  };
}
```

`rewriteEnd(complete.join('\n\n'), buffer = rest)` is deliberate: the finished blocks and the new tail go in as one chained transaction, so the document never shows the tail twice. If `resolve(r.to).nodeBefore` returns null when the tail paragraph is the last node of the document, use `editor.state.doc.resolve(r.to).parent.nodeSize` instead and say which one held in a comment.

- [ ] **Step 2: Typecheck**

Run: `docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"` — Expected `0`. `chain.command(({ tr }) => …)` is the TipTap way to stamp metas on a chained transaction; if the `insertContentAt` overload rejects the options object, import `type { InsertContentAtOptions }` is unnecessary — the Markdown extension's module augmentation (registered in Task 8's editor) provides `contentType`.

- [ ] **Step 3: Commit (browser verification comes in Task 14)**

```bash
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/ai/article-writer.ts
git commit -m "feat(ai): stream markdown into the document block by block

The writer inserts each block once a blank line has closed it and shows the
unfinished tail as plain text, so headings become headings as they complete
and words still appear continuously. Appends are invisible to history; Keep
re-inserts the range as one event so a single undo removes the whole write."
```

---

### Task 10: The hook — `useAiAssistant`

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/use-ai-assistant.ts`
- Delete: `src/frontend.inkwell.ai/src/features/ai/use-ai-chat.ts` (in Task 12, when its last consumer goes)

**Interfaces:**
- Consumes: `assistant-run.ts` (Task 7), `createArticleWriter` (Task 9), `getAuthHeaders`, `qk.ai.tokens()`, `API_URL`.
- Produces: `useAiAssistant({ articleId, editor }) → { messages, sendMessage(text), stop, status, error, runs: Record<string, RunState>, activeRun: RunState | null, openWrite: { editor, keep(), discard() } | null }`.

- [ ] **Step 1: Implement**

```ts
'use client';

import { useCallback, useMemo, useRef, useState } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport, type UIMessage } from 'ai';
import { useQueryClient } from '@tanstack/react-query';
import type { Editor } from '@tiptap/react';
import { API_URL } from '@/lib/constants';
import { getAuthHeaders } from '@/lib/api/auth-storage';
import { qk } from '@/lib/api/query-keys';
import { createArticleWriter, type ArticleWriter } from './article-writer';
import {
  createRun,
  applyStatus,
  applyArticleStart,
  applyArticleDelta,
  applyArticleDone,
  decideWrite,
  failRun,
  type RunState,
  type StatusData,
  type ArticleStartData,
  type ArticleDeltaData,
  type ArticleDoneData,
} from './assistant-run';

interface UseAiAssistantOptions {
  articleId?: string;
  editor: Editor | null;
}

/** The data parts the server writes; see article-write-stream.ts on the API. */
type AssistantDataParts = {
  status: StatusData;
  'article-start': ArticleStartData;
  'article-delta': ArticleDeltaData;
  'article-done': ArticleDoneData;
};
type AssistantMessage = UIMessage<never, AssistantDataParts>;

/**
 * The one place the assistant stream is interpreted.
 *
 * `useChat` owns the request and the messages; this hook owns two things the
 * SDK knows nothing about — the run state per assistant message (for the
 * panel) and the writer that mutates the document (for a write). Both are
 * fed from `onData`, which receives every transient `data-*` part in order.
 *
 * Runs are keyed by the assistant message id so a second question never
 * relabels the first, and so the panel can render a finished run's steps
 * next to its recap after the fact.
 */
export function useAiAssistant({ articleId, editor }: UseAiAssistantOptions) {
  const queryClient = useQueryClient();
  const [runs, setRuns] = useState<Record<string, RunState>>({});
  const [openWrite, setOpenWrite] = useState<ArticleWriter | null>(null);

  // The id of the assistant message currently streaming. Data parts do not
  // carry it, so it is taken from the SDK's `start` of each response and
  // held here for the parts that follow.
  const currentRunId = useRef<string | null>(null);
  // The editor selection at send time — positions the model never sees but
  // the writer needs if the model chooses replace_selection.
  const selectionAtSend = useRef<{ from: number; to: number; text: string } | null>(null);
  const writerRef = useRef<ArticleWriter | null>(null);

  const editorRef = useRef(editor);
  editorRef.current = editor;

  const updateRun = useCallback((fn: (run: RunState) => RunState) => {
    const id = currentRunId.current;
    if (!id) return;
    setRuns((prev) => ({ ...prev, [id]: fn(prev[id] ?? createRun()) }));
  }, []);

  const transport = useMemo(
    () =>
      new DefaultChatTransport<AssistantMessage>({
        api: `${API_URL}/ai/chat`,
        headers: getAuthHeaders,
        body: (): object => ({
          ...(articleId ? { articleId } : {}),
          ...(selectionAtSend.current?.text ? { selection: { text: selectionAtSend.current.text } } : {}),
        }),
      }),
    [articleId],
  );

  const chat = useChat<AssistantMessage>({
    transport,
    onData: (part) => {
      switch (part.type) {
        case 'data-status':
          updateRun((run) => applyStatus(run, part.data));
          break;
        case 'data-article-start': {
          const ed = editorRef.current;
          if (!ed) break;
          // A second write in the same run closes the first; the range can
          // only follow one stream.
          writerRef.current?.finish();
          const sel = selectionAtSend.current;
          const writer = createArticleWriter(ed, {
            placement: part.data.placement,
            selection:
              part.data.placement === 'replace_selection' && sel
                ? { from: sel.from, to: sel.to }
                : undefined,
          });
          writerRef.current = writer;
          setOpenWrite(writer);
          updateRun((run) => applyArticleStart(run, part.data));
          break;
        }
        case 'data-article-delta':
          writerRef.current?.append(part.data.text);
          updateRun((run) => applyArticleDelta(run, part.data));
          break;
        case 'data-article-done':
          writerRef.current?.finish();
          updateRun((run) => applyArticleDone(run, part.data));
          break;
      }
    },
    onError: (error) => {
      writerRef.current?.finish();
      updateRun((run) => failRun(run, error.message || 'Something went wrong. Please try again.'));
    },
    onFinish: ({ message, isAbort }) => {
      // Balance is decremented server-side at the end of the turn; this is
      // the earliest a refetch can return the new number.
      void queryClient.invalidateQueries({ queryKey: qk.ai.tokens() });
      if (isAbort) writerRef.current?.finish();
      // Move the run under its final message id in case the SDK's id for
      // the streaming message differed from the placeholder we keyed on.
      const placeholder = currentRunId.current;
      if (placeholder && placeholder !== message.id) {
        setRuns((prev) => {
          const { [placeholder]: run, ...rest } = prev;
          return run ? { ...rest, [message.id]: run } : prev;
        });
      }
      currentRunId.current = null;
    },
  });

  const sendMessage = useCallback(
    (text: string) => {
      const ed = editorRef.current;
      const sel = ed?.state.selection;
      selectionAtSend.current =
        ed && sel && !sel.empty
          ? { from: sel.from, to: sel.to, text: ed.state.doc.textBetween(sel.from, sel.to, '\n') }
          : null;
      // Key the run on a placeholder now; onFinish re-keys it on the real
      // assistant message id. Data parts arrive before that id is known.
      const id = `run-${Date.now()}`;
      currentRunId.current = id;
      setRuns((prev) => ({ ...prev, [id]: createRun() }));
      void chat.sendMessage({ text });
    },
    [chat],
  );

  const decide = useCallback(
    (action: 'keep' | 'discard') => {
      const writer = writerRef.current;
      if (!writer) return;
      if (action === 'keep') writer.keep();
      else writer.discard();
      writerRef.current = null;
      setOpenWrite(null);
      setRuns((prev) => {
        // The run that owns the open write is the last one with an undecided write.
        const entry = Object.entries(prev).find(([, r]) => r.writing && !r.writing.decided);
        if (!entry) return prev;
        return { ...prev, [entry[0]]: decideWrite(entry[1]) };
      });
    },
    [],
  );

  const activeRun = currentRunId.current ? (runs[currentRunId.current] ?? null) : null;

  return {
    messages: chat.messages,
    sendMessage,
    stop: chat.stop,
    status: chat.status,
    error: chat.error,
    runs,
    activeRun,
    openWrite: openWrite ? { keep: () => decide('keep'), discard: () => decide('discard') } : null,
    /** The id under which the streaming run is keyed, for the run card. */
    currentRunId: currentRunId.current,
  };
}
```

**Run keying note for the implementer:** the SDK creates the assistant `UIMessage` when the stream's `start` chunk arrives; its `id` is available as `chat.messages.at(-1)?.id` during streaming. If, while implementing, that id proves stable from the first `onData`, key runs on it directly and drop the placeholder/re-key logic — simpler is better. Verify in the browser which is true and leave a comment stating it.

- [ ] **Step 2: Typecheck**

Run: `docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"` — Expected `0`. If `UIMessage<never, …>` rejects `never` for metadata, use `unknown`.

- [ ] **Step 3: Commit**

```bash
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/ai/use-ai-assistant.ts
git commit -m "feat(ai): one hook that reads the assistant stream into runs and the writer

useChat owns the request; this owns what the SDK cannot know — the run state
each assistant message shows in the panel, and the writer that mutates the
document during a write. Both are fed from onData in stream order."
```

---

### Task 11: Panel pieces — run card, keep/discard bar, pill

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/ai-run-card.tsx`
- Create: `src/frontend.inkwell.ai/src/features/ai/ai-keep-discard-bar.tsx`
- Create: `src/frontend.inkwell.ai/src/features/ai/ai-assistant-pill.tsx`
- Modify: `src/frontend.inkwell.ai/src/features/ai/ai-chat-message.tsx` (remove `onInsert`, `sources`)

**Interfaces:**
- Consumes: `RunState`, `CHAT_STEPS`, `STEP_LABELS`, `currentStepLabel` (Task 7); `AiSources` (existing; takes `chunks: RetrievedChunk[]`).
- Produces: `<AiRunCard run text />`, `<AiKeepDiscardBar editor onKeep onDiscard />`, `<AiAssistantPill label unread onClick />`.

- [ ] **Step 1: Run card**

`ai-run-card.tsx`:
```tsx
'use client';

import { useState } from 'react';
import { Check, ChevronDown, Loader2, XCircle } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { cn } from '@/lib/utils';
import { AiSources } from './ai-sources';
import { CHAT_STEPS, STEP_LABELS, type RunState } from './assistant-run';

interface AiRunCardProps {
  run: RunState;
  /** The model's text for this turn — an answer, or the recap after a write. */
  text: string;
}

/**
 * One assistant turn: the steps that ran, the write if there was one, the
 * model's text. Steps render in the fixed order and only once they have
 * fired, so a question shows three rows and a write shows five; the panel
 * never shows a step the pipeline did not run.
 */
export function AiRunCard({ run, text }: AiRunCardProps) {
  const [sourcesOpen, setSourcesOpen] = useState(false);
  const steps = CHAT_STEPS.filter((s) => s !== 'done' && run.steps[s].state !== 'pending');

  return (
    <div className="flex gap-3">
      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-muted">
        <Loader2
          className={cn('h-4 w-4', run.steps.done.state === 'done' || run.error ? 'hidden' : 'animate-spin')}
        />
        {(run.steps.done.state === 'done' || run.error) && (
          <span className="text-xs">✦</span>
        )}
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        {/* Step list */}
        <ol className="space-y-1 text-xs text-muted-foreground">
          {steps.map((step) => {
            const s = run.steps[step];
            const label =
              s.state === 'active'
                ? step === 'writing' && run.writing
                  ? `Writing into your article… ${run.writing.words.toLocaleString('en-US')} words`
                  : STEP_LABELS[step]
                : (s.detail ?? STEP_LABELS[step].replace('…', ''));
            const expandable = step === 'retrieval' && s.state === 'done' && (s.chunks?.length ?? 0) > 0;
            return (
              <li key={step} className="flex flex-col">
                <button
                  type="button"
                  disabled={!expandable}
                  onClick={() => setSourcesOpen((o) => !o)}
                  className={cn('flex items-center gap-2 text-left', expandable && 'hover:text-foreground')}
                >
                  {s.state === 'active' && <Loader2 className="h-3 w-3 animate-spin" />}
                  {s.state === 'done' && <Check className="h-3 w-3 text-ink-success" />}
                  {s.state === 'failed' && <XCircle className="h-3 w-3 text-destructive" />}
                  <span className={cn(s.state === 'failed' && 'text-destructive')}>{label}</span>
                  {expandable && (
                    <ChevronDown className={cn('h-3 w-3 transition-transform', sourcesOpen && 'rotate-180')} />
                  )}
                </button>
                {expandable && sourcesOpen && s.chunks && (
                  <div className="mt-1 pl-5">
                    <AiSources chunks={s.chunks} />
                  </div>
                )}
              </li>
            );
          })}
        </ol>

        {/* The write, once finished */}
        {run.writing?.done && (
          <p className="text-xs text-muted-foreground">
            Wrote {run.writing.words.toLocaleString('en-US')} words
            {run.writing.headings && run.writing.headings.length > 0
              ? `, ${run.writing.headings.length} section${run.writing.headings.length === 1 ? '' : 's'}`
              : ''}
            {!run.writing.decided && ' — keep or discard it in the editor'}
          </p>
        )}

        {/* Answer or recap */}
        {text.trim() && (
          <div
            data-ai-bubble=""
            className="prose prose-sm prose-slate max-w-none rounded-lg bg-muted px-3 py-2 text-sm dark:prose-invert"
          >
            <ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown>
          </div>
        )}
      </div>
    </div>
  );
}
```

Check `AiSources`'s prop name in `ai-sources.tsx` (`chunks`) and that `RetrievedChunkLite` is assignable to its `RetrievedChunk` (same fields). If `AiSources` renders its own "Sources used" header, pass a prop or leave it — the row already says what it is; prefer removing the duplicate header inside `AiSources` if it exists, with a comment.

- [ ] **Step 2: Keep/Discard bar**

`ai-keep-discard-bar.tsx`:
```tsx
'use client';

import { useEffect, useState } from 'react';
import type { Editor } from '@tiptap/react';
import { Check, Trash2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { getAiWriteRange } from '@/features/editor/ai-write-range';

interface AiKeepDiscardBarProps {
  editor: Editor;
  onKeep: () => void;
  onDiscard: () => void;
}

/**
 * The decision, where the text is. Anchored under the end of the assistant's
 * range rather than inside the panel, because the writer is looking at what
 * was written when they decide. Position comes from `coordsAtPos` on every
 * editor update and on scroll; the range itself lives in the plugin.
 *
 * Not a BubbleMenu: that primitive shows on a non-empty selection, and here
 * there is none — the range is a plugin state, not a selection.
 */
export function AiKeepDiscardBar({ editor, onKeep, onDiscard }: AiKeepDiscardBarProps) {
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  useEffect(() => {
    const update = () => {
      const range = getAiWriteRange(editor);
      if (!range) return setPos(null);
      const coords = editor.view.coordsAtPos(range.to);
      setPos({ left: coords.left, top: coords.bottom + 8 });
    };
    update();
    editor.on('update', update);
    editor.on('selectionUpdate', update);
    window.addEventListener('scroll', update, true);
    window.addEventListener('resize', update);
    return () => {
      editor.off('update', update);
      editor.off('selectionUpdate', update);
      window.removeEventListener('scroll', update, true);
      window.removeEventListener('resize', update);
    };
  }, [editor]);

  if (!pos) return null;

  return (
    <div
      role="group"
      aria-label="AI text: keep or discard"
      className="fixed z-40 flex items-center gap-1 rounded-lg border bg-popover p-1 shadow-lg"
      style={{ left: Math.max(8, Math.min(pos.left, window.innerWidth - 220)), top: pos.top }}
    >
      <Button size="xs" onClick={onKeep}>
        <Check className="mr-1 size-3" />
        Keep
      </Button>
      <Button size="xs" variant="ghost" onClick={onDiscard}>
        <Trash2 className="mr-1 size-3" />
        Discard
      </Button>
      <span className="px-1 text-[11px] text-muted-foreground">Ctrl+Z undoes after Keep</span>
    </div>
  );
}
```

- [ ] **Step 3: The pill**

`ai-assistant-pill.tsx`:
```tsx
'use client';

import { Loader2, Sparkles } from 'lucide-react';
import { cn } from '@/lib/utils';

interface AiAssistantPillProps {
  /** Current step while a request is in flight; null when idle. */
  label: string | null;
  /** A run finished while minimized and has not been looked at. */
  unread: boolean;
  onClick: () => void;
}

/**
 * The minimized dock. A round sparkle button when idle; while a request is
 * in flight it grows into a pill with the live step, so the writer can
 * minimize and still watch it work. A dot marks a run that finished unseen.
 */
export function AiAssistantPill({ label, unread, onClick }: AiAssistantPillProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label ? `AI assistant: ${label}` : 'Open AI assistant'}
      className={cn(
        'fixed right-4 bottom-4 z-50 flex h-12 items-center gap-2 rounded-full bg-primary text-primary-foreground shadow-lg transition-[width,padding] duration-200',
        label ? 'px-4' : 'w-12 justify-center',
      )}
    >
      {label ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-5 w-5" />}
      {label && <span className="max-w-[220px] truncate text-sm">{label}</span>}
      {unread && !label && (
        <span
          aria-hidden="true"
          className="absolute top-1 right-1 h-2.5 w-2.5 rounded-full bg-ink-warning-text ring-2 ring-background"
        />
      )}
    </button>
  );
}
```

- [ ] **Step 4: Slim `AiChatMessage`**

In `ai-chat-message.tsx`: remove the `onInsert` and `sources` props, the `Button`/`CornerDownLeft`/`AiSources`/`RetrievedChunk` imports, the insert button and the sources block. Keep the role icon, the bubble, and the Markdown rendering (assistant bubbles are still used for answers when there is no run — e.g. history restored later; today the run card renders the text, so the assistant branch stays for completeness). Update the docblock to say the card, not this component, renders a run.

- [ ] **Step 5: Gates and commit**

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
cd src/frontend.inkwell.ai && git add src/features/ai/ai-run-card.tsx src/features/ai/ai-keep-discard-bar.tsx src/features/ai/ai-assistant-pill.tsx src/features/ai/ai-chat-message.tsx
git commit -m "feat(ai): run card, keep/discard bar and minimized pill

The card shows only the steps that fired, in pipeline order, with the
retrieval row expanding to its passages. The decision bar sits under the
range in the document, because that is where the writer is looking. The pill
carries the live step so minimizing does not mean losing sight of the work."
```

---

### Task 12: The dock, and wiring it into the editor

**Files:**
- Create: `src/frontend.inkwell.ai/src/features/ai/ai-assistant-dock.tsx`
- Modify: `src/frontend.inkwell.ai/src/features/editor/use-autosave.ts`
- Modify: `src/frontend.inkwell.ai/src/features/editor/editor-shell.tsx`
- Delete: `src/frontend.inkwell.ai/src/features/ai/ai-chat-panel.tsx`, `src/frontend.inkwell.ai/src/features/ai/use-ai-chat.ts`

**Interfaces:**
- Consumes: `useAiAssistant` (Task 10), `AiRunCard`, `AiKeepDiscardBar`, `AiAssistantPill` (Task 11), `AiChatMessage`, `AiTokenIndicator`, `AiQuotaNotice`, `useAiQuota`, `AiCorpusNotice`, `useAiTokens`, `ScrollArea`, `Notice`.
- Produces: `<AiAssistantDock open onOpenChange articleId editor onWriteOpenChange />`; `useAutoSave({ …, suspended })`.

- [ ] **Step 1: Autosave suspension**

In `use-autosave.ts`: add `suspended?: boolean; // true while the assistant has an open write range` to `UseAutoSaveOptions`, destructure it (`suspended = false`), and at the top of the scheduling effect:
```ts
    // While the assistant is writing — or waiting for Keep/Discard — the
    // document holds provisional text. Saving it would persist a half-written
    // article as the draft. The effect re-runs when `suspended` clears, so the
    // pending change is saved then.
    if (suspended) return;
```
Add `suspended` to that effect's dependency array.

- [ ] **Step 2: The dock**

`ai-assistant-dock.tsx` — carry over from `ai-chat-panel.tsx` (read it first): the spent-balance verdict state (`balanceReadAtSend`, `spentByReply`, render-time derivation), the auto-scroll sentinel, the quota/corpus notices, the input form. Replace the `Sheet` with:

```tsx
'use client';

import { useEffect, useRef, useState } from 'react';
import { ChevronDown, Send, Square, X } from 'lucide-react';
import type { Editor } from '@tiptap/react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Notice } from '@/components/shared/notice';
import { cn } from '@/lib/utils';
import { useAiAssistant } from './use-ai-assistant';
import { AiChatMessage } from './ai-chat-message';
import { AiRunCard } from './ai-run-card';
import { AiKeepDiscardBar } from './ai-keep-discard-bar';
import { AiAssistantPill } from './ai-assistant-pill';
import { AiTokenIndicator } from './ai-token-indicator';
import { AiQuotaNotice, useAiQuota } from './ai-quota-notice';
import { AiCorpusNotice } from './ai-corpus-notice';
import { useAiTokens } from './use-ai-tokens';
import { currentStepLabel } from './assistant-run';

interface AiAssistantDockProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  articleId?: string;
  editor: Editor | null;
  /** Lets the shell suspend autosave while a write range is open. */
  onWriteOpenChange: (open: boolean) => void;
}

const MINIMIZED_KEY = 'inkwell.ai-dock.minimized';

function getMessageText(parts: Array<{ type: string; text?: string }>): string {
  return parts.filter((p) => p.type === 'text' && p.text).map((p) => p.text!).join('');
}

/**
 * The floating assistant: an anchored card bottom-right, or a pill.
 *
 * Not a Sheet. The sheet trapped nothing but still drew a backdrop and sat
 * over a third of the editor; the writer wants the assistant beside the
 * document, not in front of it. The card is `fixed`, has no overlay, and the
 * editor stays fully interactive behind it — which the Keep/Discard bar in
 * the document relies on.
 */
export function AiAssistantDock({ open, onOpenChange, articleId, editor, onWriteOpenChange }: AiAssistantDockProps) {
  const { messages, sendMessage, stop, status, runs, activeRun, openWrite, currentRunId } =
    useAiAssistant({ articleId, editor: editor ?? null });
  const { exhausted } = useAiQuota();
  const { dataUpdatedAt: balanceReadAt } = useAiTokens();
  const [input, setInput] = useState('');
  const [minimized, setMinimized] = useState(false);
  const [unread, setUnread] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);
  const isStreaming = status === 'streaming' || status === 'submitted';

  // Remembered per browser; the conversation itself is not.
  useEffect(() => {
    try {
      setMinimized(localStorage.getItem(MINIMIZED_KEY) === '1');
    } catch {
      /* private mode etc. — default expanded */
    }
  }, []);
  const setMinimizedPersisted = (value: boolean) => {
    setMinimized(value);
    try {
      localStorage.setItem(MINIMIZED_KEY, value ? '1' : '0');
    } catch {
      /* ignore */
    }
    if (!value) setUnread(false);
  };

  // A run that finished while minimized earns the dot.
  const wasStreaming = useRef(false);
  if (wasStreaming.current && !isStreaming && minimized) setUnread(true);
  wasStreaming.current = isStreaming;

  // Tell the shell when a write range opens/closes, for autosave.
  useEffect(() => onWriteOpenChange(openWrite !== null), [openWrite, onWriteOpenChange]);

  // ── spent-balance verdict: copy the block from ai-chat-panel.tsx verbatim
  //    (balanceReadAtSend / spentByReply, derived during render) ──

  // Auto-scroll, as before, plus the pill label so the last row is visible.
  const renderedLength = messages.reduce((t, m) => t + getMessageText(m.parts as never).length, 0);
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' });
  }, [renderedLength, messages.length, isStreaming, exhausted, activeRun]);

  // Escape minimizes.
  useEffect(() => {
    if (!open || minimized) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMinimizedPersisted(true);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isStreaming || exhausted) return;
    // setBalanceReadAtSend(balanceReadAt);  ← from the copied verdict block
    sendMessage(input.trim());
    setInput('');
  };

  if (!open) return null;

  const pillLabel = activeRun ? currentStepLabel(activeRun) : null;

  return (
    <>
      {editor && openWrite && (
        <AiKeepDiscardBar editor={editor} onKeep={openWrite.keep} onDiscard={openWrite.discard} />
      )}

      {minimized ? (
        <AiAssistantPill label={pillLabel} unread={unread} onClick={() => setMinimizedPersisted(false)} />
      ) : (
        <section
          aria-label="AI Writing Assistant"
          className={cn(
            'fixed z-50 flex flex-col overflow-hidden rounded-xl border bg-popover text-sm text-popover-foreground shadow-xl',
            // Desktop: anchored card. Phone: full width, bottom-anchored.
            'right-4 bottom-4 h-[560px] max-h-[calc(100vh-2rem)] w-[380px] max-w-[calc(100vw-2rem)]',
            'max-sm:inset-x-2 max-sm:bottom-2 max-sm:h-[70vh] max-sm:w-auto',
          )}
        >
          <header className="flex items-start justify-between border-b px-4 py-3">
            <div>
              <h2 className="text-base font-medium text-foreground">AI Writing Assistant</h2>
              <AiTokenIndicator />
            </div>
            <div className="flex items-center gap-1">
              <Button variant="ghost" size="icon-sm" aria-label="Minimize" onClick={() => setMinimizedPersisted(true)}>
                <ChevronDown />
              </Button>
              <Button variant="ghost" size="icon-sm" aria-label="Close" onClick={() => onOpenChange(false)}>
                <X />
              </Button>
            </div>
          </header>

          <AiQuotaNotice className="mx-4 mt-3" />
          <AiCorpusNotice className="mx-4 mt-3" />

          {/* min-h-0 is load-bearing — see the previous ticket's note in git history. */}
          <ScrollArea className="min-h-0 flex-1 px-4 py-4">
            {messages.length === 0 ? (
              <div className="flex h-full items-center justify-center text-center text-sm text-muted-foreground">
                <p>Ask me anything about your article, or tell me what to write — I&apos;ll put it straight into the document.</p>
              </div>
            ) : (
              <div className="space-y-4">
                {messages.map((msg) => {
                  const text = getMessageText(msg.parts as never);
                  if (msg.role === 'user') return <AiChatMessage key={msg.id} role="user" content={text} />;
                  const run = runs[msg.id] ?? (msg.id === messages.at(-1)?.id && currentRunId ? runs[currentRunId] : undefined);
                  return run ? (
                    <AiRunCard key={msg.id} run={run} text={text} />
                  ) : (
                    <AiChatMessage key={msg.id} role="assistant" content={text} />
                  );
                })}
                {/* spent-balance Notice, copied from ai-chat-panel.tsx */}
                <div ref={endRef} />
              </div>
            )}
          </ScrollArea>

          <form onSubmit={handleSubmit} className="flex items-center gap-2 border-t px-4 py-3">
            <Input
              value={input}
              onChange={(e) => setInput(e.target.value)}
              placeholder={exhausted ? 'No AI tokens remaining' : 'Ask, or say what to write…'}
              className="flex-1"
              disabled={isStreaming || exhausted}
            />
            {isStreaming ? (
              <Button type="button" size="icon" variant="outline" aria-label="Stop" onClick={() => stop()}>
                <Square className="h-4 w-4" />
              </Button>
            ) : (
              <Button type="submit" size="icon" aria-label="Send message" disabled={exhausted || !input.trim()}>
                <Send className="h-4 w-4" />
              </Button>
            )}
          </form>
        </section>
      )}
    </>
  );
}
```

The two `← copy` markers are instructions to the implementer: lift those exact blocks from `ai-chat-panel.tsx` (they were reviewed and verified in the previous ticket) before deleting it. There must be no marker left in the committed file.

- [ ] **Step 3: Editor shell**

In `editor-shell.tsx`:
- Replace `import { AiChatPanel } from '@/features/ai/ai-chat-panel';` with `import { AiAssistantDock } from '@/features/ai/ai-assistant-dock';`.
- Add state `const [aiWriteOpen, setAiWriteOpen] = useState(false);` and a stable callback `const handleWriteOpenChange = useCallback((v: boolean) => setAiWriteOpen(v), []);`.
- Pass `suspended: aiWriteOpen` into `useAutoSave({ … })`.
- Add the unload guard:
```ts
  // A half-written range must not be lost silently to a tab close, nor saved
  // by a route change. beforeunload asks; a client-side navigation cannot be
  // intercepted the same way, so the dock's writer is discarded by unmount
  // (its range plugin state dies with the editor).
  useEffect(() => {
    if (!aiWriteOpen) return;
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [aiWriteOpen]);
```
- Replace the `<AiChatPanel …/>` block with:
```tsx
      {/* Floating AI assistant — anchored bottom-right, minimizes to a pill */}
      {currentId && (
        <AiAssistantDock
          open={aiPanelOpen}
          onOpenChange={setAiPanelOpen}
          articleId={currentId}
          editor={editor}
          onWriteOpenChange={handleWriteOpenChange}
        />
      )}
```
- Update the toolbar button comment (it "opens the chat panel" → "opens the floating assistant").

- [ ] **Step 4: Delete the replaced files**

```bash
cd src/frontend.inkwell.ai && git rm -q src/features/ai/ai-chat-panel.tsx src/features/ai/use-ai-chat.ts
grep -rn "ai-chat-panel\|use-ai-chat\|useAiChat\|AiChatPanel" src && echo "STILL REFERENCED" || echo "clean"
```
Expected: `clean`. `use-ai-retrieval.ts`'s `fetchAiRetrieval` may now be unused — if `grep -rn fetchAiRetrieval src` shows only its definition, remove the function and its docblock (the hook `useAiCorpus`/notice still uses the query).

- [ ] **Step 5: Gates**

```bash
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"
```
Expected: both `0`. The lint rule against setState-in-effect applies: the `unread` derivation above is render-time on purpose; the `minimized` read from localStorage in an effect is the sanctioned seed-from-storage case — if eslint flags it, derive the initial value with a lazy `useState(() => …)` guarded by `typeof window !== 'undefined'` instead.

- [ ] **Step 6: Commit**

```bash
cd src/frontend.inkwell.ai && git add -A src/features/ai src/features/editor
git commit -m "feat(ai): floating assistant dock replaces the side sheet

The assistant is now a card anchored bottom-right, with no backdrop, that
minimizes to a pill carrying the live step. Replies stream into the document
through the writer; the panel shows the run and the recap. Autosave is
suspended while a write range is open so a half-written article is never
persisted, and a tab close asks first."
```

---

### Task 13: Full gates, dev image, and a first browser pass

**Files:** none.

- [ ] **Step 1: All gates, both repos**

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "api tsc: $?"
docker exec -w /app inkwell-api-1 npm run lint >/dev/null; echo "api lint: $?"
docker exec -w /app inkwell-api-1 npm test 2>&1 | tail -5; echo "api test: $?"
docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "web tsc: $?"
docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "web eslint: $?"
docker exec -w /app inkwell-web-1 node --test src/features/ai/article-blocks.check.ts src/features/ai/assistant-run.check.ts 2>&1 | tail -8; echo "web checks: $?"
```
Expected: all `0`.

- [ ] **Step 2: Browser — smoke**

Using the Chrome extension on `http://frontend.inkwell.ai/editor/<an article of the signed-in premium account>` (ask the user to be signed in; never type a password):
1. Click *AI Assistant*. Expected: a card bottom-right, no backdrop, editor still clickable behind it.
2. Send "Is my introduction too long?". Expected: run card shows Reading your draft ✓, Loading your style profile ✓, Thinking… then ✓, then the answer as Markdown. No change to the document. Token indicator decreases.
3. Place the cursor at the end of the document; send "Write two short paragraphs with a heading about why Hello World matters." Expected: steps as above, then Searching your published work ✓ (with a count or "nothing close enough"), Writing into your article… with a rising word count; in the document, tinted text grows block by block, the heading appears as a heading once its blank line arrives; the caret blinks at the end; the Keep/Discard bar appears under the last block when done; the panel shows "Wrote N words, 1 section — keep or discard it in the editor" and then the one-line recap.
4. Click into the tinted text and type. Expected: toast "Finish or discard the AI text first", nothing inserted. Type above the range: allowed; the tint stays on the right text.
5. Click Keep. Expected: tint gone, bar gone, autosave status changes to Saving/Saved. Press Ctrl+Z once. Expected: the entire write disappears. Ctrl+Shift+Z brings it back.
6. Send another write; click Stop mid-stream. Expected: streaming stops, caret gone, bar appears, panel's writing row ends with the count so far. Click Discard. Expected: the range is deleted exactly; text around it untouched.
7. Minimize during a write. Expected: pill reads "Writing… N words" and updates; expanding shows the run. Minimize, let a run finish, expected: dot on the pill.
8. Select a paragraph; send "Make this more formal." Expected: the model chooses `replace_selection`; the selection is replaced by the tinted stream; Keep works.
9. Resize to 400px wide (measure with JS; do not resize the window — see memory note). Expected: the card is full-width and 70vh; nothing overflows.

Record what was seen for each, and what was not. Fix defects found; re-run affected gates; commit fixes with their own messages.

---

### Task 14: Adversarial review

- [ ] **Step 1: Dispatch** a `general-purpose` agent told to be adversarial, given: this plan's path, the spec's path, the branch names, `references/environment.md`, and the instruction to re-run every gate itself and not modify code. Ask specifically for concrete failure scenarios around: range mapping under concurrent edits (type above / below / inside during a stream), the block splitter on lists and fences, the Keep re-insert trick vs. history, abort billing, a model that calls the tool twice, a `replace_selection` whose selection the user has since changed, the run re-keying in `onFinish`, and `min-h-0` still present on the ScrollArea.

- [ ] **Step 2: Fix** every finding with a failure scenario yourself; re-run the gates the fix could affect; commit each fix with its reason.

---

### Task 15: Spec reconcile

**Files:**
- Modify: `spec.inkwell.ai/5-ai-design.md` (§9 chat, §10 quota note, §11 stream/failure)
- Modify: `spec.inkwell.ai/2-features.md` §3 (AI assistant behaviour)
- Modify: `spec.inkwell.ai/10-requirements.md` (new FR/US rows, append-only ids)
- Modify: `docs/superpowers/specs/2026-09-13-floating-ai-assistant-design.md` (superproject; the two corrections below)

- [ ] **Step 1: What this change makes false — find and fix**

```bash
cd spec.inkwell.ai && grep -n -i "pipeTextStreamToResponse\|text stream\|SSE\|side panel\|sheet\|Insert into article\|slide-out\|503" 5-ai-design.md 2-features.md 3-user-flows.md 9-implementation-guide.md 10-requirements.md
```
For each hit that describes the old panel or the old wire format, rewrite it or add a dated correction note per the repo's convention.

- [ ] **Step 2: Record the design**

In `5-ai-design.md`, a new subsection under §9 (or wherever chat is described) titled "Assistant turn (2026-09-xx)": the stream contract table from the spec (parts, payloads), the tool, the step order **draft → profile → thinking → retrieval (write only) → writing → done**, the overdraft/Keep/Discard behaviour, and the failure mode (error part with "AI is temporarily unavailable", no longer a 503).

In `2-features.md` §3.x: the floating dock, minimize/pill, in-document writing with Keep/Discard, the recap.

In `10-requirements.md`: append (next free ids, never renumber) FR rows for: model-routed write vs answer; in-document streaming with Keep/Discard; live step status; one-line recap; and US rows for the writer ("tell the assistant what to write and watch it appear in my draft", "see what the assistant is doing while it works").

- [ ] **Step 3: Correct the design spec**

In the superproject's design doc, under a heading "Corrections during implementation": (1) retrieval runs inside the write tool, so the step order is draft → profile → thinking → retrieval → writing → done and a question never runs retrieval; (2) undo-as-one is achieved by `addToHistory: false` appends plus a delete-and-reinsert on Keep, not by history grouping; (3) provider outage is an `error` part on an open stream, not a 503, because the pre-model stages are streamed live; (4) `data-article-start` was added to the contract so the client opens the range independently of tool-part timing; (5) the Keep/Discard bar is positioned via `coordsAtPos`, not BubbleMenu, which requires a selection.

- [ ] **Step 4: Commit**

```bash
cd spec.inkwell.ai && git add -A && git commit -m "docs(ai): the assistant turn — routing tool, typed stream, in-document writing

Records the floating assistant as built: the model decides between writing
into the document and answering, the response is a typed stream the panel
reads for status, and written text arrives block by block with Keep/Discard.
Retrieval now runs only for writes, and an outage is an error part rather
than a 503; both are stated so the spec does not describe the previous shape."
cd ../ && git add docs/superpowers/specs/2026-09-13-floating-ai-assistant-design.md && git commit -m "docs: corrections to the floating assistant design found during implementation"
```

---

### Task 16: Ship

- [ ] **Step 1: Attribution check, per repo, as separate commands**

```bash
git -C src/backend.inkwell.ai log origin/main..HEAD --format="%B" | grep -icE "claude|co-authored|generated with"
git -C src/frontend.inkwell.ai log origin/main..HEAD --format="%B" | grep -icE "claude|co-authored|generated with"
git -C spec.inkwell.ai log origin/main..HEAD --format="%B" | grep -icE "claude|co-authored|generated with"
```
Expected: `0` three times.

- [ ] **Step 2: Push and open PRs** — backend first, then frontend, then spec; cross-link. Each body carries: the cost model, the stream contract, the decisions and corrections, what was verified with actual results (gate exit codes, the browser checklist with what was seen), and what was **not** verified (no frontend test suite; the two pure checks are the only automated frontend coverage; whichever browser items could not be run).

- [ ] **Step 3: Hold the merge.** Ask the user once. On "merge": `--merge --delete-branch` in order, sync each repo to `main`, then `chore/bump-floating-ai-assistant` in the superproject moving all three pointers in one commit (the backend and frontend halves depend on each other — say so in the message), plus the superproject's `docs/` branch for the design doc if not already merged.

---

## Self-review against the spec

- §3 stream contract → Tasks 2, 3, 5 (plus `data-article-start`, recorded in Task 15).
- §3.2 tool, §3.3 status mapping → Task 5 (order corrected: retrieval inside the tool).
- §3.4 selection → Tasks 4, 10.
- §3.5 billing sum, one row → Task 5 `onFinish`/`onAbort`.
- §3.6 reasoning not forwarded → Task 5 `sendReasoning: false`.
- §4.1 range mapping → Task 8. §4.2 block-by-block → Tasks 6, 9. §4.3 decoration → Task 8. §4.4 undo → Task 9 (mechanism corrected). §4.5 protection + toast → Task 8. §4.6 bar → Task 11. §4.7 autosave → Task 12. §4.8 leaving → Task 12. §4.9 removed insert → Tasks 11, 12.
- §5.1–5.5 dock, pill, entries, errors, mobile → Tasks 11, 12, 13.
- §6 hook/data flow → Task 10. §7 risks → Tasks 0, 8, 9, 10, 14. §8 verification → Tasks 2, 3, 6, 7, 13, 14 (jest fakes at the module boundary, not a fake model — `ai` cannot load in jest). §9 out of scope → untouched. §10 repos → Tasks 15, 16.

No placeholders remain except the two explicit "copy from ai-chat-panel.tsx" instructions in Task 12, which name the exact blocks. Type names are consistent: `RunState`, `ArticleWriter`, `AiWriteRangeState`, `PartWriter`, `StatusPart`, `ChatStep` are defined once each and used by those names.
