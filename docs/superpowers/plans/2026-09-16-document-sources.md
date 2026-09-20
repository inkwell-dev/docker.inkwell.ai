# Document Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A writer uploads PDF/DOCX/TXT/MD into a private library, attaches documents to an article, and the assistant draws on them as cited reference material in both answers and writes.

**Architecture:** Three new tables (`documents`, `document_chunks`, `article_documents`) beside `article_chunks`; a private MinIO bucket reached only through presigned URLs; a new BullMQ queue `documents` whose worker processor extracts text (pdf-parse / mammoth), chunks it with the existing splitter keeping the page, embeds with the existing Gemini service and stores vectors; a second retrieval query over `document_chunks` scoped to owner + attached + ready; a new `documents` status step in the assistant turn and a "Reference material" prompt block distinct from the voice block. Frontend: `/dashboard/documents` library page, a Sources strip in the dock, and a "Reading your documents" run-card row whose passages open the file at the cited page.

**Tech Stack:** NestJS 11, Drizzle + Postgres 16/pgvector, BullMQ, MinIO (`minio@8`), `pdf-parse@2.4.5`, `mammoth@1.12.3`, `ai@7` + `@ai-sdk/google` (embeddings), jest; Next.js 16 / React 19, TanStack Query v5, Axios, `node --test` for pure modules.

**Spec:** `docs/superpowers/specs/2026-09-16-document-sources-design.md` (superproject `docker.inkwell.ai`). Read it first; it is the authority and this plan argues from it.

## Global Constraints

Copied from the spec and from `.claude/skills/inkwell-ticket/references/environment.md` — every task's requirements include these.

- **Nothing runs on the host.** Backend commands: `docker exec -w /app inkwell-api-1 <cmd>`; worker: `inkwell-worker-1`; frontend: `inkwell-web-1`. Backend tests are `npm test` (never bare `npx jest`); lint is `npm run lint` (never bare eslint). The only exceptions are `pnpm add --lockfile-only` on the host (Task 0) and `pandoc` on the host (Task 0 fixtures).
- **Jest cannot load `ai`, `@ai-sdk/*` (ESM-only).** Any class a spec imports must not value-import `EmbeddingsService`, `RetrievalService`, `AiService`, `UploadsService`'s consumers of those, or anything under `src/ai/` that reaches them. Use `import type` + an import-free DI token (the `CONTENT_MODERATION` pattern in `src/moderation/content-moderation.token.ts`).
- **Schema changes:** edit `src/database/schema/*.ts` → `docker exec -w /app inkwell-api-1 npx drizzle-kit generate` → read the emitted SQL → `make dci-migrate` (from `docker.inkwell.ai`) → confirm with `psql`. Commit the `.sql`, `meta/NNNN_snapshot.json`, `meta/_journal.json`. After a schema change run `npm test` WITHOUT `SKIP_DB_PUSH=1`.
- **`forbidNonWhitelisted` ValidationPipe:** every request field must be declared on a DTO; an undeclared field is a 400.
- **Ownership:** a document that does not exist or is not the caller's answers **`404 "Document not found"`, never 403** (spec §8): every document query filters `owner_id = caller` and passes through `assertFound(row, 'Document')` from `src/common/ownership.ts`.
- **Caps and copy, verbatim:** `DOCUMENT_MAX_BYTES = 10 * 1024 * 1024`; `DOCUMENT_MAX_COUNT = 20`; `DOCUMENT_MAX_PAGES = 200`; `DOCUMENT_MIN_TEXT_CHARS = 50`; `DOCUMENT_FILE_URL_TTL_SECONDS = 600`; 21st document → `409 "You already have 20 documents"`; no text layer → `"This PDF has no text layer — export it with selectable text"`; too many pages → `"Documents are limited to 200 pages"`; any other ingestion throw → `"Couldn't process this document — try again"`; prompt block header sentence exactly as spec §6; empty Sources strip: `"No sources attached — the assistant writes from your own published work."`; library cap line: `"20 of 20 — delete one to upload another"`; pending over 60 s: `"Waiting…"`.
- **Retrieval:** `topK = 5`, `minSimilarity = 0.60`, query embedded as `RETRIEVAL_QUERY`, documents embedded as `RETRIEVAL_DOCUMENT`; scoped to `owner_id = caller AND deleted_at IS NULL AND status = 'ready' AND id IN attached`.
- **Status step:** `documents` sits between `profile` and `thinking` in `CHAT_STEPS` on BOTH sides (`src/ai/chat-status.ts` and `src/features/ai/assistant-run.ts`). The step is emitted only when the article has at least one attached document (spec §6/§7: a step that never fires is never rendered).
- **Every function, logic block and non-obvious line gets a comment** (user rule). Match the surrounding comment density.
- **No AI attribution anywhere** — commits, PRs, comments. Commit messages in the user's voice: what changed and why.
- **Branches:** backend `feat/document-sources`, frontend `feat/document-sources`, spec `docs/document-sources`, each from `origin/main` (backend main `82e0d4e`, frontend `e5127c5`, spec `0ba59e8`). Do not merge or push unless the user says so.
- **Frontend has no test runner**: pure modules get a `*.check.ts` run with `docker exec -w /app inkwell-web-1 node --test <file>`; gates are `npx tsc --noEmit` and `npx eslint . --max-warnings=0` in the container. React-compiler lint rules apply (no mutation of props/state, no refs read during render).
- **Never type a password in the browser.** Browser checks use the page the user signed into; live API checks from `.mjs` probes in the container, deleted afterwards. Delete `ai_interactions` probe rows and restore token balances after live tests.

---

## File map

