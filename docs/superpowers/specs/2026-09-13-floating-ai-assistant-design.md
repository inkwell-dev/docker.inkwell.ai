# Floating AI assistant — design

*2026-09-13. Approved in conversation, section by section; this is the written
form. Supersedes the side-sheet chat panel shipped through
`fix/ai-quota-and-chat-panel`.*

## 1. The request, in the user's words

> we will make the panel floating … there is a tab floating, and it could be
> minimized to a button at the bottom right … it doesn't blur the background …
> I wanted to think and state that it's thinking and then execute and states
> … if it makes researches or something like that, states that it's making
> researches … a bit of status bar, small one … the insertion of the article
> or the generation of the article happens inside the WYSIWYG field, not
> inside the chat panel. And the chat panel only makes recaps. For example,
> "I finished integrating the article" … I wanna make it very professional.

Speech (talking to the assistant and hearing it answer) is explicitly a later
piece of work. This design does not build it, but §3 is shaped so that it can
be added as more event types on the same stream.

## 2. Decisions

| Question | Decision |
|---|---|
| How does a reply get routed to the document vs the panel? | **The model decides, via a tool** (`write_to_article`). |
| Where does written content go, and what happens at the end? | **At the cursor** (or replacing the selection), visibly marked while streaming, with **Stop**; then **Keep / Discard**. |
| What is the recap and who writes it? | **The model**, as a one-line message after the tool returns, in the same request. |
| How does the panel behave? | **Anchored bottom-right**, no backdrop, **minimizes to a round button**; not draggable. |
| How detailed is the status? | **The pipeline's real steps only**, as a compact step list with counts. No web research is claimed, because none exists. |
| Does the minimized button show live status? | **Yes** — a pill with the current step while a request is in flight. |
| Architecture for routing + writing | **Approach 1**: the tool call carries the *intent*; the server streams the *content* as plain text on the same response. |

Assumptions made without asking, stated here so they can be overturned in one
line:

- The assistant exists only in the editor, as today.
- Conversations live in memory for the editor session; no persistence across
  reloads.
- User messages render as plain text; model text renders as Markdown.
- The inline-edit popup is untouched.
- Mobile must not break, but is not a design focus.

## 3. Backend: one request, one typed stream

`POST /ai/chat` keeps its route, `AiQuotaGuard`, and DTO shape. The response
changes from a plain text stream (`pipeTextStreamToResponse`) to an AI SDK v7
**UI-message stream** (`createUIMessageStream` →
`pipeUIMessageStreamToResponse`). Every consumer reads typed parts from that
one response.

### 3.1 Parts

| Part type | Emitted by | Payload |
|---|---|---|
| `data-status` | each pipeline stage | `{ step, state, detail? }` — `step ∈ draft \| retrieval \| profile \| thinking \| writing \| done`, `state ∈ active \| done \| failed`, `detail` a short human string, e.g. `"4 passages from 2 articles"` |
| `text` (built-in) | the outer model call | a chat **answer**, or the **recap** after a write |
| `tool-write_to_article` (built-in tool part) | the outer model call | input `{ placement: 'cursor' \| 'replace_selection', brief: string }` |
| `data-article-delta` | the tool's `execute` | `{ id, text }` — plain-text chunk of the content being written |
| `data-article-done` | the tool's `execute` | `{ id, words, headings: string[] }` — the factual result the recap is grounded in |
| `reasoning` (built-in) | the outer model call, Groq only | consumed server-side to drive the `thinking` status; not rendered |

`id` on the article parts is one per write, so a run that (unexpectedly)
writes twice cannot interleave.

### 3.2 The tool

```ts
write_to_article: tool({
  description: 'Write or rewrite article text directly in the writer\'s document. ' +
    'Call this whenever the writer asks you to produce or change article text. ' +
    'Never paste article text into the chat instead.',
  inputSchema: z.object({
    placement: z.enum(['cursor', 'replace_selection']),
    brief: z.string().describe('One line: what you are about to write'),
  }),
  execute: async ({ placement, brief }, { abortSignal }) => { … },
})
```

- Declared on the outer `streamText` with `stopWhen: stepCountIs(3)` (decide →
  tool → recap; a third step is headroom, not a plan).
- `execute` runs the **existing generation path** as a second `streamText`
  through `streamWithFallback`: same system prompt (draft, retrieved passages,
  style profile — unchanged), the conversation, plus the `brief` and the
  selection when `placement = 'replace_selection'`. Each chunk is forwarded as
  `data-article-delta`. It returns `{ words, headings }`, which the SDK feeds
  back to the outer model, which then writes the recap as ordinary text.
