# Retrieval-augmented generation

## What it is for

The editor's assistant claims to help a writer sound like themselves. That claim
is only honest if the model can *see* how they write, so every chat message and
every inline edit carries excerpts of that writer's own published work, selected
by similarity to what they just asked.

Without retrieval the alternative is instructing a model to "match the writer's
tone" — an instruction it cannot follow, because it has never read them. The
pipeline exists to replace that instruction with evidence.

The same retrieval serves two other consumers: the semantic half of search, and
the Portfolio Insights report a magazine reads before licensing.

---

## The pipeline

```
TipTap document
      │
      ▼
  chunkArticle()          paragraph-level blocks, heading-prefixed
      │
      ▼
  embedMany()             Gemini, 1536 dimensions, batches of 96
      │
      ▼
  article_chunks          vector(1536) + HNSW index
      │
      ▼
  findSimilarChunks()     cosine, top 5, similarity ≥ 0.60
      │
      ▼
  buildChatSystemPrompt() three labelled context blocks, ~2000 token ceiling
```

Embedding happens **off the request path**, on a BullMQ queue, so publishing does
not wait for an embedding API.

---

## 1 · Chunking

`src/ai/chunking.ts`

An article is split at **block** level rather than by a fixed character window,
because a paragraph is already the unit an author thinks in.

**Why chunk at all.** Embedding a whole article produces one vector for several
thousand words. It matches everything weakly and nothing precisely. Paragraph
chunks are what let retrieval return *the passage about tides* rather than *the
article that mentions tides somewhere*.

**Two bounds, each for a different reason.**

| | | |
|---|---|---|
| `MIN_CHUNK_CHARS` | 120 | Below this a block is too thin to embed. "Yes." produces an embedding dominated by two tokens and matches almost nothing. Short blocks are **merged forward** into the next, not discarded — a one-line paragraph is often the punchline of the one before it |
| `MAX_CHUNK_CHARS` | 1200 | Not a model limit — the embedding model accepts 8191 tokens. It is a *retrieval quality* limit: one vector must represent the whole chunk, so a long chunk averages several ideas into one point and stops matching any of them sharply |

**Heading context is the subtle part.** Each chunk is prefixed with its nearest
preceding heading. A paragraph reading *"It rarely works below 8°C"* is nearly
meaningless alone and its embedding lands nowhere useful; prefixed with
*"Cold-water tactics"* it embeds near the subject it is actually about.

Headings are therefore never chunks of their own — a bare heading is three words
of context and no content. And the prefix is stored in `content`, not merely used
for the vector, because the stored text is what gets injected into the prompt
later: the model benefits from the same context the vector did.

## 2 · Embedding

`src/ai/embeddings.service.ts`

**Gemini, not OpenAI, and the reason is worth stating plainly.** The design
specified OpenAI's `text-embedding-3-small`. OpenAI no longer grants trial
credit, so a key without billing returns `insufficient_quota` on the first call,
and adding credit requires an international payment card this project does not
have. Gemini's embedding endpoint is free-tier.

The substitution is invisible downstream because `outputDimensionality` pins the
width to the same **1536** the schema already declared, so the `vector(1536)`
column and its HNSW index were never touched.

**The dimension constant lives beside the column definition**, not beside the
model. Changing the model is not a config tweak: vectors of different widths
cannot be compared, so a switch invalidates every stored embedding and demands a
full re-embed. Keeping the constant next to the schema means the two cannot be
edited independently.

**Batches of 96.** Deliberately small: a failed batch is retried whole, so a
large batch turns one bad input into a large redundant re-send — and on a free
tier that re-send counts against the same rate limit that caused the failure.

**The key is read lazily**, unlike every other AI service here, which reads its
key at construction and fails fast. That is right for the API and wrong for the
**worker**: a missing embedding key would become a crash loop in which no job of
any kind runs, analytics and token resets included. A missing key must degrade
retrieval, not take the background processor down.

## 3 · Retrieval

`src/ai/retrieval.service.ts`

Cosine similarity over the HNSW index, top **5** chunks, with a similarity floor
of **0.60**.

**The floor is the most important number in the pipeline, and it was measured.**

Vector search always returns its K nearest neighbours — there is no such thing as
"no results". Without a floor, asking a fermentation writer about tides still
returns five fermentation chunks, and the model treats them as relevant
background. That is *worse* than no retrieval, because it actively misleads.

The threshold started at 0.35 and filtered nothing, because the embedding model
does not use the full [0,1] range — two texts on entirely unrelated subjects
still score around 0.5. Measured against this corpus:

| | |
|---|---|
| On-topic (query matches the corpus) | **0.63 – 0.73** |
| Off-topic (nothing relevant exists) | **0.48 – 0.58** |

0.60 sits in the gap. Verified by asking a fermentation writer a surfcasting
question: at 0.35 it injected five irrelevant chunks scoring 0.52–0.55; at 0.60
it correctly injects nothing.

> **This number is a property of the model, not of similarity in general.** A
> threshold tuned for one embedding model is meaningless for another. If the
> model changes, re-measure — the code says so at the constant.

**Top-K is a token budget, not a preference.** Injected context — memory plus
chunks — has to stay under roughly 2000 tokens or it crowds out the conversation
itself in the model's window.

## 4 · Prompt injection

`src/ai/prompts/chat.prompt.ts`

Three kinds of context, doing three different jobs, and **labelled distinctly in
the prompt**:

1. **The current article** — what the writer is working on now. Task context,
   truncated to ~6000 characters. It used to go in whole, which made the prompt
   grow without bound as the writer wrote: the longer the article, the likelier
   the request blew the context window, so the failure arrived exactly when
   someone had done the most work.
2. **The style profile** — a compact, stable description of how this writer
   sounds, extracted from their corpus by a background job. Identical on every
   request.
3. **Retrieved passages** — excerpts from their own past work, selected by
   similarity to this question.

The last two are complementary rather than redundant: the profile is a persona
that holds even when retrieval finds nothing, and the passages are concrete
evidence relevant to *this* question.

**Why the labelling matters.** Conflating them causes a specific failure — the
model treats a passage from an old article as part of the current draft and
starts "continuing" text the writer never wrote here.

---

## The same retrieval, in search

`src/search/search.service.ts`

Search runs a lexical ranking (Postgres `tsvector` with weighted `ts_rank`) and a
semantic ranking (the retrieval above) **concurrently**, then fuses them with
reciprocal rank fusion:

```
score(doc) = Σ  1 / (k + rank(doc, ranking))
```

**Fusion is on position, not score, and that is what makes it possible at all.**
`ts_rank` and cosine similarity are unrelated scales with no meaningful
conversion between them; adding or averaging the raw numbers would be arithmetic
on incomparable units. Ranks are the common currency.

A document missing from one ranking contributes nothing for it, rather than
scoring zero — **absence means "not retrieved", not "irrelevant"**.

Lexical alone misses paraphrase; vector alone misses proper nouns and exact
titles. The fusion is why searching for a half-remembered phrase and searching
for a writer's name both work.

One detail with a correctness consequence: the semantic ranking is the one half
that **cannot filter itself** — it is writer-facing retrieval, viewer-agnostic by
construction and shared with chat. Its ids are screened for blocks *before*
fusion rather than after, because fusion produces the result count, and a blocked
article surviving into the fused list would inflate the total even if it were
dropped from the page.

---

## What breaks, and what guards it

`src/ai/model-inventory.ts`

**Twice a provider retired a model out from under a live feature, and both times
the breakage was silent for days.**

- `llama-3.3-70b-versatile` was the only model chat and inline editing called.
  When it was dropped, both features were dead.
- `llama-3.1-8b-instant` was the moderation classifier. When it was dropped, the
  call caught the 404, returned null, and the chain fell through to **CLEAN** —
  so every publish passed unmoderated. A dead classifier and a working one
  produced the identical verdict.

Neither was detectable from inside the process: the test suite mocks the AI SDK
wholesale, so it passes cheerfully against a model id that no longer exists.

Two things came out of that:

- **One inventory file** listing every model id the product calls, so a liveness
  check cannot drift from what is actually used. When ids lived in each service,
  "check every model we use" meant "check every model somebody remembered to
  add".
- **A scheduled liveness probe** that calls the real API, because only that tells
  you.

**Failover order is policy, and it is tested.** The streaming endpoints try two
Groq models before Gemini — two rather than one because a Groq rate limit is
per-model, so when the larger model is throttled the smaller one has its own
budget and answers.

---

## Honest limitations

- **Retrieval is scoped to one writer's own corpus.** It is a "sound like
  yourself" tool, not a research tool; it cannot cite anyone else's work.
- **A writer with little published work gets little retrieval**, and the assistant
  degrades toward a generic one. The style profile is what carries it in that
  case.
- **The similarity floor is tuned to one embedding model** and to this corpus. It
  is measured, not universal.
- **Chunks are re-created wholesale on every edit** — delete, then reinsert —
  because of the uniqueness constraint on `(article_id, chunk_index)`.
- **Moderation fails open by design.** A dead classifier lets a publish through
  rather than blocking the product; the inventory and the liveness probe exist
  because that trade is only acceptable if you find out quickly.