**Backend (`src/backend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/database/schema/enums.ts` | `documentStatusEnum` |
| `src/database/schema/documents.ts` (new) | `documents`, `documentChunks`, `articleDocuments` tables |
| `src/database/schema/index.ts` | export the new file |
| `drizzle/0007_*.sql` + meta | generated migration |
| `src/ai/chunking.ts` | `chunkText(pages)` beside `chunkArticle`, sharing `splitLongText` |
| `src/documents/document-limits.ts` (new, import-free) | caps, copy, type map, `documentTypeFromFilename` |
| `src/documents/documents.queue.ts` (new, import-free) | queue + job names + payload |
| `src/documents/document-extractor.token.ts` (new, import-free) | `DOCUMENT_EXTRACTOR`, `DOCUMENT_EMBEDDER` tokens + interfaces |
| `src/documents/document-extractor.service.ts` (new) | pdf-parse / mammoth / utf-8 → pages |
| `src/uploads/minio-client.ts` (new) | `createMinioClient(config)` shared by both storage services |
| `src/uploads/uploads.service.ts` | use the factory (no behaviour change) |
| `src/documents/document-storage.service.ts` (new) | private `documents` bucket: presign PUT/GET, read, remove |
| `src/documents/document-ingestion.service.ts` (new) | `ingest(id)`, `purge(id)` — the worker's work |
| `src/documents/processors/documents.processor.ts` (new, worker only) | `@Processor(DOCUMENTS_QUEUE)` |
| `src/worker.module.ts` | register queue + providers |
| `src/documents/dto/*.ts` (new) | `PresignDocumentDto`, `RegisterDocumentDto`, `SetArticleDocumentsDto` |
| `src/documents/documents.service.ts` (new) | library CRUD, cap, retry, file URL, article attachments |
| `src/documents/documents.controller.ts` (new) | the eight routes |
| `src/documents/documents.module.ts` (new) + `src/app.module.ts` | wiring |
| `src/ai/document-retrieval.query.ts` (new, jest-loadable) | `searchDocumentChunks(db, vector, opts)` |
| `src/ai/retrieval.service.ts` | `findSimilarDocumentChunks` |
| `src/ai/chat-status.ts` | `documents` step, `passages` on status parts |
| `src/ai/article-write-stream.ts` | `withStatus` forwards `passages` |
| `src/ai/prompts/reference.prompt.ts` (new) | `buildReferenceBlock`, `citationLabel` |
| `src/ai/prompts/chat.prompt.ts` | both prompts take `referenceBlock` |
| `src/ai/ai.service.ts` | load attached docs, `documents` stage, pass the block |
| `test/documents/*.spec.ts`, `test/documents/fixtures/*` | DB-backed specs + real-file fixtures |

**Frontend (`src/frontend.inkwell.ai`)**

| File | Responsibility |
|---|---|
| `src/lib/constants.ts`, `src/lib/api/query-keys.ts` | `ROUTES.dashboardDocuments`, `qk.documents.*`, `qk.articles.documents()` |
| `src/features/documents/document-types.ts` (new) | API shapes + client-side limits |
| `src/features/documents/document-upload.ts` (new) | presign → XHR PUT with progress → register |
| `src/hooks/use-documents.ts` (new) | list (polling), upload, delete, retry |
| `src/hooks/use-article-documents.ts` (new) | GET/PUT attachments |
| `src/features/documents/documents-view.tsx`, `document-status-chip.tsx` (new) | the library page |
| `src/app/(main)/dashboard/documents/page.tsx` (new), `src/components/layout/nav-items.tsx` | route + nav |
| `src/features/ai/ai-sources-strip.tsx` (new) | chips + Attach picker in the dock |
| `src/features/ai/ai-assistant-dock.tsx` | mount the strip |
| `src/features/ai/document-citation.ts` (+ `.check.ts`) (new) | `documentFileUrl`, `citationLabel` |
| `src/features/ai/assistant-run.ts` (+ `.check.ts`) | `documents` step + `passages` |
| `src/features/ai/ai-document-sources.tsx` (new), `ai-run-card.tsx` | the expandable row |

**Spec (`spec.inkwell.ai`)**: `5-ai-design.md` §9.5, `2-features.md` §3.7, `6-database-schema.md` §5.5–5.7, `3-user-flows.md` §6.5, `4-system-architecture.md` pipelines, `10-requirements.md` FR-84..87 / US-70..72.

---

### Task 0: Spike — libraries install, real extraction, similarity floor

**Files:**
- Modify: `src/backend.inkwell.ai/package.json`, `pnpm-lock.yaml`
- Create: `src/backend.inkwell.ai/test/documents/fixtures/two-pages.pdf`, `test/documents/fixtures/sample.docx`, `test/documents/fixtures/sample.md`
- Throwaway (delete after): `src/backend.inkwell.ai/spike-extract.mjs`, `spike-similarity.mjs`

**Interfaces:**
- Produces: the fixtures every later spec reads; a finding on whether `pdf-parse` loads under CommonJS (Task 3 depends on it) and whether 0.60 holds for this corpus (Task 7's constant).

- [ ] **Step 1: Add the dependencies through the host lockfile** (from `docker.inkwell.ai`; never `pnpm add` inside a container — a registry timeout half-relinks the shared `api_node_modules` volume):

```bash
cd src/backend.inkwell.ai && pnpm add --lockfile-only pdf-parse@2.4.5 mammoth@1.12.3 && cd ../..
docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env --profile apps \
  run --rm --no-deps api pnpm install --frozen-lockfile --fetch-timeout 600000
make dci-dev-build
docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env --profile apps up -d api worker
docker exec -w /app inkwell-api-1 node -e "require('pdf-parse'); require('mammoth'); console.log('cjs ok')"
```
Expected: `cjs ok`. If `pdf-parse` throws on `@napi-rs/canvas` (native binary for the image's libc), report it as BLOCKED with the exact error — the fix is a different package, not a workaround.

- [ ] **Step 2: Build the fixtures on the host with pandoc** (the only host-side tool; the files are committed so specs never need pandoc):

```bash
cd src/backend.inkwell.ai && mkdir -p test/documents/fixtures && cd test/documents/fixtures
cat > sample.md <<'EOF'
# Tides and surfcasting

Spring tides happen twice a month, when the sun and moon pull along the same line and the range between high and low water is greatest.

## Reading the beach

Surfcasting works best on a rising tide, in the two hours before high water, when bait fish move in over the sandbars and predators follow them.

\newpage

## Tackle

A twelve-foot rod with a fixed-spool reel casts a four-ounce lead past the first breaker. Braided line carries the bite through the surf better than nylon does.
EOF
pandoc sample.md -o two-pages.pdf
pandoc sample.md -o sample.docx
ls -la
```
Expected: three files; `two-pages.pdf` has two pages (the `\newpage`).

- [ ] **Step 3: Extract both in the container** — write `spike-extract.mjs` in `src/backend.inkwell.ai`:

```js
// Throwaway spike: does pdf-parse give per-page text, does mammoth give paragraphs?
import { readFile } from 'node:fs/promises';
import { PDFParse } from 'pdf-parse';
import mammoth from 'mammoth';

const pdf = new PDFParse({ data: await readFile('test/documents/fixtures/two-pages.pdf') });
const text = await pdf.getText();
console.log('pdf total pages', text.total);
for (const page of text.pages) console.log(`--- page ${page.num} ---\n${page.text.trim()}`);
await pdf.destroy();

const docx = await mammoth.extractRawText({ buffer: await readFile('test/documents/fixtures/sample.docx') });
console.log('--- docx ---\n' + docx.value.trim());
```
Run: `docker exec -w /app inkwell-api-1 node spike-extract.mjs`
Expected: `pdf total pages 2`, page 2 contains "Tackle"; docx text contains all three sections separated by blank lines.

- [ ] **Step 4: Measure the similarity floor** — `spike-similarity.mjs`:

```js
// Throwaway: does 0.60 separate on-topic from off-topic for uploaded reference text?
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { embed, embedMany } from 'ai';
const google = createGoogleGenerativeAI({ apiKey: process.env.GEMINI_API_KEY });
const model = google.embeddingModel('gemini-embedding-001');
const opts = (taskType) => ({ google: { outputDimensionality: 1536, taskType } });
const passages = [
  'Spring tides happen twice a month, when the sun and moon pull along the same line and the range between high and low water is greatest.',
  'Surfcasting works best on a rising tide, in the two hours before high water, when bait fish move in over the sandbars and predators follow them.',
  'A twelve-foot rod with a fixed-spool reel casts a four-ounce lead past the first breaker. Braided line carries the bite through the surf better than nylon does.',
];
const queries = ['When is the best time to fish from the beach?', 'How do I ferment cabbage into sauerkraut?'];
const { embeddings: docs } = await embedMany({ model, values: passages, providerOptions: opts('RETRIEVAL_DOCUMENT') });
const cos = (a, b) => a.reduce((s, x, i) => s + x * b[i], 0) / (Math.hypot(...a) * Math.hypot(...b));
for (const q of queries) {
  const { embedding } = await embed({ model, value: q, providerOptions: opts('RETRIEVAL_QUERY') });
  console.log(q, docs.map((d) => cos(embedding, d).toFixed(3)));
}
```
Run: `docker exec -w /app inkwell-api-1 node spike-similarity.mjs`
Expected: on-topic scores ≥ 0.62, off-topic ≤ 0.58. If the bands overlap, write the numbers in the report — Task 7 picks its constant from them.

- [ ] **Step 5: Delete the spike files, commit the dependency and fixtures**

```bash
rm src/backend.inkwell.ai/spike-extract.mjs src/backend.inkwell.ai/spike-similarity.mjs
cd src/backend.inkwell.ai && git checkout -b feat/document-sources origin/main
git add package.json pnpm-lock.yaml test/documents/fixtures
git commit -m "chore: add pdf-parse and mammoth, with the document fixtures the specs read"
git log --oneline -1
```

---

### Task 1: Schema and migration

**Files:**
- Modify: `src/database/schema/enums.ts`, `src/database/schema/index.ts`
- Create: `src/database/schema/documents.ts`, `drizzle/0007_*.sql`, `drizzle/meta/0007_snapshot.json`, `drizzle/meta/_journal.json` (entry)

**Interfaces:**
- Produces: `schema.documents`, `schema.documentChunks`, `schema.articleDocuments`, `schema.documentStatusEnum` with the column names below — every later task reads them.

- [ ] **Step 1: Add the enum** at the end of `src/database/schema/enums.ts`:

```ts
/**
 * Where an uploaded document is in its ingestion.
 *
 * `pending` → the row exists and the job is queued; `extracting` → the worker
 * has it; `ready` → chunks are embedded and retrievable; `failed` → the
 * writer-readable reason is in `documents.error`. Nothing moves backwards
 * except a retry, which re-queues a `failed` row as `pending`.
 */
export const documentStatusEnum = pgEnum('document_status', [
  'pending',
  'extracting',
  'ready',
  'failed',
]);
```

- [ ] **Step 2: Create `src/database/schema/documents.ts`**:

```ts
import {
  pgTable,
  uuid,
  text,
  integer,
  timestamp,
  unique,
  index,
  primaryKey,
  vector,
} from 'drizzle-orm/pg-core';
import { documentStatusEnum } from './enums.js';
import { users } from './users.js';
import { articles } from './articles.js';
import { EMBEDDING_DIMENSIONS } from './ai.js';

/**
 * A file a writer uploaded as reference material.
 *
 * Separate from `articles` on purpose: an article is the writer's WORK, a
 * document is material they draw on. Documents never feed writer memory,
 * Portfolio Insights or search — they exist only to be retrieved into the
 * assistant's prompt for the articles they are attached to.
 */
export const documents = pgTable(
  'documents',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    // Every read, attach, retrieve and delete filters on this column.
    ownerId: uuid('owner_id')
      .notNull()
      .references(() => users.id),
    /** Filename without its extension; not editable. */
    title: text('title').notNull(),
    filename: text('filename').notNull(),
    contentType: text('content_type').notNull(),
    sizeBytes: integer('size_bytes').notNull(),
    /** Object key in the private `documents` bucket. */
    storageKey: text('storage_key').notNull(),
    status: documentStatusEnum('status').notNull().default('pending'),
    /** Set on `ready`. 1 for TXT/MD and DOCX, which have no fixed pages. */
    pageCount: integer('page_count'),
    chunkCount: integer('chunk_count'),
    /** The writer-readable reason when `failed`. */
    error: text('error'),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
    // Soft delete like articles: retrieval stops at once, the purge job
    // removes the object and hard-deletes the row afterwards.
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (table) => [index('documents_owner_idx').on(table.ownerId)],
);

/**
 * Same shape as `article_chunks` plus the page, so the pgvector query
 * pattern documented on `article_chunks.embedding` is reused verbatim.
 */
export const documentChunks = pgTable(
  'document_chunks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    documentId: uuid('document_id')
      .notNull()
      .references(() => documents.id, { onDelete: 'cascade' }),
    chunkIndex: integer('chunk_index').notNull(),
    /** The page the chunk starts on; 1 for text files and DOCX. */
    page: integer('page').notNull(),
    content: text('content').notNull(),
    embedding: vector('embedding', { dimensions: EMBEDDING_DIMENSIONS }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    unique('document_chunks_document_index_unique').on(
      table.documentId,
      table.chunkIndex,
    ),
    index('document_chunks_document_id_idx').on(table.documentId),
    // Must be `vector_cosine_ops` — the query uses `<=>`. See the note on
    // `chunks_embedding_hnsw_idx` in schema/ai.ts.
    index('document_chunks_embedding_hnsw_idx').using(
      'hnsw',
      table.embedding.op('vector_cosine_ops'),
    ),
  ],
);

/** "Attached to this article." Cascades both ways: a purged document or a hard-deleted article takes the row with it. */
export const articleDocuments = pgTable(
  'article_documents',
  {
    articleId: uuid('article_id')
      .notNull()
      .references(() => articles.id, { onDelete: 'cascade' }),
    documentId: uuid('document_id')
      .notNull()
      .references(() => documents.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.articleId, table.documentId] })],
);
```

- [ ] **Step 3: Export it** — append to `src/database/schema/index.ts`: `export * from './documents.js';`

- [ ] **Step 4: Generate, read, apply**

```bash
docker exec -w /app inkwell-api-1 npx drizzle-kit generate
cat src/backend.inkwell.ai/drizzle/0007_*.sql
```
Expected in the SQL: `CREATE TYPE "public"."document_status"`, three `CREATE TABLE`s, the HNSW index with `vector_cosine_ops`, the two cascades, the composite primary key. Then from `docker.inkwell.ai`: `make dci-migrate` and `docker exec inkwell-db-1 psql -U inkwell -d inkwell -c "\d document_chunks"` — expect the `page` column and the hnsw index.

- [ ] **Step 5: Gates and commit**

```bash
docker exec -w /app inkwell-api-1 npx tsc --noEmit; echo "exit: $?"
docker exec -w /app inkwell-api-1 npm test 2>&1 | tail -5      # no SKIP_DB_PUSH: the test DB needs the push
cd src/backend.inkwell.ai && git add src/database/schema drizzle && git commit -m "feat: documents, document_chunks and article_documents tables" && git log --oneline -1
```

---

### Task 2: `chunkText` — page-tracking chunker

**Files:**
- Modify: `src/ai/chunking.ts`, `src/ai/chunking.spec.ts`

**Interfaces:**
- Produces: `chunkText(pages: DocumentPage[]): TextChunk[]` with `DocumentPage = { page: number; text: string }`, `TextChunk = { index: number; page: number; content: string }`. Task 5 calls it.

- [ ] **Step 1: Append failing tests** to `src/ai/chunking.spec.ts` (keep the existing `chunkArticle` cases):

```ts
import { chunkText } from './chunking.js';

describe('chunkText', () => {
  const long = (words: number, seed = 'tide') =>
    Array.from({ length: words }, (_, i) => `${seed}${i} rises.`).join(' ');

  it('keeps the page a chunk started on', () => {
    const chunks = chunkText([
      { page: 1, text: long(40, 'one') },
      { page: 2, text: long(40, 'two') },
    ]);
    expect(chunks.map((c) => c.page)).toEqual([1, 2]);
    expect(chunks.map((c) => c.index)).toEqual([0, 1]);
  });

  it('merges a thin paragraph forward and dates the chunk from the first paragraph', () => {
    const chunks = chunkText([
      { page: 3, text: 'Yes.' },
      { page: 4, text: long(40) },
    ]);
    expect(chunks).toHaveLength(1);
    expect(chunks[0].page).toBe(3);
    expect(chunks[0].content.startsWith('Yes.')).toBe(true);
  });

  it('splits a long page on sentence boundaries under 1200 characters', () => {
    const chunks = chunkText([{ page: 1, text: long(400) }]);
    expect(chunks.length).toBeGreaterThan(1);
    for (const c of chunks) expect(c.content.length).toBeLessThanOrEqual(1200);
  });

  it('collapses wrapped lines inside a paragraph but splits on blank lines', () => {
    const text = 'First line\nof one paragraph.\n\nSecond paragraph here.';
    const [chunk] = chunkText([{ page: 1, text }]);
    expect(chunk.content).toBe('First line of one paragraph.\n\nSecond paragraph here.');
  });

  it('returns nothing for whitespace-only pages', () => {
    expect(chunkText([{ page: 1, text: '  \n\n ' }])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to see them fail**: `docker exec -w /app inkwell-api-1 npm test -- src/ai/chunking.spec.ts` → FAIL, `chunkText is not a function`.

- [ ] **Step 3: Implement** in `src/ai/chunking.ts` — after `chunkArticle`, before `withHeading`:

```ts
/** One page of extracted text, as the document extractor produces it. */
export interface DocumentPage {
  /** 1-based page number; 1 throughout for formats without fixed pages. */
  page: number;
  text: string;
}

/** A chunk of an uploaded document, ready to embed. */
export interface TextChunk {
  /** Contiguous from 0 — persisted as `chunk_index`. */
  index: number;
  /** The page the chunk STARTED on; a merged chunk keeps its first paragraph's page. */
  page: number;
  content: string;
}

/**
 * Chunks plain text pages with the same bounds as `chunkArticle`.
 *
 * Paragraphs split on blank lines; single newlines inside a paragraph are
 * PDF line wraps, not structure, so they collapse to spaces — otherwise every
 * wrapped line would embed as its own "sentence". Thin paragraphs merge
 * forward and long ones split on sentences exactly as article blocks do; the
 * one addition is the page carried on each chunk, which is what lets the
 * assistant cite `[Title, p. N]`.
 */
export function chunkText(pages: DocumentPage[]): TextChunk[] {
  const chunks: { page: number; content: string }[] = [];
  let pending: string[] = [];
  // The page of the first paragraph in `pending` — the page the chunk starts on.
  let pendingPage = 1;

  const flushPending = () => {
    if (pending.length === 0) return;
    chunks.push({ page: pendingPage, content: pending.join('\n\n') });
    pending = [];
  };

  for (const { page, text } of pages) {
    const paragraphs = text
      .split(/\n\s*\n/)
      .map((p) => p.replace(/\s+/g, ' ').trim())
      .filter(Boolean);

    for (const paragraph of paragraphs) {
      if (pending.length === 0) pendingPage = page;
      pending.push(paragraph);
      const merged = pending.join('\n\n');
      if (merged.length >= MIN_CHUNK_CHARS) {
        pending = [];
        for (const piece of splitLongText(merged)) {
          chunks.push({ page: pendingPage, content: piece });
        }
      }
    }
  }

  // A short tail is still real content; nothing follows to merge it into.
  flushPending();

  return chunks.map((c, index) => ({ index, ...c }));
}
```

- [ ] **Step 4: Run**: same command → PASS (all chunking cases).

- [ ] **Step 5: Commit**: `git add src/ai/chunking.ts src/ai/chunking.spec.ts && git commit -m "feat: chunkText keeps the page a chunk starts on"`

---

### Task 3: Limits, queue contract, extractor

**Files:**
- Create: `src/documents/document-limits.ts`, `src/documents/documents.queue.ts`, `src/documents/document-extractor.token.ts`, `src/documents/document-extractor.service.ts`, `test/documents/document-extractor.spec.ts`, `src/documents/document-limits.spec.ts`

**Interfaces:**
- Produces: everything below, verbatim names. `DocumentExtractorService.extract(buffer, contentType): Promise<DocumentPage[]>`.

- [ ] **Step 1: `src/documents/document-limits.ts`** (import-free — DTOs, the service and the worker all read it):

```ts
/**
 * The caps and copy of the document library. Import-free so any spec can
 * load it without dragging in a provider.
 */

/** Per-file ceiling; the client refuses larger files before presigning, the API is the backstop. */
export const DOCUMENT_MAX_BYTES = 10 * 1024 * 1024;
/** Live (not soft-deleted) documents per writer. */
export const DOCUMENT_MAX_COUNT = 20;
/** Pages a PDF may have; more is refused at extraction, not upload. */
export const DOCUMENT_MAX_PAGES = 200;
/** Below this many characters of extracted text a PDF is treated as scanned. */
export const DOCUMENT_MIN_TEXT_CHARS = 50;
/** Lifetime of a presigned download URL. Short: it is a bearer credential to a private file. */
export const DOCUMENT_FILE_URL_TTL_SECONDS = 600;

/** Failure copy, shown verbatim in the library row. */
export const NO_TEXT_LAYER_MESSAGE =
  'This PDF has no text layer — export it with selectable text';
export const TOO_MANY_PAGES_MESSAGE = 'Documents are limited to 200 pages';
export const INGEST_FAILED_MESSAGE = "Couldn't process this document — try again";
export const LIBRARY_FULL_MESSAGE = 'You already have 20 documents';

export const DOCUMENT_CONTENT_TYPES = {
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  txt: 'text/plain',
  md: 'text/markdown',
} as const;

export type DocumentContentType =
  (typeof DOCUMENT_CONTENT_TYPES)[keyof typeof DOCUMENT_CONTENT_TYPES];

/**
 * The content type a filename implies, or null for anything unsupported.
 *
 * The EXTENSION is authoritative, not the browser's `File.type`: Chrome sends
 * an empty type for `.md` on some systems, so trusting it would refuse valid
 * Markdown.
 */
export function documentTypeFromFilename(filename: string): DocumentContentType | null {
  const ext = filename.toLowerCase().split('.').pop() ?? '';
  return ext in DOCUMENT_CONTENT_TYPES
    ? DOCUMENT_CONTENT_TYPES[ext as keyof typeof DOCUMENT_CONTENT_TYPES]
    : null;
}

/** Filename without its last extension — the document's title. */
export function titleFromFilename(filename: string): string {
  const dot = filename.lastIndexOf('.');
  return dot > 0 ? filename.slice(0, dot) : filename;
}
```

- [ ] **Step 2: `src/documents/document-limits.spec.ts`**:

```ts
import { documentTypeFromFilename, titleFromFilename } from './document-limits.js';

describe('documentTypeFromFilename', () => {
  it('maps the four extensions, case-insensitively', () => {
    expect(documentTypeFromFilename('notes.PDF')).toBe('application/pdf');
    expect(documentTypeFromFilename('a.docx')).toContain('wordprocessingml');
    expect(documentTypeFromFilename('a.txt')).toBe('text/plain');
    expect(documentTypeFromFilename('a.md')).toBe('text/markdown');
  });
  it('refuses everything else', () => {
    expect(documentTypeFromFilename('a.doc')).toBeNull();
    expect(documentTypeFromFilename('noext')).toBeNull();
    expect(documentTypeFromFilename('a.png')).toBeNull();
  });
});

describe('titleFromFilename', () => {
  it('drops only the last extension', () => {
    expect(titleFromFilename('field notes.v2.pdf')).toBe('field notes.v2');
    expect(titleFromFilename('README')).toBe('README');
  });
});
```
Run: `docker exec -w /app inkwell-api-1 npm test -- src/documents/document-limits.spec.ts` → PASS (the module was written first; the point of the spec is the extension table).

- [ ] **Step 3: `src/documents/documents.queue.ts`** (import-free, same reasoning as `embeddings.queue.ts`):

```ts
/**
 * The documents queue contract: name, job names, payload.
 *
 * Its own queue, not `embeddings`: a slow 200-page PDF must never delay an
 * article's chunks. Import-free so DocumentsService (the producer) can reach
 * these without loading the processor and, through it, the AI provider —
 * see `src/ai/processors/embeddings.queue.ts` for the full story.
 */
export const DOCUMENTS_QUEUE = 'documents';

export const INGEST_DOCUMENT = 'ingest-document';
export const PURGE_DOCUMENT = 'purge-document';

export interface DocumentJob {
  documentId: string;
}
```

- [ ] **Step 4: `src/documents/document-extractor.token.ts`** (import-free):

```ts
import type { DocumentPage } from '../ai/chunking.js';

/** Turns a file's bytes into pages of plain text. */
export interface DocumentExtractor {
  extract(buffer: Buffer, contentType: string): Promise<DocumentPage[]>;
}

/** The slice of EmbeddingsService the ingestion needs. */
export interface DocumentEmbedder {
  readonly isConfigured: boolean;
  embedDocuments(texts: string[]): Promise<number[][]>;
}

/**
 * DI tokens so DocumentIngestionService can `import type` its collaborators.
 *
 * EmbeddingsService value-imports `@ai-sdk/google` (ESM-only), which jest's
 * CommonJS registry cannot parse; injecting through a token keeps the
 * ingestion service — and its spec — free of that edge. Same pattern as
 * `CONTENT_MODERATION`.
 */
export const DOCUMENT_EXTRACTOR = Symbol('DOCUMENT_EXTRACTOR');
export const DOCUMENT_EMBEDDER = Symbol('DOCUMENT_EMBEDDER');
```
(`import type` of an interface from `chunking.ts` is erased at compile time; chunking.ts imports only `tiptap-utils`, which is jest-safe anyway.)

- [ ] **Step 5: Failing extractor spec** `test/documents/document-extractor.spec.ts`:

```ts
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { DocumentExtractorService } from '../../src/documents/document-extractor.service.js';
import { DOCUMENT_CONTENT_TYPES } from '../../src/documents/document-limits.js';

const fixture = (name: string) => readFile(join(__dirname, 'fixtures', name));

describe('DocumentExtractorService', () => {
  const extractor = new DocumentExtractorService();

  it('returns one entry per PDF page with the page number', async () => {
    const pages = await extractor.extract(await fixture('two-pages.pdf'), DOCUMENT_CONTENT_TYPES.pdf);
    expect(pages.map((p) => p.page)).toEqual([1, 2]);
    expect(pages[0].text).toContain('Spring tides');
    expect(pages[1].text).toContain('Tackle');
  });

  it('flattens a DOCX to a single page', async () => {
    const pages = await extractor.extract(await fixture('sample.docx'), DOCUMENT_CONTENT_TYPES.docx);
    expect(pages).toHaveLength(1);
    expect(pages[0].page).toBe(1);
    expect(pages[0].text).toContain('Surfcasting');
    expect(pages[0].text).toContain('Tackle');
  });

  it('reads text files as UTF-8, one page', async () => {
    const pages = await extractor.extract(Buffer.from('héllo\n\nworld', 'utf8'), DOCUMENT_CONTENT_TYPES.md);
    expect(pages).toEqual([{ page: 1, text: 'héllo\n\nworld' }]);
  });

  it('refuses an unknown content type', async () => {
    await expect(extractor.extract(Buffer.from(''), 'image/png')).rejects.toThrow('Unsupported');
  });
});
```
Run: `docker exec -w /app inkwell-api-1 npm test -- test/documents/document-extractor.spec.ts` → FAIL, cannot find module.

- [ ] **Step 6: `src/documents/document-extractor.service.ts`**:

```ts
import { Injectable } from '@nestjs/common';
import { PDFParse } from 'pdf-parse';
import mammoth from 'mammoth';
import type { DocumentPage } from '../ai/chunking.js';
import { DOCUMENT_CONTENT_TYPES } from './document-limits.js';
import type { DocumentExtractor } from './document-extractor.token.js';

/**
 * Text extraction for the three supported families.
 *
 * Runs in the worker only. PDF keeps pages because citations name them; DOCX
 * has no fixed pages (they depend on the renderer), so it is one page and
 * cites as `[Title]`; text files are read as they are.
 *
 * No OCR: a PDF without a text layer yields (near-)empty pages, and the
 * ingestion service turns that into the "no text layer" failure.
 */
@Injectable()
export class DocumentExtractorService implements DocumentExtractor {
  async extract(buffer: Buffer, contentType: string): Promise<DocumentPage[]> {
    switch (contentType) {
      case DOCUMENT_CONTENT_TYPES.pdf:
        return this.extractPdf(buffer);
      case DOCUMENT_CONTENT_TYPES.docx: {
        const { value } = await mammoth.extractRawText({ buffer });
        return [{ page: 1, text: value }];
      }
      case DOCUMENT_CONTENT_TYPES.txt:
      case DOCUMENT_CONTENT_TYPES.md:
        return [{ page: 1, text: buffer.toString('utf8') }];
      default:
        throw new Error(`Unsupported document type: ${contentType}`);
    }
  }

  /** Per-page text via pdf-parse; the parser is destroyed even if getText throws. */
  private async extractPdf(buffer: Buffer): Promise<DocumentPage[]> {
    const parser = new PDFParse({ data: buffer });
    try {
      const result = await parser.getText();
      return result.pages.map((p) => ({ page: p.num, text: p.text }));
    } finally {
      await parser.destroy();
    }
  }
}
```
If `import mammoth from 'mammoth'` fails type-checking under NodeNext (`esModuleInterop` off), use `import * as mammoth from 'mammoth'`. Check `docker exec -w /app inkwell-api-1 npx tsc --noEmit`.

- [ ] **Step 7: Run**: the extractor spec → PASS. Then `npm run lint` and `tsc --noEmit`; exit 0 each.

- [ ] **Step 8: Commit**: `git add src/documents test/documents && git commit -m "feat: document limits, queue contract and text extractor"`

---

### Task 4: Private document storage

**Files:**
- Create: `src/uploads/minio-client.ts`, `src/documents/document-storage.service.ts`
- Modify: `src/uploads/uploads.service.ts` (constructor uses the factory; behaviour unchanged)

**Interfaces:**
- Produces: `DocumentStorageService` with `presignUpload(filename): Promise<{ uploadUrl; storageKey }>`, `presignDownload(storageKey, contentType, filename): Promise<string>`, `read(storageKey): Promise<Buffer>`, `remove(storageKey): Promise<void>`. Depends only on `ConfigService`, so the worker can list it.

- [ ] **Step 1: `src/uploads/minio-client.ts`**:

```ts
import { ConfigService } from '@nestjs/config';
import * as Minio from 'minio';

/**
 * One place that knows how the MinIO client is built.
 *
 * Both the image bucket (UploadsService) and the private document bucket
 * (DocumentStorageService) presign against the same endpoint; keeping the
 * construction here means the `useSSL`/endpoint reasoning documented below is
 * written once.
 */
export function createMinioClient(config: ConfigService): Minio.Client {
  return new Minio.Client({
    endPoint: config.getOrThrow<string>('MINIO_ENDPOINT'),
    port: config.getOrThrow<number>('MINIO_PORT'),
    // Drives the scheme of every presigned URL. False locally (plain HTTP
    // through nginx), true in production (public domain behind TLS).
    useSSL: config.getOrThrow<boolean>('MINIO_USE_SSL'),
    accessKey: config.getOrThrow<string>('MINIO_ACCESS_KEY'),
    secretKey: config.getOrThrow<string>('MINIO_SECRET_KEY'),
  });
}
```
In `uploads.service.ts` replace the `new Minio.Client({...})` block with `this.client = createMinioClient(config);` (keep the `import * as Minio` for the type).

- [ ] **Step 2: `src/documents/document-storage.service.ts`**:

```ts
import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type * as Minio from 'minio';
import { randomUUID } from 'crypto';
import { createMinioClient } from '../uploads/minio-client.js';
import { PRESIGNED_UPLOAD_TTL_SECONDS } from '../common/constants.js';
import { DOCUMENT_FILE_URL_TTL_SECONDS } from './document-limits.js';

/** The private bucket. NOT `MINIO_BUCKET`, which is anonymously readable for images. */
export const DOCUMENTS_BUCKET = 'documents';

/**
 * The private object store for uploaded documents.
 *
 * Unlike the image bucket there is NO anonymous-read policy: a document is
 * reference material the writer may not have the right to publish, so the
 * only way to read one is a presigned GET issued to its owner. Everything
 * here is a thin wrapper over the client so both the API (presign, purge) and
 * the worker (read) share the bucket bootstrap.
 */
@Injectable()
export class DocumentStorageService {
  private readonly client: Minio.Client;
  private bucketReady = false;

  constructor(config: ConfigService) {
    this.client = createMinioClient(config);
  }

  /** Creates the bucket on first use. Private by default — no policy is set on purpose. */
  private async ensureBucket(): Promise<void> {
    if (this.bucketReady) return;
    if (!(await this.client.bucketExists(DOCUMENTS_BUCKET))) {
      await this.client.makeBucket(DOCUMENTS_BUCKET);
    }
    this.bucketReady = true;
  }

  /** A presigned PUT for a fresh key; the extension is kept so the object's type is visible in the console. */
  async presignUpload(filename: string): Promise<{ uploadUrl: string; storageKey: string }> {
    await this.ensureBucket();
    const ext = filename.split('.').pop() ?? 'bin';
    const storageKey = `${randomUUID()}.${ext}`;
    const uploadUrl = await this.client.presignedPutObject(
      DOCUMENTS_BUCKET,
      storageKey,
      PRESIGNED_UPLOAD_TTL_SECONDS,
    );
    return { uploadUrl, storageKey };
  }

  /**
   * A presigned GET the browser opens directly.
   *
   * The response headers are pinned so the browser renders a PDF inline (which
   * is what makes `#page=N` work) with the writer's own filename rather than
   * the UUID key.
   */
  async presignDownload(storageKey: string, contentType: string, filename: string): Promise<string> {
    await this.ensureBucket();
    return this.client.presignedGetObject(
      DOCUMENTS_BUCKET,
      storageKey,
      DOCUMENT_FILE_URL_TTL_SECONDS,
      {
        'response-content-type': contentType,
        'response-content-disposition': `inline; filename="${filename.replace(/"/g, '')}"`,
      },
    );
  }

  /** The whole object in memory — bounded by DOCUMENT_MAX_BYTES at registration. */
  async read(storageKey: string): Promise<Buffer> {
    await this.ensureBucket();
    const stream = await this.client.getObject(DOCUMENTS_BUCKET, storageKey);
    const parts: Buffer[] = [];
    for await (const chunk of stream) parts.push(Buffer.from(chunk));
    return Buffer.concat(parts);
  }

  /** Deletes the object. Idempotent: MinIO answers 204 for a missing key. */
  async remove(storageKey: string): Promise<void> {
    await this.ensureBucket();
    await this.client.removeObject(DOCUMENTS_BUCKET, storageKey);
  }
}
```

- [ ] **Step 3: Gates**: `tsc --noEmit`, `npm run lint`, `npm test -- src/uploads` (nothing there today — just confirm the build). Exit 0.

- [ ] **Step 4: Commit**: `git add src/uploads src/documents/document-storage.service.ts && git commit -m "feat: private MinIO bucket for documents, sharing the client factory"`

---

### Task 5: Ingestion service, worker processor

**Files:**
- Create: `src/documents/document-ingestion.service.ts`, `src/documents/processors/documents.processor.ts`, `test/documents/document-ingestion.spec.ts`
- Modify: `src/worker.module.ts`

**Interfaces:**
- Consumes: `chunkText`, `DOCUMENT_EXTRACTOR`/`DOCUMENT_EMBEDDER` tokens, `DocumentStorageService`, `schema.documents`/`documentChunks`.
- Produces: `DocumentIngestionService.ingest(documentId): Promise<IngestResult>`, `.purge(documentId): Promise<void>`.

- [ ] **Step 1: Failing spec** `test/documents/document-ingestion.spec.ts`:

```ts
import { eq, sql } from 'drizzle-orm';
import * as schema from '../../src/database/schema/index.js';
import type { Tx } from '../../src/database/tx.js';
import { withRollback } from '../support/db.js';
import { makeWriter } from '../support/fixtures/ledger.js';
import { DocumentIngestionService } from '../../src/documents/document-ingestion.service.js';
import {
  INGEST_FAILED_MESSAGE,
  NO_TEXT_LAYER_MESSAGE,
  TOO_MANY_PAGES_MESSAGE,
} from '../../src/documents/document-limits.js';
import type { DocumentPage } from '../../src/ai/chunking.js';

/** A unit vector — any 1536-wide array the column accepts. */
const vec = () => Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0));
const long = (seed: string) => Array.from({ length: 40 }, (_, i) => `${seed}${i} rises.`).join(' ');

/** The service with every collaborator faked; `pages` is what the extractor returns. */
function build(tx: Tx, pages: DocumentPage[] | Error, embedder = { isConfigured: true, embedDocuments: jest.fn(async (t: string[]) => t.map(vec)) }) {
  const extractor = { extract: jest.fn(async () => { if (pages instanceof Error) throw pages; return pages; }) };
  const storage = { read: jest.fn(async () => Buffer.from('bytes')), remove: jest.fn(async () => undefined) };
  return {
    service: new DocumentIngestionService(tx, extractor, embedder, storage as never),
    extractor, embedder, storage,
  };
}

async function insertDoc(tx: Tx, ownerId: string, contentType = 'application/pdf') {
  const [row] = await tx.insert(schema.documents).values({
    ownerId, title: 'notes', filename: 'notes.pdf', contentType, sizeBytes: 10, storageKey: 'k.pdf',
  }).returning({ id: schema.documents.id });
  return row.id;
}

async function statusOf(tx: Tx, id: string) {
  const [row] = await tx.select({ status: schema.documents.status, error: schema.documents.error, pageCount: schema.documents.pageCount, chunkCount: schema.documents.chunkCount })
    .from(schema.documents).where(eq(schema.documents.id, id));
  return row;
}

async function chunkCount(tx: Tx, id: string) {
  const r = await tx.execute<{ n: number }>(sql`SELECT COUNT(*)::int AS n FROM document_chunks WHERE document_id = ${id}`);
  return r.rows[0].n;
}

describe('DocumentIngestionService', () => {
  it('extracts, chunks, embeds and marks ready with counts', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      const { service, embedder } = build(tx, [{ page: 1, text: long('a') }, { page: 2, text: long('b') }]);

      await service.ingest(id);

      expect(await statusOf(tx, id)).toEqual({ status: 'ready', error: null, pageCount: 2, chunkCount: 2 });
      expect(await chunkCount(tx, id)).toBe(2);
      expect(embedder.embedDocuments).toHaveBeenCalledTimes(1);
      const pages = await tx.select({ page: schema.documentChunks.page }).from(schema.documentChunks).where(eq(schema.documentChunks.documentId, id)).orderBy(schema.documentChunks.chunkIndex);
      expect(pages.map((p) => p.page)).toEqual([1, 2]);
    }));

  it('fails a PDF with no text layer, with the exact copy', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      const { service, embedder } = build(tx, [{ page: 1, text: '  ' }, { page: 2, text: 'x' }]);
      await service.ingest(id);
      expect(await statusOf(tx, id)).toMatchObject({ status: 'failed', error: NO_TEXT_LAYER_MESSAGE });
      expect(embedder.embedDocuments).not.toHaveBeenCalled();
    }));

  it('fails over 200 pages before chunking', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      const pages = Array.from({ length: 201 }, (_, i) => ({ page: i + 1, text: long(`p${i}`) }));
      const { service, embedder } = build(tx, pages);
      await service.ingest(id);
      expect(await statusOf(tx, id)).toMatchObject({ status: 'failed', error: TOO_MANY_PAGES_MESSAGE });
      expect(embedder.embedDocuments).not.toHaveBeenCalled();
    }));

  it('turns any other throw into the generic message and leaves no chunks', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      const embedder = { isConfigured: true, embedDocuments: jest.fn(async () => { throw new Error('429 from provider'); }) };
      const { service } = build(tx, [{ page: 1, text: long('a') }], embedder);
      await service.ingest(id);
      expect(await statusOf(tx, id)).toMatchObject({ status: 'failed', error: INGEST_FAILED_MESSAGE });
      expect(await chunkCount(tx, id)).toBe(0);
    }));

  it('replaces old chunks on a retry', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      await tx.insert(schema.documentChunks).values({ documentId: id, chunkIndex: 0, page: 1, content: 'stale', embedding: vec() });
      const { service } = build(tx, [{ page: 1, text: long('fresh') }]);
      await service.ingest(id);
      const rows = await tx.select({ content: schema.documentChunks.content }).from(schema.documentChunks).where(eq(schema.documentChunks.documentId, id));
      expect(rows).toHaveLength(1);
      expect(rows[0].content).toContain('fresh0');
    }));

  it('skips a document that was deleted before the job ran', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      await tx.update(schema.documents).set({ deletedAt: new Date() }).where(eq(schema.documents.id, id));
      const { service, extractor } = build(tx, [{ page: 1, text: long('a') }]);
      const result = await service.ingest(id);
      expect(result.skipped).toBe('deleted');
      expect(extractor.extract).not.toHaveBeenCalled();
    }));

  it('purge removes the object and hard-deletes the row', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const id = await insertDoc(tx, ownerId);
      const { service, storage } = build(tx, []);
      await service.purge(id);
      expect(storage.remove).toHaveBeenCalledWith('k.pdf');
      const r = await tx.execute<{ n: number }>(sql`SELECT COUNT(*)::int AS n FROM documents WHERE id = ${id}`);
      expect(r.rows[0].n).toBe(0);
    }));
});
```
Run: `docker exec -w /app inkwell-api-1 npm test -- test/documents/document-ingestion.spec.ts` → FAIL, module not found.

- [ ] **Step 2: `src/documents/document-ingestion.service.ts`**:

```ts
import { Inject, Injectable, Logger } from '@nestjs/common';
import { and, eq, isNull } from 'drizzle-orm';
import { DRIZZLE } from '../database/database.module.js';
import * as schema from '../database/schema/index.js';
import { withTx, type DbOrTx } from '../database/tx.js';
import { chunkText } from '../ai/chunking.js';
import {
  DOCUMENT_EMBEDDER,
  DOCUMENT_EXTRACTOR,
  type DocumentEmbedder,
  type DocumentExtractor,
} from './document-extractor.token.js';
import { DocumentStorageService } from './document-storage.service.js';
import {
  DOCUMENT_CONTENT_TYPES,
  DOCUMENT_MAX_PAGES,
  DOCUMENT_MIN_TEXT_CHARS,
  INGEST_FAILED_MESSAGE,
  NO_TEXT_LAYER_MESSAGE,
  TOO_MANY_PAGES_MESSAGE,
} from './document-limits.js';