- `placement = 'replace_selection'` with no selection in the request degrades
  to `cursor`; the server does not error.
- A plain question never calls the tool: one model call, text answer, today's
  cost exactly.

### 3.3 Status mapping

| Step | `active` when | `done` when | `detail` |
|---|---|---|---|
| `draft` | request received, article context loaded | immediately after | `"1,240 words read"` (or "empty draft") |
| `retrieval` | `findSimilarChunks` starts | it returns | `"N passages from M articles"` / `"nothing close enough"` |
| `profile` | `writerMemory.get` starts | it returns | `"style profile loaded"` / `"no profile yet"` |
| `thinking` | first `reasoning` chunk (Groq), or request sent to the model (Gemini) | first text or tool-call chunk | — |
| `writing` | tool `execute` starts | `data-article-done` | live word count is client-side; the server sends the final |
| `done` | outer stream finishes | — | — |

Retrieval and profile run concurrently today; both statuses are emitted
concurrently and complete independently. The client renders them in the fixed
order above regardless of arrival.

### 3.4 Request body

`ChatDto` gains an optional `selection?: { text: string }` — what the model
sees when the writer asks about "this paragraph". The document positions are
not sent: the client records the selection range it had at send time and hands
it to the writer if the model chooses `replace_selection`.

### 3.5 Unchanged

`AiQuotaGuard`; `settleUsage` — it now bills the **sum** of both calls'
`totalTokens`, one `ai_interactions` row per request with `outputText` = the
article content when a write happened, else the answer; the fallback chain
(applies to both calls); `POST /ai/inline`; `GET /ai/tokens`;
`GET /ai/retrieval-debug`.

### 3.6 Reasoning

Groq's provider is configured with `reasoningFormat: 'parsed'` so gpt-oss's
reasoning arrives as `reasoning` parts. They drive the `thinking` status and are
**not** forwarded to the client. Reasoning tokens are already billed today;
nothing changes in cost.

## 4. Editor: writing into the document

A module `features/ai/article-writer.ts` owns every mutation the assistant
makes to the TipTap document. Interface:

```ts
createArticleWriter(editor, { placement, selection? }) → {
  append(text: string): void;   // buffer + block-by-block insert
  finish(): void;               // parse the trailing block
  stop(): void;                 // = finish(), reached via abort
  keep(): void;                 // drop the decoration, release the range
  discard(): void;              // delete exactly the tracked range
}
```

### 4.1 Range

On creation it records the insertion range: the cursor for `cursor`; for
`replace_selection` the selection is deleted first and the range starts there.
The range is tracked by **mapping through every transaction**
(`tr.mapping.map(pos)`), so the writer typing elsewhere does not move it out
from under the stream.

### 4.2 Block-by-block growth

- Incoming text accumulates in a buffer.
- On each blank line, the completed block is inserted as real nodes via
  `insertContentAt(end, block, { contentType: 'markdown' })` (the
  `@tiptap/markdown` extension registered in the last ticket).
- The in-progress block is a plain paragraph replaced in place as text
  arrives, so words appear continuously.
- `finish()` parses the trailing block the same way.
- Only blank-line-terminated blocks are parsed, so a list item split across
  chunks stays plain until its block completes. Worst case: a paragraph that
  becomes a list one chunk later.

### 4.3 Decoration

A ProseMirror plugin decorates the tracked range: a soft tint on AI-written
blocks and a caret glyph at the range end while streaming. Decorations are not
document content; they never reach `getJSON()` or autosave.

### 4.4 History

Every append is stamped with the same `addToHistory` group so one Ctrl+Z after a
write removes the entire write, not the last chunk. `discard()` is one
transaction for the same reason.

### 4.5 Protection

While a range is open (streaming, or awaiting Keep/Discard), a
`filterTransaction` rejects the writer's own edits inside it and a toast says
"Finish or discard the AI text first". Edits elsewhere are allowed.

### 4.6 Keep / Discard bar

A small strip anchored under the last AI-written block (the same BubbleMenu
primitive the toolbar uses), with **Keep** and **Discard**. It appears on
`finish()` — reached by normal completion or by Stop. Keep drops the decoration
and releases the range; Discard deletes exactly the range. The bar lives in the
document, not the panel, because the decision belongs where the text is.

### 4.7 Autosave

`use-autosave.ts` gains a `suspended` flag. It is set while a range is open and
cleared on Keep/Discard, so a half-written article is never persisted. The
existing debounce is unchanged.

### 4.8 Leaving mid-write

`beforeunload` warns while a range is open; on a client-side route change,
`discard()` runs first so a half-written range is never saved.

### 4.9 Removed