/** What `ingest` did, for the processor's log line. */
export interface IngestResult {
  documentId: string;
  chunks: number;
  skipped?: 'not-found' | 'deleted' | 'not-configured';
  failed?: string;
}

/**
 * A failure whose message is meant for the writer.
 *
 * Distinguishes the three refusals with their own copy from a provider or
 * parser throw, which gets the generic sentence — a stack trace is not
 * something to show in a library row.
 */
class WriterFacingError extends Error {}

/**
 * Owns one document's lifecycle in the worker: extract → chunk → embed →
 * ready, or failed with a reason.
 *
 * ## Why extraction happens outside the transaction
 *
 * Parsing and embedding are slow; holding a transaction open across them
 * would pin a connection for seconds per document. The write — delete old
 * chunks, insert new, set ready — is one short transaction, so a document is
 * never half-embedded: either all its chunks and `ready` land, or none do.
 *
 * ## Collaborators by token
 *
 * The extractor and embedder are injected through import-free tokens so this
 * class, and its spec, never value-import the AI provider (ESM-only, which
 * jest cannot load). The spec hands in fakes; WorkerModule aliases the tokens
 * to the real services.
 */
@Injectable()
export class DocumentIngestionService {
  private readonly logger = new Logger(DocumentIngestionService.name);

  constructor(
    @Inject(DRIZZLE) private readonly db: DbOrTx,
    @Inject(DOCUMENT_EXTRACTOR) private readonly extractor: DocumentExtractor,
    @Inject(DOCUMENT_EMBEDDER) private readonly embedder: DocumentEmbedder,
    private readonly storage: DocumentStorageService,
  ) {}

  async ingest(documentId: string): Promise<IngestResult> {
    const [doc] = await this.db
      .select({
        id: schema.documents.id,
        contentType: schema.documents.contentType,
        storageKey: schema.documents.storageKey,
        deletedAt: schema.documents.deletedAt,
      })
      .from(schema.documents)
      .where(eq(schema.documents.id, documentId))
      .limit(1);

    if (!doc) return { documentId, chunks: 0, skipped: 'not-found' };
    // Deleted between enqueue and run: the purge job will take the row; there
    // is nothing to embed for anyone.
    if (doc.deletedAt) return { documentId, chunks: 0, skipped: 'deleted' };
    if (!this.embedder.isConfigured) {
      // Same degradation as article embedding: no key means no RAG, not a
      // crashed worker. The row stays pending so a retry after configuring
      // the key picks it up.
      this.logger.warn(`Skipping document ${documentId}: GEMINI_API_KEY is not configured`);
      return { documentId, chunks: 0, skipped: 'not-configured' };
    }

    await this.db
      .update(schema.documents)
      .set({ status: 'extracting', error: null })
      .where(eq(schema.documents.id, documentId));

    try {
      const bytes = await this.storage.read(doc.storageKey);
      const pages = await this.extractor.extract(bytes, doc.contentType);

      // Order matters: the page cap is checked before the text floor so a
      // 300-page scan is told about the pages, which is the cheaper fix.
      if (pages.length > DOCUMENT_MAX_PAGES) {
        throw new WriterFacingError(TOO_MANY_PAGES_MESSAGE);
      }
      const totalChars = pages.reduce((n, p) => n + p.text.trim().length, 0);
      if (totalChars < DOCUMENT_MIN_TEXT_CHARS) {
        throw new WriterFacingError(
          doc.contentType === DOCUMENT_CONTENT_TYPES.pdf
            ? NO_TEXT_LAYER_MESSAGE
            : 'This document has no text to read',
        );
      }

      const chunks = chunkText(pages);
      const vectors = await this.embedder.embedDocuments(chunks.map((c) => c.content));

      await withTx(this.db, async (tx) => {
        // Delete-then-insert, for the same reason as article chunks: a retry
        // of a document that partially succeeded before must not leave a
        // stale tail behind the `(document_id, chunk_index)` constraint.
        await tx.delete(schema.documentChunks).where(eq(schema.documentChunks.documentId, documentId));
        await tx.insert(schema.documentChunks).values(
          chunks.map((chunk, i) => ({
            documentId,
            chunkIndex: chunk.index,
            page: chunk.page,
            content: chunk.content,
            // Positional zip — embedDocuments guarantees input order.
            embedding: vectors[i],
          })),
        );
        await tx
          .update(schema.documents)
          .set({ status: 'ready', pageCount: pages.length, chunkCount: chunks.length, error: null })
          .where(eq(schema.documents.id, documentId));
      });

      this.logger.log(`Document ${documentId}: ${chunks.length} chunk(s) over ${pages.length} page(s)`);
      return { documentId, chunks: chunks.length };
    } catch (error) {
      // Anything not written for the writer gets the generic sentence; the
      // real cause goes to the log where it can be read with its stack.
      const message = error instanceof WriterFacingError ? error.message : INGEST_FAILED_MESSAGE;
      if (!(error instanceof WriterFacingError)) {
        this.logger.error(
          `Document ${documentId} failed to ingest`,
          error instanceof Error ? error.stack : String(error),
        );
      }
      await this.db
        .update(schema.documents)
        .set({ status: 'failed', error: message })
        .where(eq(schema.documents.id, documentId));
      return { documentId, chunks: 0, failed: message };
    }
  }

  /**
   * Removes the object, then hard-deletes the row (chunks and attachments
   * cascade). Runs after a soft delete; if the row was never soft-deleted the
   * purge still proceeds — the job's existence is the writer's decision.
   */
  async purge(documentId: string): Promise<void> {
    const [doc] = await this.db
      .select({ storageKey: schema.documents.storageKey })
      .from(schema.documents)
      .where(eq(schema.documents.id, documentId))
      .limit(1);
    if (!doc) return;

    // Object first: if this throws, the row survives and the job retries; the
    // reverse order could orphan a private file nobody can list.
    await this.storage.remove(doc.storageKey);
    await this.db.delete(schema.documents).where(eq(schema.documents.id, documentId));
    this.logger.log(`Purged document ${documentId}`);
  }
}
```
Note `isNull` is imported for the status query in Task 6 only if used; remove unused imports before lint.

- [ ] **Step 3: Run the spec** → PASS (7 cases).

- [ ] **Step 4: Processor** `src/documents/processors/documents.processor.ts`:

```ts
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Logger } from '@nestjs/common';
import type { Job } from 'bullmq';
import { DocumentIngestionService } from '../document-ingestion.service.js';
import { DOCUMENTS_QUEUE, INGEST_DOCUMENT, PURGE_DOCUMENT, type DocumentJob } from '../documents.queue.js';

/**
 * Consumes the `documents` queue. Registered in WorkerModule ONLY — a
 * WorkerHost polls its queue, and a second registration in the API would make
 * the two containers compete for jobs (see EmbedArticleProcessor).
 */
@Processor(DOCUMENTS_QUEUE)
export class DocumentsProcessor extends WorkerHost {
  private readonly logger = new Logger(DocumentsProcessor.name);

  constructor(private readonly ingestion: DocumentIngestionService) {
    super();
  }

  async process(job: Job<DocumentJob>): Promise<unknown> {
    switch (job.name) {
      case INGEST_DOCUMENT:
        // `ingest` never throws — a failure is recorded on the row for the
        // writer to read. Retrying here would re-run a scan that will fail
        // the same way, so the job completes either way.
        return this.ingestion.ingest(job.data.documentId);
      case PURGE_DOCUMENT:
        await this.ingestion.purge(job.data.documentId);
        return { purged: job.data.documentId };
      default:
        // Warn, not throw: an unknown name is a rename mid-deploy, and
        // throwing would loop it through retries nobody can handle.
        this.logger.warn(`Ignoring unknown job "${job.name}"`);
        return undefined;
    }
  }
}
```

- [ ] **Step 5: Wire the worker** in `src/worker.module.ts` — add imports and, in `imports`, `BullModule.registerQueue({ name: DOCUMENTS_QUEUE })`; in `providers`:

```ts
    // Document ingestion. The extractor and embedder reach the ingestion
    // service through tokens (see document-extractor.token.ts); the embedder
    // token is aliased to the EmbeddingsService instance already listed above.
    DocumentStorageService,
    DocumentExtractorService,
    { provide: DOCUMENT_EXTRACTOR, useExisting: DocumentExtractorService },
    { provide: DOCUMENT_EMBEDDER, useExisting: EmbeddingsService },
    DocumentIngestionService,
    DocumentsProcessor,
```
Then restart and read the worker log: `docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env --profile apps restart worker && docker logs --tail 30 inkwell-worker-1` — expect `Worker started`, no `UnknownDependenciesException`.

- [ ] **Step 6: Gates and commit**: `tsc --noEmit`, `npm run lint`, `npm test` (full); then `git add src/documents src/worker.module.ts test/documents && git commit -m "feat: document ingestion in the worker — extract, chunk, embed, ready or failed"`

---

### Task 6: Library API — service, controller, DTOs, module

**Files:**
- Create: `src/documents/dto/presign-document.dto.ts`, `dto/register-document.dto.ts`, `dto/set-article-documents.dto.ts`, `src/documents/documents.service.ts`, `documents.controller.ts`, `documents.module.ts`, `test/documents/documents-service.spec.ts`
- Modify: `src/app.module.ts`

**Interfaces:**
- Produces the routes (all behind `@Auth`, all under the global `/api` prefix): `POST /documents/presign {filename}` → `{ uploadUrl, storageKey }`; `POST /documents {storageKey, filename, sizeBytes}` → document row; `GET /documents` → `{ items: DocumentRow[], count, max: 20 }`; `GET /documents/:id/file` → `{ url, expiresInSeconds }`; `POST /documents/:id/retry` → row; `DELETE /documents/:id` → 204; `GET /articles/:id/documents` → `DocumentRow[]`; `PUT /articles/:id/documents {documentIds}` → `DocumentRow[]`. `DocumentRow = { id, title, filename, contentType, sizeBytes, status, pageCount, chunkCount, error, createdAt }`.
- Also `DocumentsService.attachedReadyDocumentIds(articleId, ownerId): Promise<string[]>` for Task 8.

- [ ] **Step 1: DTOs**

`dto/presign-document.dto.ts`:
```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsNotEmpty, IsString, MaxLength } from 'class-validator';

export class PresignDocumentDto {
  @ApiProperty({ example: 'field-notes.pdf' })
  @IsString()
  @IsNotEmpty()
  @MaxLength(255)
  filename!: string;
}
```
`dto/register-document.dto.ts`:
```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsInt, IsNotEmpty, IsString, Max, MaxLength, Min } from 'class-validator';
import { DOCUMENT_MAX_BYTES } from '../document-limits.js';

/**
 * No `contentType` field: the type is derived from the filename's extension
 * (see documentTypeFromFilename), so a client-sent type would carry no
 * information the server trusts — and an undeclared field is a 400 under
 * `forbidNonWhitelisted`.
 */
export class RegisterDocumentDto {
  @ApiProperty({ description: 'The storageKey returned by POST /documents/presign' })
  @IsString()
  @IsNotEmpty()
  storageKey!: string;

  @ApiProperty({ example: 'field-notes.pdf' })
  @IsString()
  @IsNotEmpty()
  @MaxLength(255)
  filename!: string;

  @ApiProperty({ example: 482913 })
  @IsInt()
  @Min(1)
  @Max(DOCUMENT_MAX_BYTES, { message: 'Documents must be under 10 MB' })
  sizeBytes!: number;
}
```
`dto/set-article-documents.dto.ts`:
```ts
import { ApiProperty } from '@nestjs/swagger';
import { ArrayMaxSize, IsArray, IsUUID } from 'class-validator';
import { DOCUMENT_MAX_COUNT } from '../document-limits.js';

export class SetArticleDocumentsDto {
  @ApiProperty({ type: [String], description: 'The full set of attached document ids' })
  @IsArray()
  @ArrayMaxSize(DOCUMENT_MAX_COUNT)
  @IsUUID('4', { each: true })
  documentIds!: string[];
}
```

- [ ] **Step 2: Failing service spec** `test/documents/documents-service.spec.ts`:

```ts
import { ConflictException, NotFoundException, BadRequestException } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import * as schema from '../../src/database/schema/index.js';
import type { Tx } from '../../src/database/tx.js';
import { withRollback } from '../support/db.js';
import { makeArticle, makeWriter } from '../support/fixtures/ledger.js';
import { DocumentsService } from '../../src/documents/documents.service.js';
import { INGEST_DOCUMENT, PURGE_DOCUMENT } from '../../src/documents/documents.queue.js';

function build(tx: Tx) {
  const queue = { add: jest.fn(async () => undefined) };
  const storage = {
    presignUpload: jest.fn(async () => ({ uploadUrl: 'http://put', storageKey: 'k.pdf' })),
    presignDownload: jest.fn(async () => 'http://get'),
  };
  return { service: new DocumentsService(tx, queue as never, storage as never), queue, storage };
}

const register = (service: DocumentsService, ownerId: string, filename = 'notes.pdf') =>
  service.register(ownerId, { storageKey: 'k.pdf', filename, sizeBytes: 10 });

describe('DocumentsService', () => {
  it('registers as pending, derives title and type, enqueues ingestion', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service, queue } = build(tx);
      const doc = await register(service, ownerId, 'Field Notes.PDF');
      expect(doc).toMatchObject({ title: 'Field Notes', contentType: 'application/pdf', status: 'pending' });
      expect(queue.add).toHaveBeenCalledWith(INGEST_DOCUMENT, { documentId: doc.id });
    }));

  it('refuses an unsupported extension', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service } = build(tx);
      await expect(register(service, ownerId, 'photo.png')).rejects.toBeInstanceOf(BadRequestException);
    }));

  it('refuses the 21st live document with a 409, not counting deleted ones', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service } = build(tx);
      for (let i = 0; i < 20; i++) await register(service, ownerId, `d${i}.md`);
      await expect(register(service, ownerId, 'one-more.md')).rejects.toThrow(ConflictException);
      // Deleting one frees a slot: the cap counts live rows only.
      const [first] = await tx.select({ id: schema.documents.id }).from(schema.documents).limit(1);
      await service.remove(ownerId, first.id);
      await expect(register(service, ownerId, 'one-more.md')).resolves.toBeDefined();
    }));

  it('answers 404 for another writer\'s document on every read', () =>
    withRollback(async (tx) => {
      const owner = await makeWriter(tx);
      const other = await makeWriter(tx);
      const { service } = build(tx);
      const doc = await register(service, owner.id);
      await expect(service.fileUrl(other.id, doc.id)).rejects.toThrow(NotFoundException);
      await expect(service.retry(other.id, doc.id)).rejects.toThrow(NotFoundException);
      await expect(service.remove(other.id, doc.id)).rejects.toThrow(NotFoundException);
    }));

  it('remove soft-deletes and enqueues the purge', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service, queue } = build(tx);
      const doc = await register(service, ownerId);
      await service.remove(ownerId, doc.id);
      const r = await tx.execute<{ n: number }>(sql`SELECT COUNT(*)::int AS n FROM documents WHERE id = ${doc.id} AND deleted_at IS NOT NULL`);
      expect(r.rows[0].n).toBe(1);
      expect(queue.add).toHaveBeenCalledWith(PURGE_DOCUMENT, { documentId: doc.id });
      // Gone from the list.
      const list = await service.list(ownerId);
      expect(list.items.find((d) => d.id === doc.id)).toBeUndefined();
    }));

  it('retry only re-queues a failed document', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service, queue } = build(tx);
      const doc = await register(service, ownerId);
      await expect(service.retry(ownerId, doc.id)).rejects.toThrow(ConflictException);
      await tx.update(schema.documents).set({ status: 'failed', error: 'x' });
      const retried = await service.retry(ownerId, doc.id);
      expect(retried.status).toBe('pending');
      expect(queue.add).toHaveBeenLastCalledWith(INGEST_DOCUMENT, { documentId: doc.id });
    }));

  it('attaches only the caller\'s own documents to the caller\'s own article', () =>
    withRollback(async (tx) => {
      const owner = await makeWriter(tx);
      const other = await makeWriter(tx);
      const { service } = build(tx);
      const mine = await register(service, owner.id, 'mine.md');
      const theirs = await register(service, other.id, 'theirs.md');
      const article = await makeArticle(tx, { authorId: owner.id });
      const foreignArticle = await makeArticle(tx, { authorId: other.id });

      await expect(service.setForArticle(owner.id, article.id, [mine.id, theirs.id])).rejects.toThrow(NotFoundException);
      await expect(service.setForArticle(owner.id, foreignArticle.id, [mine.id])).rejects.toThrow(NotFoundException);

      const attached = await service.setForArticle(owner.id, article.id, [mine.id]);
      expect(attached.map((d) => d.id)).toEqual([mine.id]);
      // Replacing the set detaches what is not in it.
      expect(await service.setForArticle(owner.id, article.id, [])).toEqual([]);
      const r = await tx.execute<{ n: number }>(sql`SELECT COUNT(*)::int AS n FROM article_documents WHERE article_id = ${article.id}`);
      expect(r.rows[0].n).toBe(0);
    }));

  it('attachedReadyDocumentIds ignores pending, failed and deleted documents', () =>
    withRollback(async (tx) => {
      const { id: ownerId } = await makeWriter(tx);
      const { service } = build(tx);
      const a = await register(service, ownerId, 'a.md');
      const b = await register(service, ownerId, 'b.md');
      const article = await makeArticle(tx, { authorId: ownerId });
      await service.setForArticle(ownerId, article.id, [a.id, b.id]);
      await tx.update(schema.documents).set({ status: 'ready' }).where(sql`id = ${a.id}`);
      expect(await service.attachedReadyDocumentIds(article.id, ownerId)).toEqual([a.id]);
    }));
});
```
Run → FAIL (module not found).

- [ ] **Step 3: `src/documents/documents.service.ts`**:

```ts
import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import type { Queue } from 'bullmq';
import { and, desc, eq, inArray, isNull, sql } from 'drizzle-orm';
import { DRIZZLE } from '../database/database.module.js';
import * as schema from '../database/schema/index.js';
import { withTx, type DbOrTx } from '../database/tx.js';
import { assertFound } from '../common/ownership.js';
import { DocumentStorageService } from './document-storage.service.js';
import { DOCUMENTS_QUEUE, INGEST_DOCUMENT, PURGE_DOCUMENT } from './documents.queue.js';
import {
  DOCUMENT_FILE_URL_TTL_SECONDS,
  DOCUMENT_MAX_BYTES,
  DOCUMENT_MAX_COUNT,
  LIBRARY_FULL_MESSAGE,
  documentTypeFromFilename,
  titleFromFilename,
} from './document-limits.js';
import type { RegisterDocumentDto } from './dto/register-document.dto.js';