The per-reply "Insert into article" button and `handleInsert` in the panel.
`textToParagraphs` stays — the inline popup uses it.

## 5. The floating panel

`AiChatPanel` (a `Sheet`) is replaced by `AiAssistantDock`, mounted once in
`EditorShell`.

### 5.1 Expanded

Fixed card, bottom-right: `w-[380px] h-[560px] max-h-[calc(100vh-2rem)]`,
`z-50`, no backdrop, no focus trap; the editor stays interactive. Header: title,
`AiTokenIndicator`, minimize (chevron) and close (×). Then `AiQuotaNotice` /
`AiCorpusNotice` as today. Then the conversation (`min-h-0 flex-1` scroll region
from the last ticket), then the input. Escape minimizes. Close hides the dock;
the toolbar's *AI Assistant* button reopens it.

### 5.2 Minimized

A 48px round sparkle button in the same corner. While a request is in flight it
becomes a **pill** showing the current step's label ("Searching your work…",
"Writing… 412 words") with a subtle progress ring. A run that finished while
minimized shows a dot until the dock is opened. Click expands.

Minimized/expanded is remembered in `localStorage`; the conversation lives in
component state for the editor session.

### 5.3 Conversation entries

1. **User message** — plain text, as now.
2. **Run card** — one per request:
   - the step list from `data-status`, in fixed order, each row spinner → tick →
     detail; a `failed` state renders the server's message;
   - if a write happened: "Writing into your article… *N* words" with a live
     counter, then "Wrote *N* words, *M* sections" on `data-article-done`;
   - the model's text (answer or recap) rendered as Markdown;
   - the retrieval row's detail is clickable and expands to the passages —
     this replaces the separate "Sources used" block.
3. **Spent-balance notice** — unchanged from the last ticket.

### 5.4 Errors

A provider failure (503 before first byte, as today) renders as a failed step in
the run card with the server's message. A failure *during* a write ends it via
`finish()` so the Keep/Discard bar appears and nothing is silently lost. The
quota 403 is prevented client-side before sending, as today.

### 5.5 Mobile (<640px)

Expanded: full width, bottom-anchored, `h-[70vh]`. Minimized: unchanged.

## 6. Client state and data flow

`useAiAssistant({ articleId, editor })` replaces `useAiChat`. It wraps `useChat`
with `DefaultChatTransport` (UI-message protocol) and one `onData` handler,
the only place the stream is interpreted:

```
data-status              → runs[msgId].steps[step] = { state, detail }
tool-write_to_article    → writer = createArticleWriter(editor, input); runs[msgId].writing = { words: 0 }
  (input-available)
data-article-delta       → writer.append(text); runs[msgId].writing.words = countWords(...)
data-article-done        → writer.finish(); runs[msgId].writing = { ...done, awaitingDecision: true }
text                     → rendered from message.parts, as today
```

- `runs` is component state keyed by assistant message id, so step lists,
  counters and recaps survive re-renders and minimizing, and a second request
  never relabels an earlier run.
- One writer per run; torn down on Keep/Discard.
- `body` reads the editor's selection at send time and includes it when
  non-empty.
- Stop calls the SDK's `stop()`; the server sees the closed socket, aborts the
  outer stream, and `settleUsage` bills what was generated (as on abort today).
  The client treats it as `finish()`.
- `onFinish` invalidates the token query; the spent-balance verdict logic from
  the last ticket is reused unchanged.

## 7. Risks and their answers

| Risk | Answer |
|---|---|
| Model answers in text for an obvious write | Prompt rule + explicit tool description; **spike on gpt-oss-120b and Gemini before any UI work**. |
| Model calls the tool for a question | `brief` is visible in the run card; Discard is one click. Tune the prompt if it recurs. |
| Fallback model and tools | Both calls go through `streamWithFallback`; the tool is model-agnostic. Covered by the same spike. |
| Reasoning tokens | Already billed; only made visible. |
| Partial Markdown at block boundaries | Only blank-line-terminated blocks are parsed (§4.2). |
| Writer edits inside the range mid-write | Rejected with a toast (§4.5). |
| Navigation mid-write | `beforeunload` + `discard()` on route change (§4.8). |
| Two writes in one run | Per-write `id` on article parts; the client keeps one writer per id and closes the previous with `finish()` if a second starts. |
| Autosave races | Suspended while a range is open (§4.7). |

## 8. Verification

- **Backend (jest, in `inkwell-api-1`):** a fake model that emits a tool call,
  asserting the exact ordered sequence of `data-status`, `tool-*`,
  `data-article-delta`, `data-article-done`, `text` parts; a fake that answers
  in text, asserting no article parts; `settleUsage` billing the sum of both
  calls; `replace_selection` without a selection degrading to `cursor`.