/** A document as the library and the dock see it. Never the storage key. */
export interface DocumentRow {
  id: string;
  title: string;
  filename: string;
  contentType: string;
  sizeBytes: number;
  status: 'pending' | 'extracting' | 'ready' | 'failed';
  pageCount: number | null;
  chunkCount: number | null;
  error: string | null;
  createdAt: Date;
}

/** The public columns, reused by every select here. */
const ROW = {
  id: schema.documents.id,
  title: schema.documents.title,
  filename: schema.documents.filename,
  contentType: schema.documents.contentType,
  sizeBytes: schema.documents.sizeBytes,
  status: schema.documents.status,
  pageCount: schema.documents.pageCount,
  chunkCount: schema.documents.chunkCount,
  error: schema.documents.error,
  createdAt: schema.documents.createdAt,
};

/**
 * The writer's document library and its per-article attachments.
 *
 * ## Ownership is 404, not 403
 *
 * Every query filters on `owner_id = caller` and then `assertFound`s, so a
 * document that exists but is someone else's is indistinguishable from one
 * that never existed. That is the exception `common/ownership.ts` reserves for
 * endpoints that "must not admit existence": a document is private material,
 * and its id must not confirm that a stranger uploaded something.
 */
@Injectable()
export class DocumentsService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbOrTx,
    @InjectQueue(DOCUMENTS_QUEUE) private readonly queue: Queue,
    private readonly storage: DocumentStorageService,
  ) {}

  /** A presigned PUT; the type is checked here too so an unsupported file never reaches the bucket. */
  async presign(filename: string): Promise<{ uploadUrl: string; storageKey: string }> {
    if (!documentTypeFromFilename(filename)) {
      throw new BadRequestException('Only PDF, DOCX, TXT and MD files are supported');
    }
    return this.storage.presignUpload(filename);
  }

  /** Registers an uploaded object as a document and queues its ingestion. */
  async register(ownerId: string, dto: RegisterDocumentDto): Promise<DocumentRow> {
    const contentType = documentTypeFromFilename(dto.filename);
    if (!contentType) {
      throw new BadRequestException('Only PDF, DOCX, TXT and MD files are supported');
    }
    if (dto.sizeBytes > DOCUMENT_MAX_BYTES) {
      throw new BadRequestException('Documents must be under 10 MB');
    }

    const row = await withTx(this.db, async (tx) => {
      // Counted inside the transaction so two concurrent uploads cannot both
      // see 19 and both succeed.
      const [{ n }] = await tx
        .select({ n: sql<number>`COUNT(*)::int` })
        .from(schema.documents)
        .where(and(eq(schema.documents.ownerId, ownerId), isNull(schema.documents.deletedAt)));
      if (n >= DOCUMENT_MAX_COUNT) throw new ConflictException(LIBRARY_FULL_MESSAGE);

      const [inserted] = await tx
        .insert(schema.documents)
        .values({
          ownerId,
          title: titleFromFilename(dto.filename),
          filename: dto.filename,
          contentType,
          sizeBytes: dto.sizeBytes,
          storageKey: dto.storageKey,
        })
        .returning(ROW);
      return inserted;
    });

    // After the commit: a job for a row that rolled back would fail on
    // not-found forever.
    await this.queue.add(INGEST_DOCUMENT, { documentId: row.id });
    return row;
  }

  /** The library, newest first, with the cap so the page can say "N of 20". */
  async list(ownerId: string): Promise<{ items: DocumentRow[]; count: number; max: number }> {
    const items = await this.db
      .select(ROW)
      .from(schema.documents)
      .where(and(eq(schema.documents.ownerId, ownerId), isNull(schema.documents.deletedAt)))
      .orderBy(desc(schema.documents.createdAt));
    return { items, count: items.length, max: DOCUMENT_MAX_COUNT };
  }

  /** One owned, live document — or 404. */
  private async findOwned(ownerId: string, id: string) {
    const [row] = await this.db
      .select({ ...ROW, storageKey: schema.documents.storageKey })
      .from(schema.documents)
      .where(and(eq(schema.documents.id, id), eq(schema.documents.ownerId, ownerId), isNull(schema.documents.deletedAt)))
      .limit(1);
    return assertFound(row, 'Document');
  }

  /** A short-lived URL the browser opens directly; see DocumentStorageService. */
  async fileUrl(ownerId: string, id: string): Promise<{ url: string; expiresInSeconds: number }> {
    const doc = await this.findOwned(ownerId, id);
    const url = await this.storage.presignDownload(doc.storageKey, doc.contentType, doc.filename);
    return { url, expiresInSeconds: DOCUMENT_FILE_URL_TTL_SECONDS };
  }

  /** Re-queues a failed document. A 409 for any other status: a retry of a ready document would only rebuild what exists. */
  async retry(ownerId: string, id: string): Promise<DocumentRow> {
    const doc = await this.findOwned(ownerId, id);
    if (doc.status !== 'failed') {
      throw new ConflictException('Only a failed document can be retried');
    }
    const [row] = await this.db
      .update(schema.documents)
      .set({ status: 'pending', error: null })
      .where(eq(schema.documents.id, id))
      .returning(ROW);
    await this.queue.add(INGEST_DOCUMENT, { documentId: id });
    return row;
  }

  /** Soft delete now (retrieval stops at once); the purge job removes the object and the row. */
  async remove(ownerId: string, id: string): Promise<void> {
    await this.findOwned(ownerId, id);
    await this.db
      .update(schema.documents)
      .set({ deletedAt: new Date() })
      .where(eq(schema.documents.id, id));
    await this.queue.add(PURGE_DOCUMENT, { documentId: id });
  }

  /** The caller's own article, or 404 — attachments are private to the author. */
  private async assertOwnArticle(ownerId: string, articleId: string): Promise<void> {
    const [article] = await this.db
      .select({ id: schema.articles.id })
      .from(schema.articles)
      .where(and(eq(schema.articles.id, articleId), eq(schema.articles.authorId, ownerId), isNull(schema.articles.deletedAt)))
      .limit(1);
    assertFound(article, 'Article');
  }

  /** Documents attached to an article, in attachment order. */
  async listForArticle(ownerId: string, articleId: string): Promise<DocumentRow[]> {
    await this.assertOwnArticle(ownerId, articleId);
    return this.db
      .select(ROW)
      .from(schema.articleDocuments)
      .innerJoin(schema.documents, eq(schema.documents.id, schema.articleDocuments.documentId))
      .where(and(eq(schema.articleDocuments.articleId, articleId), isNull(schema.documents.deletedAt)))
      .orderBy(schema.articleDocuments.createdAt);
  }

  /**
   * Replaces the attachment set. The whole set travels rather than a diff so
   * the client's chips and the table cannot drift; a document id that is not
   * the caller's is a 404 for the whole request (nothing is written).
   */
  async setForArticle(ownerId: string, articleId: string, documentIds: string[]): Promise<DocumentRow[]> {
    await this.assertOwnArticle(ownerId, articleId);
    const unique = [...new Set(documentIds)];

    if (unique.length > 0) {
      const owned = await this.db
        .select({ id: schema.documents.id })
        .from(schema.documents)
        .where(and(inArray(schema.documents.id, unique), eq(schema.documents.ownerId, ownerId), isNull(schema.documents.deletedAt)));
      if (owned.length !== unique.length) throw new NotFoundException('Document not found');
    }

    await withTx(this.db, async (tx) => {
      await tx.delete(schema.articleDocuments).where(eq(schema.articleDocuments.articleId, articleId));
      if (unique.length > 0) {
        await tx.insert(schema.articleDocuments).values(unique.map((documentId) => ({ articleId, documentId })));
      }
    });

    return this.listForArticle(ownerId, articleId);
  }

  /** The attached documents retrieval may use: owner's, live, ready. Called by the assistant turn. */
  async attachedReadyDocumentIds(articleId: string, ownerId: string): Promise<string[]> {
    const rows = await this.db
      .select({ id: schema.documents.id })
      .from(schema.articleDocuments)
      .innerJoin(schema.documents, eq(schema.documents.id, schema.articleDocuments.documentId))
      .where(
        and(
          eq(schema.articleDocuments.articleId, articleId),
          eq(schema.documents.ownerId, ownerId),
          isNull(schema.documents.deletedAt),
          eq(schema.documents.status, 'ready'),
        ),
      );
    return rows.map((r) => r.id);
  }
}
```

- [ ] **Step 4: Run the spec** → PASS (8 cases). If `findOwned`'s `assertFound(row, 'Document')` typing complains about the spread select, keep `ROW` inline.

- [ ] **Step 5: Controller** `src/documents/documents.controller.ts`:

```ts
import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Post, Put } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Auth } from '../common/decorators/auth.decorator.js';
import { CurrentUser } from '../common/decorators/current-user.decorator.js';
import { DocumentsService } from './documents.service.js';
import { PresignDocumentDto } from './dto/presign-document.dto.js';
import { RegisterDocumentDto } from './dto/register-document.dto.js';
import { SetArticleDocumentsDto } from './dto/set-article-documents.dto.js';

/**
 * The document library and per-article attachments.
 *
 * One controller with no prefix, the SavesController arrangement: six routes
 * under `documents` and two under `articles/:articleId/documents`. The latter
 * are three segments, so they cannot shadow ArticlesController's two-segment
 * `articles/:slug`. Personal accounts only — a magazine has no editor.
 */
@ApiTags('Documents')
@Controller()
export class DocumentsController {
  constructor(private readonly documents: DocumentsService) {}

  @Post('documents/presign')
  @Auth('Get a presigned upload URL for a document', { accountTypes: ['personal'] })
  presign(@Body() dto: PresignDocumentDto) {
    return this.documents.presign(dto.filename);
  }

  @Post('documents')
  @Auth('Register an uploaded document and queue its ingestion', { accountTypes: ['personal'] })
  register(@CurrentUser('sub') userId: string, @Body() dto: RegisterDocumentDto) {
    return this.documents.register(userId, dto);
  }

  @Get('documents')
  @Auth('List my documents', { accountTypes: ['personal'] })
  list(@CurrentUser('sub') userId: string) {
    return this.documents.list(userId);
  }

  @Get('documents/:id/file')
  @Auth('Get a short-lived URL to open a document', { accountTypes: ['personal'] })
  file(@CurrentUser('sub') userId: string, @Param('id', ParseUUIDPipe) id: string) {
    return this.documents.fileUrl(userId, id);
  }

  @Post('documents/:id/retry')
  @Auth('Retry a failed document', { accountTypes: ['personal'] })
  retry(@CurrentUser('sub') userId: string, @Param('id', ParseUUIDPipe) id: string) {
    return this.documents.retry(userId, id);
  }

  @Delete('documents/:id')
  @HttpCode(204)
  @Auth('Delete a document', { accountTypes: ['personal'] })
  remove(@CurrentUser('sub') userId: string, @Param('id', ParseUUIDPipe) id: string) {
    return this.documents.remove(userId, id);
  }

  @Get('articles/:articleId/documents')
  @Auth('Documents attached to my article', { accountTypes: ['personal'] })
  listForArticle(@CurrentUser('sub') userId: string, @Param('articleId', ParseUUIDPipe) articleId: string) {
    return this.documents.listForArticle(userId, articleId);
  }

  @Put('articles/:articleId/documents')
  @Auth('Replace the documents attached to my article', { accountTypes: ['personal'] })
  setForArticle(
    @CurrentUser('sub') userId: string,
    @Param('articleId', ParseUUIDPipe) articleId: string,
    @Body() dto: SetArticleDocumentsDto,
  ) {
    return this.documents.setForArticle(userId, articleId, dto.documentIds);
  }
}
```

- [ ] **Step 6: Module** `src/documents/documents.module.ts` and AppModule:

```ts
import { Module } from '@nestjs/common';
import { BullModule } from '@nestjs/bullmq';
import { DocumentsController } from './documents.controller.js';
import { DocumentsService } from './documents.service.js';
import { DocumentStorageService } from './document-storage.service.js';
import { DOCUMENTS_QUEUE } from './documents.queue.js';

/**
 * Producer side only: registers the queue so DocumentsService can enqueue,
 * and deliberately does NOT list DocumentsProcessor — that lives in
 * WorkerModule, or the API would compete with the worker for jobs.
 */
@Module({
  imports: [BullModule.registerQueue({ name: DOCUMENTS_QUEUE })],
  controllers: [DocumentsController],
  providers: [DocumentsService, DocumentStorageService],
  exports: [DocumentsService],
})
export class DocumentsModule {}
```
In `src/app.module.ts` import and add `DocumentsModule` to `imports` after `UploadsModule`. Check the router log: `docker logs --tail 80 inkwell-api-1 | grep -i documents` → the eight mapped routes.

- [ ] **Step 7: Live smoke from the container** — write `src/backend.inkwell.ai/probe-docs.mjs` (delete after):

```js
// Login → presign → PUT a small markdown file → register → poll until ready → attach → file URL → delete.
const API = 'http://localhost:3000/api';
const login = await fetch(`${API}/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: 'tomas@example.com', password: 'InkwellDemo123!' }) }).then((r) => r.json());
const h = { authorization: `Bearer ${login.accessToken}`, 'content-type': 'application/json' };
const pre = await fetch(`${API}/documents/presign`, { method: 'POST', headers: h, body: JSON.stringify({ filename: 'probe.md' }) }).then((r) => r.json());
const body = '# Tides\n\nSpring tides happen twice a month when the sun and moon align, and the range between high and low water is greatest.';
const put = await fetch(pre.uploadUrl.replace('storage.inkwell.ai', 'nginx'), { method: 'PUT', body, headers: { host: 'storage.inkwell.ai', 'content-type': 'text/markdown' } });
console.log('PUT', put.status);
const doc = await fetch(`${API}/documents`, { method: 'POST', headers: h, body: JSON.stringify({ storageKey: pre.storageKey, filename: 'probe.md', sizeBytes: body.length }) }).then((r) => r.json());
console.log('registered', doc.status, doc.id);
for (let i = 0; i < 20; i++) {
  await new Promise((r) => setTimeout(r, 1500));
  const { items } = await fetch(`${API}/documents`, { headers: h }).then((r) => r.json());
  const row = items.find((d) => d.id === doc.id);
  console.log('status', row.status, row.error ?? '', row.pageCount, row.chunkCount);
  if (row.status === 'ready' || row.status === 'failed') break;
}
console.log('file', await fetch(`${API}/documents/${doc.id}/file`, { headers: h }).then((r) => r.status));
console.log('delete', (await fetch(`${API}/documents/${doc.id}`, { method: 'DELETE', headers: h })).status);
```
Run: `docker exec -w /app inkwell-api-1 node probe-docs.mjs`. Expected: `PUT 200`, `registered pending`, then `status ready  1 1`, `file 200`, `delete 204`. If the PUT via the nginx hostname fails inside the container, PUT directly to `http://minio:9000` is NOT valid (signature covers Host) — instead check the login field name in `AuthController` and the `host` header trick; report what you saw. Then `rm probe-docs.mjs` and confirm the purge ran: `docker exec inkwell-db-1 psql -U inkwell -d inkwell -c "SELECT COUNT(*) FROM documents"` → 0.

- [ ] **Step 8: Gates and commit**: `tsc --noEmit`, `npm run lint`, `npm test`; `git add src/documents src/app.module.ts test/documents && git commit -m "feat: document library API — upload, list, retry, delete, per-article attachments"`

---

### Task 7: Document retrieval

**Files:**
- Create: `src/ai/document-retrieval.query.ts`, `test/documents/document-retrieval.spec.ts`
- Modify: `src/ai/retrieval.service.ts`

**Interfaces:**
- Produces: `RetrievedDocumentChunk { chunkId, documentId, documentTitle, contentType, page, chunkIndex, content, similarity }`; `searchDocumentChunks(db, queryVector, { ownerId, documentIds, topK?, minSimilarity? })`; `RetrievalService.findSimilarDocumentChunks(query, { ownerId, documentIds, topK?, minSimilarity? })`. Task 8 consumes both types.

- [ ] **Step 1: Failing spec** `test/documents/document-retrieval.spec.ts`:

```ts
import { sql } from 'drizzle-orm';
import * as schema from '../../src/database/schema/index.js';
import type { Tx } from '../../src/database/tx.js';
import { withRollback } from '../support/db.js';
import { makeWriter } from '../support/fixtures/ledger.js';
import { searchDocumentChunks } from '../../src/ai/document-retrieval.query.js';

/** Unit vector along axis `axis` — cosine 1 with itself, 0 with any other axis. */
const unit = (axis: number) => Array.from({ length: 1536 }, (_, i) => (i === axis ? 1 : 0));

async function doc(tx: Tx, ownerId: string, status: 'ready' | 'pending' | 'failed' = 'ready', deleted = false) {
  const [row] = await tx.insert(schema.documents).values({
    ownerId, title: `t-${status}`, filename: 'a.pdf', contentType: 'application/pdf', sizeBytes: 1, storageKey: 'k', status,
    deletedAt: deleted ? new Date() : null,
  }).returning({ id: schema.documents.id });
  await tx.insert(schema.documentChunks).values({ documentId: row.id, chunkIndex: 0, page: 3, content: `chunk of ${row.id}`, embedding: unit(0) });
  return row.id;
}

describe('searchDocumentChunks', () => {
  it('returns only the owner\'s attached, ready, live documents above the floor', () =>
    withRollback(async (tx) => {
      const owner = await makeWriter(tx);
      const other = await makeWriter(tx);
      const attachedReady = await doc(tx, owner.id);
      const unattached = await doc(tx, owner.id);
      const pending = await doc(tx, owner.id, 'pending');
      const deleted = await doc(tx, owner.id, 'ready', true);
      const foreign = await doc(tx, other.id);

      const hits = await searchDocumentChunks(tx, unit(0), {
        ownerId: owner.id,
        documentIds: [attachedReady, pending, deleted, foreign],
      });

      expect(hits.map((h) => h.documentId)).toEqual([attachedReady]);
      expect(hits[0]).toMatchObject({ page: 3, documentTitle: 't-ready', contentType: 'application/pdf' });
      expect(hits[0].similarity).toBeCloseTo(1, 5);
      // Independently: five chunks exist, one qualifies.
      const r = await tx.execute<{ n: number }>(sql`SELECT COUNT(*)::int AS n FROM document_chunks`);
      expect(r.rows[0].n).toBeGreaterThanOrEqual(5);
      expect([unattached]).not.toContain(hits[0].documentId === unattached);
    }));

  it('applies the similarity floor and top-K', () =>
    withRollback(async (tx) => {
      const owner = await makeWriter(tx);
      const id = await doc(tx, owner.id);
      // A second chunk orthogonal to the query: similarity 0, below 0.6.
      await tx.insert(schema.documentChunks).values({ documentId: id, chunkIndex: 1, page: 4, content: 'far', embedding: unit(5) });
      const hits = await searchDocumentChunks(tx, unit(0), { ownerId: owner.id, documentIds: [id], topK: 5 });
      expect(hits).toHaveLength(1);
      expect(hits[0].page).toBe(3);
    }));

  it('returns nothing for an empty attachment list without querying', () =>
    withRollback(async (tx) => {
      const owner = await makeWriter(tx);
      expect(await searchDocumentChunks(tx, unit(0), { ownerId: owner.id, documentIds: [] })).toEqual([]);
    }));
});
```
Run → FAIL.

- [ ] **Step 2: `src/ai/document-retrieval.query.ts`** (imports only drizzle + schema, so the spec can load it):

```ts
import { and, cosineDistance, desc, eq, gt, inArray, isNull, sql } from 'drizzle-orm';
import * as schema from '../database/schema/index.js';
import type { DbOrTx } from '../database/tx.js';

/** Passages per turn — the same budget as the voice retrieval (§9.3.2). */
export const DOCUMENT_RETRIEVAL_TOP_K = 5;

/**
 * Floor for uploaded material. Starts at the voice floor; Task 0 measured
 * on-topic vs off-topic for this corpus and the number here is that finding.
 * Re-measure if the embedding model changes.
 */
export const DOCUMENT_MIN_SIMILARITY = 0.6;

/** One retrieved passage from an uploaded document. */
export interface RetrievedDocumentChunk {
  chunkId: string;
  documentId: string;
  documentTitle: string;
  /** Lets the citation drop the page for DOCX/text, which have none. */
  contentType: string;
  page: number;
  chunkIndex: number;
  content: string;
  /** Cosine similarity in [0,1]; higher is closer. */
  similarity: number;
}

export interface DocumentSearchOptions {
  ownerId: string;
  /** The article's attached documents. Empty → no query at all. */
  documentIds: string[];
  topK?: number;
  minSimilarity?: number;
}

/**
 * The scoped vector search over `document_chunks`.
 *
 * A plain function taking the database handle, not a method on
 * RetrievalService, so a spec can exercise the scoping with a synthetic vector
 * — RetrievalService value-imports the embedding provider, which jest cannot
 * load. The service embeds the query and calls this.
 *
 * Four filters, all load-bearing: owner (privacy), attached (the writer chose
 * these for this article), ready (a half-ingested document has no chunks
 * worth trusting), live (a soft delete stops retrieval before the purge runs).
 */
export async function searchDocumentChunks(
  db: DbOrTx,
  queryVector: number[],
  { ownerId, documentIds, topK = DOCUMENT_RETRIEVAL_TOP_K, minSimilarity = DOCUMENT_MIN_SIMILARITY }: DocumentSearchOptions,
): Promise<RetrievedDocumentChunk[]> {
  if (documentIds.length === 0) return [];

  const similarity = sql<number>`1 - (${cosineDistance(schema.documentChunks.embedding, queryVector)})`;

  return db
    .select({
      chunkId: schema.documentChunks.id,
      documentId: schema.documentChunks.documentId,
      documentTitle: schema.documents.title,
      contentType: schema.documents.contentType,
      page: schema.documentChunks.page,
      chunkIndex: schema.documentChunks.chunkIndex,
      content: schema.documentChunks.content,
      similarity,
    })
    .from(schema.documentChunks)
    .innerJoin(schema.documents, eq(schema.documents.id, schema.documentChunks.documentId))
    .where(
      and(
        eq(schema.documents.ownerId, ownerId),
        inArray(schema.documents.id, documentIds),
        eq(schema.documents.status, 'ready'),
        isNull(schema.documents.deletedAt),
        gt(similarity, minSimilarity),
      ),
    )
    .orderBy((t) => desc(t.similarity))
    .limit(topK);
}
```
If Task 0 found 0.60 does not separate the bands, set `DOCUMENT_MIN_SIMILARITY` to the measured midpoint and say so in the comment.

- [ ] **Step 3: Run the spec** → PASS.

- [ ] **Step 4: Service method** — in `src/ai/retrieval.service.ts` add the import `import { searchDocumentChunks, type DocumentSearchOptions, type RetrievedDocumentChunk } from './document-retrieval.query.js';`, re-export the type (`export type { RetrievedDocumentChunk }`), and after `findSimilarChunks`:

```ts
  /**
   * Passages from the documents attached to the article being edited.
   *
   * The other corpus: reference material, not voice. Same degradation rule as
   * `findSimilarChunks` — an embedding failure returns `[]`, and the turn
   * proceeds without the block rather than failing.
   */
  async findSimilarDocumentChunks(
    query: string,
    options: DocumentSearchOptions,
  ): Promise<RetrievedDocumentChunk[]> {
    if (!this.embeddings.isConfigured || options.documentIds.length === 0) return [];
    try {
      const queryVector = await this.embeddings.embedQuery(query);
      return await searchDocumentChunks(this.db, queryVector, options);
    } catch (error) {
      this.logger.warn(
        `Document retrieval failed, continuing without reference material: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return [];
    }
  }
```

- [ ] **Step 5: Gates and commit**: `tsc --noEmit`, `npm run lint`, `npm test`; `git add src/ai test/documents && git commit -m "feat: scoped retrieval over document chunks"`

---

### Task 8: The assistant turn — `documents` step, reference block, citations

**Files:**
- Create: `src/ai/prompts/reference.prompt.ts`, `src/ai/prompts/reference.prompt.spec.ts`
- Modify: `src/ai/chat-status.ts` (+ `chat-status.spec.ts`), `src/ai/article-write-stream.ts`, `src/ai/prompts/chat.prompt.ts`, `src/ai/ai.service.ts`, `src/ai/ai.module.ts`

**Interfaces:**
- Consumes: `DocumentsService.attachedReadyDocumentIds`, `RetrievalService.findSimilarDocumentChunks`.
- Produces on the wire: `data-status` parts with `step: 'documents'` and `passages: RetrievedDocumentChunk[]` (Task 11 reads them).

- [ ] **Step 1: Failing prompt spec** `src/ai/prompts/reference.prompt.spec.ts`:

```ts
import { buildReferenceBlock, citationLabel } from './reference.prompt.js';
import type { RetrievedDocumentChunk } from '../document-retrieval.query.js';

const chunk = (over: Partial<RetrievedDocumentChunk>): RetrievedDocumentChunk => ({
  chunkId: 'c', documentId: 'd', documentTitle: 'Field notes', contentType: 'application/pdf',
  page: 4, chunkIndex: 0, content: 'Spring tides happen twice a month.', similarity: 0.7, ...over,
});

describe('citationLabel', () => {
  it('names the page for a PDF', () => {
    expect(citationLabel('Field notes', 4, 'application/pdf')).toBe('[Field notes, p. 4]');
  });
  it('drops the page for DOCX and text', () => {
    expect(citationLabel('Memo', 1, 'text/markdown')).toBe('[Memo]');
    expect(citationLabel('Memo', 1, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document')).toBe('[Memo]');
  });
});

describe('buildReferenceBlock', () => {
  it('is empty with no passages', () => {
    expect(buildReferenceBlock([])).toBe('');
  });
  it('carries the instruction and labels each passage', () => {
    const block = buildReferenceBlock([chunk({}), chunk({ contentType: 'text/plain', documentTitle: 'Memo', content: 'Braid beats nylon.' })]);
    expect(block).toContain('Reference material the writer attached. Use it for facts and structure; do not imitate its style. When you use a passage, cite it inline as [Title, p. N].');
    expect(block).toContain('[Field notes, p. 4]\nSpring tides happen twice a month.');
    expect(block).toContain('[Memo]\nBraid beats nylon.');
  });
});
```
Run: `npm test -- src/ai/prompts/reference.prompt.spec.ts` → FAIL.

- [ ] **Step 2: `src/ai/prompts/reference.prompt.ts`**:

```ts
import type { RetrievedDocumentChunk } from '../document-retrieval.query.js';

const PDF = 'application/pdf';

/**
 * The citation the model is asked to use, and the label the panel shows.
 *
 * `[Title, p. N]` for PDFs, where the page is real; `[Title]` for DOCX and
 * text, whose "page 1" is a placeholder and would read as a claim.
 */
export function citationLabel(title: string, page: number, contentType: string): string {
  return contentType === PDF ? `[${title}, p. ${page}]` : `[${title}]`;
}

/**
 * The reference block for the prompt — the OPPOSITE instruction to the voice
 * block. Passages from the writer's own articles are there to be imitated;
 * passages from a document are there to be used and cited. Saying which is
 * which is what keeps the model from writing in the tone of a PDF.
 */
export function buildReferenceBlock(passages: RetrievedDocumentChunk[]): string {
  if (passages.length === 0) return '';

  const body = passages
    .map((p) => `${citationLabel(p.documentTitle, p.page, p.contentType)}\n${p.content}`)
    .join('\n\n');

  return `

Reference material the writer attached. Use it for facts and structure; do not imitate its style. When you use a passage, cite it inline as [Title, p. N].

---
${body}
---`;
}
```
Run the spec → PASS.

- [ ] **Step 3: Status step** — `src/ai/chat-status.ts`: change `CHAT_STEPS` to `['draft', 'profile', 'documents', 'thinking', 'retrieval', 'writing', 'done']`, extend the doc comment ("`documents` runs before the routing call because both questions and writes use the block; it is emitted only when the article has attached documents"), add `passages?: RetrievedDocumentChunk[]` to `ChatStatusData` (import the type from `./document-retrieval.query.js`), and give `statusPart` a fifth parameter `passages?: RetrievedDocumentChunk[]` set the same field-by-field way. In `src/ai/chat-status.spec.ts` add:

```ts
  it('places documents between profile and thinking', () => {
    expect(CHAT_STEPS.indexOf('documents')).toBe(CHAT_STEPS.indexOf('profile') + 1);
    expect(CHAT_STEPS.indexOf('thinking')).toBe(CHAT_STEPS.indexOf('documents') + 1);
  });
  it('carries passages only when given', () => {
    expect(statusPart('documents', 'done', '1 passage')).toEqual({ type: 'data-status', data: { step: 'documents', state: 'done', detail: '1 passage' }, transient: true });
  });
```
In `src/ai/article-write-stream.ts` `withStatus`: the `work` return type gains `passages?: RetrievedDocumentChunk[]` and the done write becomes `statusPart(step, 'done', detail, chunks, passages)`.

- [ ] **Step 4: Prompts** — in `chat.prompt.ts`, `buildRoutingSystemPrompt(articleContext?, memoryBlock = '', referenceBlock = '')` appends `${referenceBlock}` after `${memoryBlock}`; `buildArticleWriteSystemPrompt(articleContext, retrieved, memoryBlock, brief, selectionText?, referenceBlock = '')` appends `${referenceBlock}` after `${buildVoiceBlock(retrieved)}`. Update the doc comment on the routing prompt: the reference block IS in the outer call because a question about the material needs it.

- [ ] **Step 5: `ai.service.ts`** — inject `DocumentsService` (constructor: `private documents: DocumentsService`; `AiModule` imports `DocumentsModule`). After the profile stage and before the tool definition:

```ts
        // ── Stage: documents — only when the article has attached sources ──
        // Runs before routing because a QUESTION about the material needs the
        // block as much as a write does. Keyed on the newest user message
        // alone: there is no brief yet at this point in the turn.
        let referenceBlock = '';
        const attachedIds = dto.articleId
          ? await this.documents.attachedReadyDocumentIds(dto.articleId, userId)
          : [];
        if (attachedIds.length > 0) {
          const passages = await withStatus(parts, 'documents', async () => {
            const found = await this.retrieval.findSimilarDocumentChunks(lastUserMessage, {
              ownerId: userId,
              documentIds: attachedIds,
            });
            const docs = new Set(found.map((p) => p.documentId)).size;
            return {
              value: found,
              detail: found.length
                ? `${found.length} passage${found.length === 1 ? '' : 's'} from ${docs} document${docs === 1 ? '' : 's'}`
                : 'nothing close enough in your documents',
              passages: found,
            };
          });
          referenceBlock = buildReferenceBlock(passages);
        }
```
Pass `referenceBlock` as the third argument of `buildRoutingSystemPrompt(...)` and the sixth of `buildArticleWriteSystemPrompt(...)`. Import `buildReferenceBlock` and `DocumentsService`.

- [ ] **Step 6: Gates**: `tsc --noEmit`, `npm run lint`, `npm test`. Restart api (`nest --watch` does it) and check `docker logs --tail 20 inkwell-api-1` for a clean boot.

- [ ] **Step 7: Live check** (probe in the container, delete after): upload + attach a markdown document as in Task 6's probe against an article the seeded writer owns (`SELECT id FROM articles WHERE author_id = (SELECT id FROM users WHERE email='tomas@example.com') AND deleted_at IS NULL LIMIT 1`), then `POST /ai/chat` with `{ messages: [{ role: 'user', parts: [{ type: 'text', text: 'What does my document say about spring tides?' }] }], articleId }` and print the raw stream. Expected: a `data-status` part `{"step":"documents","state":"done","detail":"1 passage from 1 document","passages":[…]}` before `thinking`, and the answer text containing `[probe, p.` or `[probe]`. Afterwards: delete the document, `DELETE FROM ai_interactions WHERE user_id = … AND created_at > now() - interval '10 minutes'`, and restore the balance: `UPDATE users SET ai_tokens_remaining = 20000 WHERE email = 'tomas@example.com'`.

- [ ] **Step 8: Commit**: `git add src/ai && git commit -m "feat: assistant reads attached documents — documents step, reference block, citations"`

---

### Task 9: Frontend — types, hooks, upload helper, library page, nav

**Files:**
- Create: `src/features/documents/document-types.ts`, `src/features/documents/document-upload.ts`, `src/hooks/use-documents.ts`, `src/features/documents/document-status-chip.tsx`, `src/features/documents/documents-view.tsx`, `src/app/(main)/dashboard/documents/page.tsx`
- Modify: `src/lib/constants.ts`, `src/lib/api/query-keys.ts`, `src/components/layout/nav-items.tsx`

**Interfaces:**
- Produces: `DocumentRow` type, `useDocuments()`, `useUploadDocument()`, `useDeleteDocument()`, `useRetryDocument()`, `qk.documents.list()`, `qk.articles.documents(id)`, `ROUTES.dashboardDocuments`. Task 10 reuses `useDocuments` and `DocumentRow`.

- [ ] **Step 1: Constants and keys** — `ROUTES.dashboardDocuments: '/dashboard/documents'` after `dashboardEarnings`; in `qk`:

```ts
  // --- Documents (the writer's reference library) ---------------------------
  documents: {
    all: ['documents'] as const,
    // GET /documents. Polled while any row is pending/extracting — see useDocuments.
    list: () => [...qk.documents.all, 'list'] as const,
  },
```
and inside `qk.articles`: `documents: (id: string) => [...qk.articles.all, 'documents', id] as const,` (comment: `GET /articles/:id/documents` — the Sources strip).

- [ ] **Step 2: `src/features/documents/document-types.ts`**:

```ts
/** A document as `GET /documents` returns it. Mirrors DocumentRow on the API. */
export interface DocumentRow {
  id: string;
  title: string;
  filename: string;
  contentType: string;
  sizeBytes: number;
  status: 'pending' | 'extracting' | 'ready' | 'failed';
  pageCount: number | null;
  chunkCount: number | null;
  error: string | null;
  createdAt: string;
}

export interface DocumentList {
  items: DocumentRow[];
  count: number;
  max: number;
}

/** Client-side mirrors of the API caps — the server is the authority. */
export const DOCUMENT_MAX_BYTES = 10 * 1024 * 1024;
export const DOCUMENT_ACCEPT = '.pdf,.docx,.txt,.md';
/** A row still `pending` after this long means the worker is not picking it up. */
export const DOCUMENT_WAITING_AFTER_MS = 60_000;

/** Short badge text per type. */
export function documentKind(contentType: string): 'PDF' | 'DOCX' | 'TXT' | 'MD' {
  if (contentType === 'application/pdf') return 'PDF';
  if (contentType.includes('wordprocessingml')) return 'DOCX';
  if (contentType === 'text/markdown') return 'MD';
  return 'TXT';
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
```

- [ ] **Step 3: `src/features/documents/document-upload.ts`** — presign → XHR PUT (fetch has no upload progress) → register:

```ts
import axios from 'axios';
import { api } from '@/lib/api/client';
import { DOCUMENT_MAX_BYTES, type DocumentRow } from './document-types';

interface PresignResponse {
  uploadUrl: string;
  storageKey: string;
}

/**
 * Uploads one document: presign → PUT straight to the bucket → register.
 *
 * The PUT goes through bare `axios`, NOT the app's `api` client: that client
 * attaches the bearer token, and a presigned URL must be called with nothing
 * but the file. `onUploadProgress` is why it is axios and not fetch — fetch
 * cannot report upload progress.
 */
export async function uploadDocument(
  file: File,
  onProgress: (fraction: number) => void,
): Promise<DocumentRow> {
  if (file.size > DOCUMENT_MAX_BYTES) throw new Error('Documents must be under 10 MB');
  if (!/\.(pdf|docx|txt|md)$/i.test(file.name)) throw new Error('Only PDF, DOCX, TXT and MD files are supported');

  const { data: presign } = await api.post<PresignResponse>('/documents/presign', { filename: file.name });

  await axios.put(presign.uploadUrl, file, {
    // The extension decides the type server-side; this header only makes the
    // object's type visible in the bucket. Empty for .md on some systems.
    headers: { 'Content-Type': file.type || 'application/octet-stream' },
    onUploadProgress: (e) => onProgress(e.total ? e.loaded / e.total : 0),
  });

  const { data } = await api.post<DocumentRow>('/documents', {
    storageKey: presign.storageKey,
    filename: file.name,
    sizeBytes: file.size,
  });
  return data;
}
```

- [ ] **Step 4: `src/hooks/use-documents.ts`**:

```ts
'use client';

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/lib/api/client';
import { qk } from '@/lib/api/query-keys';
import { uploadDocument } from '@/features/documents/document-upload';
import type { DocumentList, DocumentRow } from '@/features/documents/document-types';

/** How often to poll while something is still being ingested. */
const INGEST_POLL_MS = 3000;

/**
 * The writer's library. Polls every 3 s only while a row is pending or
 * extracting, so a settled library costs nothing and an uploading one shows
 * Ready without a reload.
 */
export function useDocuments(enabled = true) {
  return useQuery<DocumentList>({
    queryKey: qk.documents.list(),
    queryFn: async () => (await api.get<DocumentList>('/documents')).data,
    enabled,
    refetchInterval: (query) =>
      query.state.data?.items.some((d) => d.status === 'pending' || d.status === 'extracting')
        ? INGEST_POLL_MS
        : false,
  });
}

export function useUploadDocument() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ file, onProgress }: { file: File; onProgress: (f: number) => void }) =>
      uploadDocument(file, onProgress),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: qk.documents.all }),
  });
}