- **Frontend:** `tsc` + `eslint` (no test suite exists). `article-writer.ts`
  keeps a **pure core** (block splitting, word counting, range mapping helpers)
  exercisable from a Node script during the build. DOM behaviour is checked in
  Chrome: block-by-block growth, decoration, Stop, Keep, Discard, one-step undo,
  autosave paused, protected range, minimized pill updating live, mobile width.
- **Spike first:** a throwaway script against the running API proving the
  routing decision on both models for "write an article about X" and "is my
  intro too long?".

## 9. Out of scope

Web research (a second tool, later); speech (later; the stream design leaves
room for it); persisting conversations across reloads; the inline-edit popup; a
draggable or dockable panel.

## 10. Repos touched

backend (`ai.service.ts`, `ai.controller.ts`, `dto/chat.dto.ts`,
`prompts/chat.prompt.ts`, new specs) · frontend (`features/ai/*`,
`features/editor/editor-shell.tsx`, `use-autosave.ts`, `tiptap-editor.tsx`) ·
spec (`5-ai-design.md` §§9–11, `2-features.md` §3, `10-requirements.md`
FR/US rows for routing, in-document writing, Keep/Discard and status).

## 11. Corrections during implementation (2026-09-14)

Each of these was ruled during execution with this spec as the authority; the
spec text above is left as approved, and these notes say where the build
departs from it and why.

1. **Retrieval runs inside the write tool, not before the outer call.** The
   outer (routing/recap) prompt carries the article and the style profile only;
   passages are fetched for the brief once the model has decided to write. So a
   question never runs the embedding search, and the honest step order is
   draft → profile → thinking → *retrieval → writing* → done (§3.3's table
   listed retrieval before thinking). Cost of a write: the lean outer prompt
   twice plus one full inner call.
2. **`data-article-start`** was added to the contract (§3.1) so the client
   opens its insertion range from a data part, independent of the SDK's tool
   part timing.
3. **Undo-as-one is not history grouping.** prosemirror-history groups by time
   *and* adjacency, so a stream with pauses would leave many undo steps. Appends
   are `addToHistory: false`; on Keep the range is restored to its pre-write
   state invisibly and then the AI text is re-applied as one recorded event —
   "replace the original selection with the AI text" — so a single undo also
   brings a replaced selection back. Discard restores the replaced selection
   from an anchor held in plugin state.
4. **The range opens at a block boundary.** The writer never streams into the
   middle of the writer's own paragraph: for `cursor` it opens *after* the block
   the cursor is in (before it when that block is empty); for
   `replace_selection` a whole-node selection replaces the node. Written text is
   therefore always a run of whole top-level nodes. The range end is tracked
   from each transaction's step map, and the writer's own transactions set the
   range explicitly rather than relying on mapping bias. Covered by a headless
   TipTap harness (`article-writer.check.ts`, 10 cases) that reproduces the
   original defect — streaming into a paragraph's end deleted it — before the
   fix.
5. **A user insertion exactly at a range edge stays outside it.** Mapping bias
   is outward only for the writer's own transactions; inward for everyone else;
   both ends the same way while the range is empty.
6. **Provider outage is an `error` part on an open 200 stream**, not a 503
   (§5.4): the pre-model stages are streamed live, so the response is open
   before a model is chosen. The copy is unchanged.
7. **A stop mid-write is billed as an estimate** — inner prompt plus text
   produced, ~4 characters per token — because `onFinish` does not fire on
   abort.
8. **The Keep/Discard bar is positioned by `coordsAtPos`**, not BubbleMenu
   (which needs a selection); it stacks above the dock and clamps to the
   viewport, since the dock disables its own input until the bar is used.
9. **A new turn is refused while a write awaits Keep/Discard.** The hook's
   `sendMessage` returns `false`, the dock disables input with "Keep or discard
   the AI text first", and the close button is disabled for the same span. The
   alternative — auto-keeping on the next send — would make a decision the
   writer never made.
10. **`replace_selection` degrades to `cursor`** when, at write start, the
    document no longer holds the send-time selection text at the recorded
    positions.
11. **Autosave suspension clears a timer already scheduled**, or the render
    that saw the writer's opening transaction would still save a half-written
    draft 1.5 s later.
12. **A stopped run is marked stopped** in the panel (every active step ends
    with "Stopped"), and unmounting the editor mid-write stops the request and
    discards the range.

Known and deliberately left: StarterKit's trailing-node rule appends an empty
paragraph after a write that ends the document with a heading; the streaming
caret renders at the block boundary rather than after the last word.