export function useDeleteDocument() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      await api.delete(`/documents/${id}`);
    },
    // Both the library and every article's attachment list: a deleted document
    // must vanish from the Sources strip too.
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: qk.documents.all });
      void queryClient.invalidateQueries({ queryKey: [...qk.articles.all, 'documents'] });
    },
  });
}

export function useRetryDocument() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => (await api.post<DocumentRow>(`/documents/${id}/retry`)).data,
    onSuccess: () => queryClient.invalidateQueries({ queryKey: qk.documents.all }),
  });
}
```

- [ ] **Step 5: Status chip** `src/features/documents/document-status-chip.tsx`:

```tsx
'use client';

import { Loader2, Check, XCircle, Clock } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { DOCUMENT_WAITING_AFTER_MS, type DocumentRow } from './document-types';

/**
 * Extracting… · Ready · Failed (with the reason) · Waiting… — the last one
 * when a row has sat in `pending` for over a minute, which means the worker
 * is not running rather than that the document is slow.
 */
export function DocumentStatusChip({ doc }: { doc: DocumentRow }) {
  if (doc.status === 'ready') {
    return <Badge variant="secondary" className="gap-1"><Check className="size-3" /> Ready</Badge>;
  }
  if (doc.status === 'failed') {
    return (
      <span className="flex flex-col gap-0.5">
        <Badge variant="destructive" className="w-fit gap-1"><XCircle className="size-3" /> Failed</Badge>
        {doc.error && <span className="text-xs text-muted-foreground">{doc.error}</span>}
      </span>
    );
  }
  const waiting = doc.status === 'pending' && Date.now() - new Date(doc.createdAt).getTime() > DOCUMENT_WAITING_AFTER_MS;
  return (
    <Badge variant="outline" className="gap-1">
      {waiting ? <Clock className="size-3" /> : <Loader2 className="size-3 animate-spin" />}
      {waiting ? 'Waiting…' : 'Extracting…'}
    </Badge>
  );
}
```
Check `Badge`'s variants in `src/components/ui/badge.tsx` and use the ones that exist.

- [ ] **Step 6: The view** `src/features/documents/documents-view.tsx` — follow `my-articles-view.tsx`'s imports (Table, Button, EmptyState, ErrorState, ConfirmDialog, toast):

```tsx
'use client';

import { useRef, useState } from 'react';
import { FileUp, Trash2, RotateCcw, FileText } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { Badge } from '@/components/ui/badge';
import { ConfirmDialog } from '@/components/ui/confirm-dialog';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { EmptyState } from '@/components/shared/empty-state';
import { ErrorState } from '@/components/shared/error-state';
import { useDeleteDocument, useDocuments, useRetryDocument, useUploadDocument } from '@/hooks/use-documents';
import { getApiErrorMessage } from '@/lib/api/error';
import { formatRelative } from '@/lib/format';
import { DocumentStatusChip } from './document-status-chip';
import { DOCUMENT_ACCEPT, documentKind, formatBytes, type DocumentRow } from './document-types';

/**
 * The writer's reference library: upload, watch ingestion, retry, delete.
 *
 * Upload is a plain file input behind a button; progress is the PUT to the
 * bucket, after which the row appears as Extracting and the list polls until
 * the worker settles it (see useDocuments).
 */
export function DocumentsView() {
  const inputRef = useRef<HTMLInputElement>(null);
  const [progress, setProgress] = useState<number | null>(null);
  const [pendingDelete, setPendingDelete] = useState<DocumentRow | null>(null);

  const { data, isPending, error, refetch } = useDocuments();
  const upload = useUploadDocument();
  const remove = useDeleteDocument();
  const retry = useRetryDocument();

  const full = !!data && data.count >= data.max;

  const onPick = async (file: File | undefined) => {
    if (!file) return;
    setProgress(0);
    try {
      await upload.mutateAsync({ file, onProgress: setProgress });
    } catch (err) {
      toast.error(err instanceof Error && !('isAxiosError' in err) ? err.message : getApiErrorMessage(err, 'Could not upload the document'));
    } finally {
      setProgress(null);
      if (inputRef.current) inputRef.current.value = '';
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Documents</h1>
          <p className="text-sm text-muted-foreground">
            Reference material the assistant can draw on when you attach it to an article.
            {data && ` ${data.count} of ${data.max}.`}
          </p>
          {full && <p className="text-sm text-destructive">20 of 20 — delete one to upload another</p>}
        </div>
        <div className="flex items-center gap-3">
          {progress !== null && <Progress value={Math.round(progress * 100)} className="w-32" />}
          <input
            ref={inputRef}
            type="file"
            accept={DOCUMENT_ACCEPT}
            className="hidden"
            onChange={(e) => void onPick(e.target.files?.[0])}
          />
          <Button onClick={() => inputRef.current?.click()} disabled={full || progress !== null}>
            <FileUp className="mr-2 size-4" /> Upload
          </Button>
        </div>
      </div>

      {error ? (
        <ErrorState message={getApiErrorMessage(error)} onRetry={() => void refetch()} />
      ) : isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : data.items.length === 0 ? (
        <EmptyState icon={FileText} title="No documents yet" description="Upload a PDF, DOCX, TXT or MD file (up to 10 MB) and attach it to an article from the assistant." />
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Title</TableHead>
              <TableHead>Type</TableHead>
              <TableHead>Pages</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>Size</TableHead>
              <TableHead>Uploaded</TableHead>
              <TableHead className="w-24" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {data.items.map((doc) => (
              <TableRow key={doc.id}>
                <TableCell className="font-medium">{doc.title}</TableCell>
                <TableCell><Badge variant="outline">{documentKind(doc.contentType)}</Badge></TableCell>
                <TableCell>{doc.pageCount ?? '—'}</TableCell>
                <TableCell><DocumentStatusChip doc={doc} /></TableCell>
                <TableCell>{formatBytes(doc.sizeBytes)}</TableCell>
                <TableCell>{formatRelative(doc.createdAt)}</TableCell>
                <TableCell className="flex justify-end gap-1">
                  {doc.status === 'failed' && (
                    <Button variant="ghost" size="icon" aria-label="Retry" onClick={() => retry.mutate(doc.id)} disabled={retry.isPending}>
                      <RotateCcw className="size-4" />
                    </Button>
                  )}
                  <Button variant="ghost" size="icon" aria-label="Delete" onClick={() => setPendingDelete(doc)}>
                    <Trash2 className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      <ConfirmDialog
        open={pendingDelete !== null}
        onOpenChange={(open) => { if (!open) setPendingDelete(null); }}
        title="Delete this document?"
        description={<>“{pendingDelete?.title}” will be detached from every article and removed. This cannot be undone.</>}
        confirmLabel="Delete"
        isPending={remove.isPending}
        onConfirm={() => {
          if (!pendingDelete) return;
          remove.mutate(pendingDelete.id, {
            onSuccess: () => setPendingDelete(null),
            onError: (err) => toast.error(getApiErrorMessage(err, 'Could not delete the document')),
          });
        }}
      />
    </div>
  );
}
```
Check the props of `EmptyState`, `ErrorState` and `formatRelative` in their files and adjust to their real signatures.

- [ ] **Step 7: Page and nav** — `src/app/(main)/dashboard/documents/page.tsx`:

```tsx
import type { Metadata } from 'next';
import { DocumentsView } from '@/features/documents/documents-view';

// Private reference material. Never indexable.
export const metadata: Metadata = {
  title: 'Documents | Inkwell.ai',
  robots: { index: false, follow: false },
};

export default function DocumentsPage() {
  return <DocumentsView />;
}
```
In `nav-items.tsx` add to `WRITER_ITEMS` after "My articles": `{ label: 'Documents', href: ROUTES.dashboardDocuments, icon: FileStack, accountTypes: ['personal'] }` (import `FileStack` from lucide-react; if absent in the installed version use `Files`).

- [ ] **Step 8: Gates**: `docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"` and `docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"`. Open `http://frontend.inkwell.ai/dashboard/documents` in the signed-in Chrome tab (the controller's browser pass; the implementer reports the gates).

- [ ] **Step 9: Commit** on `feat/document-sources` (from `origin/main`): `git add -A src && git commit -m "feat: document library page — upload with progress, ingestion status, retry, delete"`

---

### Task 10: Frontend — Sources strip in the dock

**Files:**
- Create: `src/hooks/use-article-documents.ts`, `src/features/ai/ai-sources-strip.tsx`
- Modify: `src/features/ai/ai-assistant-dock.tsx`

**Interfaces:**
- Consumes: `useDocuments`, `DocumentRow`, `qk.articles.documents(id)`.

- [ ] **Step 1: `src/hooks/use-article-documents.ts`**:

```ts
'use client';

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from '@/lib/api/client';
import { qk } from '@/lib/api/query-keys';
import type { DocumentRow } from '@/features/documents/document-types';

/** The documents attached to one article — the Sources strip's list. */
export function useArticleDocuments(articleId: string | undefined) {
  return useQuery<DocumentRow[]>({
    queryKey: qk.articles.documents(articleId ?? ''),
    queryFn: async () => (await api.get<DocumentRow[]>(`/articles/${articleId}/documents`)).data,
    enabled: !!articleId,
  });
}

/** Replaces the attachment set; the response is the new list, written straight into the cache. */
export function useSetArticleDocuments(articleId: string | undefined) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (documentIds: string[]) =>
      (await api.put<DocumentRow[]>(`/articles/${articleId}/documents`, { documentIds })).data,
    onSuccess: (rows) => {
      if (articleId) queryClient.setQueryData(qk.articles.documents(articleId), rows);
    },
  });
}
```

- [ ] **Step 2: `src/features/ai/ai-sources-strip.tsx`**:

```tsx
'use client';

import { useState } from 'react';
import Link from 'next/link';
import { Check, Paperclip, Plus, X } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import { useDocuments } from '@/hooks/use-documents';
import { useArticleDocuments, useSetArticleDocuments } from '@/hooks/use-article-documents';
import { getApiErrorMessage } from '@/lib/api/error';
import { ROUTES } from '@/lib/constants';
import { cn } from '@/lib/utils';

/**
 * The Sources strip at the top of the dock: which documents this article's
 * assistant may read. Chips for the attached ones (× detaches), an Attach
 * button opening a picker over the library's READY documents, and a link to
 * upload more. Saves on every change — there is no "apply".
 *
 * Nothing renders without an article: attachments belong to an article, and
 * a brand-new draft has no id until the first save.
 */
export function AiSourcesStrip({ articleId }: { articleId?: string }) {
  const [open, setOpen] = useState(false);
  const attached = useArticleDocuments(articleId);
  const library = useDocuments(open);
  const setDocuments = useSetArticleDocuments(articleId);

  if (!articleId) return null;

  const attachedIds = new Set((attached.data ?? []).map((d) => d.id));

  const save = (ids: string[]) =>
    setDocuments.mutate(ids, {
      onError: (err) => toast.error(getApiErrorMessage(err, 'Could not update the sources')),
    });

  const toggle = (id: string) => {
    const next = new Set(attachedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    save([...next]);
  };

  return (
    <div className="mx-4 mt-3 rounded-lg border px-3 py-2 text-xs">
      <div className="flex flex-wrap items-center gap-1.5">
        <Paperclip className="size-3 text-muted-foreground" aria-hidden="true" />
        {attached.data?.length ? (
          attached.data.map((doc) => (
            <span
              key={doc.id}
              className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5"
              title={doc.status === 'ready' ? undefined : `${doc.status} — not used until ready`}
            >
              {doc.title}
              {doc.pageCount && doc.pageCount > 1 ? <span className="text-muted-foreground">· {doc.pageCount} p.</span> : null}
              {doc.status !== 'ready' && <span className="text-muted-foreground">({doc.status})</span>}
              <button type="button" aria-label={`Detach ${doc.title}`} onClick={() => toggle(doc.id)} className="hover:text-foreground">
                <X className="size-3" />
              </button>
            </span>
          ))
        ) : (
          <span className="text-muted-foreground">No sources attached — the assistant writes from your own published work.</span>
        )}

        <Popover open={open} onOpenChange={setOpen}>
          <PopoverTrigger asChild>
            <Button variant="ghost" size="sm" className="ml-auto h-6 px-2 text-xs">
              <Plus className="mr-1 size-3" /> Attach
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-72 p-2 text-sm">
            {library.isPending ? (
              <p className="px-2 py-1 text-muted-foreground">Loading…</p>
            ) : (
              <ul className="max-h-64 space-y-0.5 overflow-y-auto">
                {(library.data?.items ?? []).filter((d) => d.status === 'ready').map((doc) => {
                  const on = attachedIds.has(doc.id);
                  return (
                    <li key={doc.id}>
                      <button
                        type="button"
                        role="checkbox"
                        aria-checked={on}
                        onClick={() => toggle(doc.id)}
                        className={cn('flex w-full items-center gap-2 rounded px-2 py-1 text-left hover:bg-muted', on && 'font-medium')}
                      >
                        <span className={cn('flex size-4 items-center justify-center rounded border', on && 'bg-primary text-primary-foreground')}>
                          {on && <Check className="size-3" />}
                        </span>
                        <span className="truncate">{doc.title}</span>
                      </button>
                    </li>
                  );
                })}
                {library.data && library.data.items.every((d) => d.status !== 'ready') && (
                  <li className="px-2 py-1 text-muted-foreground">No ready documents yet.</li>
                )}
              </ul>
            )}
            <Link href={ROUTES.dashboardDocuments} target="_blank" className="mt-2 block px-2 py-1 text-xs text-primary hover:underline">
              Upload new…
            </Link>
          </PopoverContent>
        </Popover>
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Mount it** in `ai-assistant-dock.tsx` right after `<AiCorpusNotice className="mx-4 mt-3" />`: `<AiSourcesStrip articleId={articleId} />` (import it).

- [ ] **Step 4: Gates** (`tsc`, `eslint`), then commit: `git add -A src && git commit -m "feat: Sources strip — attach library documents to the article from the dock"`

---

### Task 11: Frontend — `documents` step and cited passages in the run card

**Files:**
- Create: `src/features/ai/document-citation.ts`, `src/features/ai/document-citation.check.ts`, `src/features/ai/ai-document-sources.tsx`
- Modify: `src/features/ai/assistant-run.ts`, `assistant-run.check.ts`, `ai-run-card.tsx`

- [ ] **Step 1: Failing check** `src/features/ai/document-citation.check.ts`:

```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/document-citation.check.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { citationLabel, documentFileUrl } from './document-citation.ts';

test('citation label names the page only for PDFs', () => {
  assert.equal(citationLabel('Field notes', 4, 'application/pdf'), '[Field notes, p. 4]');
  assert.equal(citationLabel('Memo', 1, 'text/plain'), '[Memo]');
});

test('file url appends #page=N for PDFs and nothing otherwise', () => {
  assert.equal(documentFileUrl('http://s/x?sig=1', 4, 'application/pdf'), 'http://s/x?sig=1#page=4');
  assert.equal(documentFileUrl('http://s/x?sig=1', 1, 'text/markdown'), 'http://s/x?sig=1');
});
```
Run → fails (module missing).

- [ ] **Step 2: `src/features/ai/document-citation.ts`**:

```ts
/**
 * Citation helpers, mirrored from `prompts/reference.prompt.ts` on the API so
 * the label the panel shows is the label the model was told to write.
 */
const PDF = 'application/pdf';

export function citationLabel(title: string, page: number, contentType: string): string {
  return contentType === PDF ? `[${title}, p. ${page}]` : `[${title}]`;
}

/** The presigned URL with the page fragment PDF viewers honour; other types have no pages. */
export function documentFileUrl(url: string, page: number, contentType: string): string {
  return contentType === PDF ? `${url}#page=${page}` : url;
}
```
Run the check → PASS.

- [ ] **Step 3: Run state** — in `assistant-run.ts`: `CHAT_STEPS = ['draft', 'profile', 'documents', 'thinking', 'retrieval', 'writing', 'done']`; `STEP_LABELS.documents = 'Reading your documents…'`; add

```ts
export interface DocumentPassageLite {
  chunkId: string;
  documentId: string;
  documentTitle: string;
  contentType: string;
  page: number;
  chunkIndex: number;
  content: string;
  similarity: number;
}
```
and `passages?: DocumentPassageLite[]` on both `StatusData` and `RunStep`; `applyStatus` copies it like `chunks`. In `assistant-run.check.ts` add a case: applying `{ step: 'documents', state: 'done', detail: '2 passages from 1 document', passages: [...] }` stores the passages, and `CHAT_STEPS.indexOf('documents') === CHAT_STEPS.indexOf('profile') + 1`. Run `node --test src/features/ai/assistant-run.check.ts` → PASS.

- [ ] **Step 4: `src/features/ai/ai-document-sources.tsx`**:

```tsx
'use client';

import { FileText } from 'lucide-react';
import { api } from '@/lib/api/client';
import { citationLabel, documentFileUrl } from './document-citation';
import type { DocumentPassageLite } from './assistant-run';

/**
 * The passages the turn drew from attached documents, each opening the file
 * at its page.
 *
 * The link resolves on click: a presigned URL expires in ten minutes, so an
 * `href` fetched when the row rendered could be dead by the time it is
 * clicked. The tab is opened synchronously (popup blockers allow a window
 * opened inside the click) and pointed at the URL once it arrives.
 */
export function AiDocumentSources({ passages }: { passages: DocumentPassageLite[] }) {
  if (passages.length === 0) return null;

  const openAt = (p: DocumentPassageLite) => {
    const tab = window.open('', '_blank');
    api
      .get<{ url: string }>(`/documents/${p.documentId}/file`)
      .then(({ data }) => {
        const href = documentFileUrl(data.url, p.page, p.contentType);
        if (tab) tab.location.href = href;
        else window.open(href, '_blank');
      })
      .catch(() => tab?.close());
  };

  return (
    <ul className="w-full space-y-2 border-l pl-3">
      {passages.map((p) => (
        <li key={p.chunkId} className="text-xs">
          <div className="flex items-baseline justify-between gap-2">
            <button type="button" onClick={() => openAt(p)} className="inline-flex items-center gap-1 font-medium text-foreground hover:underline">
              <FileText className="size-3" aria-hidden="true" />
              {citationLabel(p.documentTitle, p.page, p.contentType)}
            </button>
            <span className="shrink-0 tabular-nums text-muted-foreground">{Math.round(p.similarity * 100)}%</span>
          </div>
          <p className="mt-1 line-clamp-3 text-muted-foreground">{p.content}</p>
        </li>
      ))}
    </ul>
  );
}
```

- [ ] **Step 5: Run card** — in `ai-run-card.tsx`: `expandable` becomes true also for `step === 'documents' && s.state === 'done' && (s.passages?.length ?? 0) > 0`; keep one `sourcesOpen` state per row by changing it to `const [openStep, setOpenStep] = useState<ChatStep | null>(null)` and toggling `openStep === step`; render `<AiDocumentSources passages={s.passages} />` for `documents` and `<AiSources chunks={s.chunks} />` for `retrieval`.

- [ ] **Step 6: Gates** (`tsc`, `eslint`, both `.check.ts` files) and commit: `git add -A src && git commit -m "feat: Reading your documents row with cited passages that open the file at the page"`

---

### Task 12: Spec repo

**Files (in `spec.inkwell.ai`, branch `docs/document-sources` from `origin/main`):** `5-ai-design.md`, `2-features.md`, `6-database-schema.md`, `3-user-flows.md`, `4-system-architecture.md`, `10-requirements.md`.

- [ ] **Step 1: `5-ai-design.md`** — after §9.4 (before `## 10.`) add `### 9.5 Document sources (2026-09-17)`: the second corpus (reference material vs voice), the three tables, ingestion steps with the caps (20 / 10 MB / 200 pages / 50-char text floor) and the three failure sentences, retrieval scoping (owner, attached, ready, live; top-K 5; floor 0.60 with the Task 0 measurement written in), the prompt block quoted verbatim, the `documents` step placed between `profile` and `thinking` "because a question about the material needs it as much as a write does", citations `[Title, p. N]` / `[Title]` for DOCX/text, the cost line (≤ 5 passages ≈ 1,500 prompt tokens billed in the turn), and what documents never feed (memory, Portfolio Insights, search). Update the provider table in §13.5 if it lists per-feature models (embeddings unchanged).

- [ ] **Step 2: `2-features.md`** — new `### 3.7 Document Sources *(2026-09-17)*` after §3.6: the library page, upload, statuses, Sources strip, citations, caps, out of scope (OCR, URL import, sharing, style toggle, images, versioning, editable titles).

- [ ] **Step 3: `6-database-schema.md`** — after §5.4 add `### 5.5 Documents`, `### 5.6 Document Chunks`, `### 5.7 Article Documents` in the same code-block column style as §5.1, with the indexes, cascades, and the lifecycle (pending → extracting → ready | failed; soft delete then purge; chunks only for `ready`). Add the three tables to §9 Relationships Summary and the `document_status` enum where enums are listed.

- [ ] **Step 4: `3-user-flows.md`** — after §6 add `## 6.5 📎 Document Sources Flow *(2026-09-17)*`: upload → Extracting → Ready; attach in the dock; ask/write → "Reading your documents — N passages from M documents" → cited answer/text; click a passage → file at page; delete → gone from strip and retrieval.

- [ ] **Step 5: `4-system-architecture.md`** — in Key Pipelines add "Document Ingestion: presigned PUT to the private `documents` bucket → `ingest-document` job on the `documents` queue → extract (pdf-parse / mammoth) → `chunkText` with pages → Gemini `RETRIEVAL_DOCUMENT` → `document_chunks`"; extend "RAG Retrieval" with the second corpus; in §8 Queue Layer list the `documents` queue and the `purge-document` job; in §11 Media Storage add the private bucket and the presigned-GET-only access.

- [ ] **Step 6: `10-requirements.md`** — append after FR-83:

```
| FR-84 | Upload PDF, DOCX, TXT or MD reference documents (≤ 10 MB, ≤ 200 pages, 20 per writer) into a private library, with text extracted and embedded by the worker and a readable failure reason when it cannot be | Must | 9 |
| FR-85 | Attach library documents to an article from the assistant and detach them; attachments are saved immediately | Must | 9 |
| FR-86 | The assistant draws on attached documents for both answers and writes, cites passages inline as [Title, p. N], and shows the passages used with a link opening the file at the page | Must | 9 |
| FR-87 | A document is the writer's alone: it never feeds writer memory, Portfolio Insights or search, and another account cannot read, attach or discover it | Must | 9 |
```
and after US-69:
```
| US-70 | Upload the documents I am working from so that the assistant can use their facts without my retyping them | A4 | Must | 8 | 9 |
| US-71 | Choose which documents apply to an article so that a piece on tides is not fed my notes on fermentation | A4 | Must | 3 | 9 |
| US-72 | See which document and page a claim came from so that I can check it before it goes out under my name | A4 | Should | 5 | 9 |
```
Adjust the sprint column to whatever sprint number the rows above use for this work (the voice rows say 8; if this is a new sprint, use the next number consistently across all rows).

- [ ] **Step 7: Commit**: `git add . && git commit -m "docs: document sources — tables, ingestion pipeline, retrieval, citations, FR-84..87 / US-70..72"`

---

### Task 13: Browser pass (controller, via the Chrome extension) and superproject bump

- [ ] **Step 1:** In the signed-in tab, open `/dashboard/documents`; upload `two-pages.pdf` from `src/backend.inkwell.ai/test/documents/fixtures/` via the file input (`mcp__claude-in-chrome__file_upload`); watch Extracting… → Ready with **2** pages. Upload a `.png` → refused client-side with the copy.
- [ ] **Step 2:** Open an existing article in the editor, open the dock: empty-state sentence shows; Attach → the PDF listed → attach → chip with `· 2 p.`; reload → chip persists (`GET /articles/:id/documents`).
- [ ] **Step 3:** Ask "When is the best time to surfcast according to my document?" → run card shows `Reading your documents — N passages from 1 document` between the profile and thinking rows; answer contains `[two-pages, p. 1]` or `p. 2`; expand the row → passage → click → new tab opens the PDF at `#page=N`. Send a SECOND turn (the strict-DTO regression from memory) → 200.
- [ ] **Step 4:** Ask it to write a paragraph about tackle → writing draws on page 2 ("twelve-foot rod") and cites it. Keep.
- [ ] **Step 5:** Detach → chip gone; ask again → no `documents` row. Delete the document from the library → confirm dialog → row gone; `SELECT COUNT(*) FROM documents` → 0 after the purge; `SELECT COUNT(*) FROM document_chunks` → 0.
- [ ] **Step 6:** Clean up: delete probe `ai_interactions` rows, restore the token balance, remove any test article text written during the pass.
- [ ] **Step 7:** Open PRs in order backend → frontend → spec; after the user says merge, one superproject commit `chore: bump submodules for document sources` moving all three pointers (branch `chore/bump-document-sources`).

---

## Self-review

**Spec coverage.** §4 tables/bucket/presign/download → Tasks 1, 4, 6. §5 register/cap/queue/processor/extraction/failure copy/retry/delete+purge → Tasks 3, 5, 6. §6 retrieval scoping/when/prompt block/citations/status step/cost → Tasks 7, 8, 11. §7 library page/upload/polling/"N of 20"/Waiting…/Sources strip/empty state/immediate save/GET list → Tasks 9, 10. §8 edge cases: 21st → Task 6 spec; >10 MB client + server → Tasks 9, 6; scanned → Task 5; >200 pages → Task 5; deleted-while-attached → soft-delete filter (Task 7) + cascade (Task 1) + strip invalidation (Task 9's delete hook); not-ready skipped → `attachedReadyDocumentIds` (Task 6) + chip status (Task 10); 404 → Task 6; no dedup → nothing to build; worker down → Task 9 chip. §9 verification → the specs in Tasks 2, 3, 5, 6, 7, 8 and the checks in Task 11; spike → Task 0; browser → Task 13. §11 repos → Tasks 1–8 (backend), 9–11 (frontend), 12 (spec).

**Deviations from the spec, stated.** `POST /documents` takes no `contentType` (spec §5 already makes the extension authoritative, and the strict DTO would otherwise need a field the server ignores). Storage is a `DocumentStorageService` sharing a `createMinioClient` factory rather than a bucket parameter on `UploadsService` — same reuse, and the worker can list it without the image upload code. Both go in the ledger as rulings if the reviewer asks.

**Placeholders.** None: every step has its code or its exact command. The two "check the real signature" notes (Badge variants, EmptyState/ErrorState/formatRelative props) name the file to read.

**Type consistency.** `DocumentPage`/`TextChunk` (Task 2) → extractor (3) → ingestion (5). `RetrievedDocumentChunk` (7) → chat-status/withStatus/reference prompt (8) → `DocumentPassageLite` mirror (11), same nine fields. `DocumentRow` (6) → `document-types.ts` (9) → hooks (9, 10). `attachedReadyDocumentIds(articleId, ownerId)` (6) called with that argument order in 8. `citationLabel(title, page, contentType)` identical on both sides.
