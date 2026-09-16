# Document sources — design

*2026-09-16. Approved in conversation, section by section; this is the written
form. Builds on the floating assistant (`2026-09-13`) and its retrieval; the
voice feature (`2026-09-14`) is untouched.*

## 1. The request, in the user's words

> the import of documents — if a user wants to create articles and wants the AI
> to inspire from documents, he will upload PDFs or something like that.

## 2. What the existing RAG is, and why this is a second corpus

Today's retrieval is a **"write like me"** system: the only corpus is the
writer's own published articles, chunked at publish time, embedded with Gemini
`gemini-embedding-001` (1536 dims), searched with pgvector cosine distance
(top-K 5, floor 0.60) and injected into the *write* prompt as a voice block —
"absorb the style, don't answer about it". Drafts are never embedded; nothing
external, nothing uploaded, nothing cross-writer.

An uploaded document is **reference material** — facts and structure to draw
on — not voice. It therefore gets its own tables, its own prompt block with
the opposite instruction, and its own step in the panel, while reusing the
chunker, the embedder and the query pattern.

## 3. Decisions

| Question | Decision |
|---|---|
| What does a document belong to? | **The writer's library, attached per article.** Upload once; pick per article. |
| Formats | **PDF, DOCX, TXT/MD.** Text extracted once in the worker; scanned PDFs refused (no OCR). |
| How the assistant uses it | **Both writes and questions**, in a separate labelled "Reference material" block, **with inline citations** `[Title, p. N]` and an expandable "Reading your documents" row. |
| Cost and caps | **Free to upload** (embeddings are Gemini's free tier); **20 documents, 10 MB and 200 pages each**; the retrieved passages are prompt tokens billed in the turn like the voice passages. |
| UI | **`/dashboard/documents`** library page; **Sources strip** at the top of the assistant dock to attach/detach per article. |
| Ingestion path | **Approach 1**: presigned PUT to a private bucket, ingestion as a worker job. |

Assumptions stated rather than asked:

- A document's title is its filename without extension; not editable.
- No deduplication across writers or across uploads.
- Documents never feed writer memory, Portfolio Insights or search — they are
  the writer's material, not the writer's work.
- The 0.60 similarity floor is the starting point; the plan's spike measures
  it on a real document and adjusts if this corpus sits elsewhere.

## 4. Data model and storage

**`documents`**

| Column | Notes |
|---|---|
| `id` uuid pk | |
| `owner_id` → users | every read, attach, retrieve, delete filters on it |
| `title` text | filename without extension |
| `filename` text | as uploaded |
| `content_type` text | `application/pdf` · `application/vnd.openxmlformats-officedocument.wordprocessingml.document` · `text/plain` · `text/markdown` |
| `size_bytes` int | ≤ 10 MB |
| `storage_key` text | object key in the `documents` bucket |
| `status` enum `document_status` | `pending` → `extracting` → `ready` \| `failed` |
| `page_count` int null | set on ready; 1 for TXT/MD and DOCX (see §5) |
| `chunk_count` int null | set on ready |
| `error` text null | the writer-readable reason when failed |
| `created_at`, `deleted_at` | soft delete like articles; chunks cascade on the hard delete the purge job performs |

**`document_chunks`** — `id`, `document_id` → documents (cascade), `chunk_index`,
`page` int (the page the chunk starts on; 1 for text files and DOCX),
`content`, `embedding vector(1536)`; unique `(document_id, chunk_index)`;
index on `document_id`. Same shape as `article_chunks` so the pgvector query
pattern is reused verbatim.

**`article_documents`** — `article_id` → articles (cascade), `document_id` →
documents (cascade), `created_at`; primary key on the pair. "Attached to this
article."

**Storage.** A second MinIO bucket, `documents`, created at boot like the
images bucket but **without** the anonymous-read policy. Upload: `POST
/documents/presign` (extends `UploadsService` with a bucket parameter and the
document content-type whitelist) → the browser PUTs. Download: `GET
/documents/:id/file` returns a presigned GET valid 10 minutes, owner-only —
never a public URL.

## 5. Ingestion

`POST /documents` `{ storageKey, filename, contentType, sizeBytes }` validates
type (derived from the filename extension — `.pdf`, `.docx`, `.txt`, `.md` —
not the browser's content type, which is empty for `.md` on some systems), size (≤ 10 MB) and count (fewer than 20 live documents, else `409`
"You already have 20 documents"), inserts `pending`, and enqueues
`ingest-document { documentId }` on a new BullMQ queue `documents` — its own
queue so a slow PDF never delays article embedding.

`IngestDocumentProcessor` (worker):

1. `status = extracting`.
2. Read the object from MinIO (≤ 10 MB by construction).
3. Extract by type: **PDF** → `pdf-parse`, per page; total text under 50
   characters → `failed`, "This PDF has no text layer — export it with
   selectable text". **DOCX** → `mammoth` paragraphs; `page` = 1 throughout
   (DOCX has no fixed pages; citations read `[Title]`). **TXT/MD** → UTF-8.
   More than 200 pages → `failed`, "Documents are limited to 200 pages".
4. Chunk with the existing rules (120–1,200 characters, thin blocks merged
   forward) through a new `chunkText(pages: { page, text }[])` that shares the
   splitter with `chunkArticle` and keeps the page on each chunk.
5. Embed in batches (`RETRIEVAL_DOCUMENT`), insert the chunks in one
   transaction, set `ready`, `page_count`, `chunk_count`.
6. Any throw → `failed` with a writer-readable sentence (provider failure:
   "Couldn't process this document — try again"), chunks rolled back.
   `POST /documents/:id/retry` re-enqueues a failed document.

`DELETE /documents/:id` soft-deletes (retrieval stops at once) and enqueues
`purge-document`, which removes the object and hard-deletes the row (cascading
chunks and attachments).

## 6. Retrieval, prompt, citations

- `RetrievalService.findSimilarDocumentChunks(query, { ownerId, documentIds,
  topK = 5, minSimilarity = 0.60 })` — `query` is the writer's message text,
  embedded as `RETRIEVAL_QUERY` like the voice lookup; the same `<=>` query over
  `document_chunks` joined to `documents` with `owner_id = caller`,
  `deleted_at IS NULL`, `status = 'ready'`, `id IN attached`.
- **When:** in the assistant turn, if the article has attached documents,
  retrieval runs before the routing call, for **both** questions and writes
  (the outer prompt gets the block for questions; the inner prompt for
  writes). Voice passages stay write-only.
- **Prompt block**, distinct from the voice block:

  > Reference material the writer attached. Use it for facts and structure;
  > do not imitate its style. When you use a passage, cite it inline as
  > [Title, p. N].

  Each passage is prefixed `[Title, p. N]` (or `[Title]` for DOCX/text).
- **Citations:** the model's inline `[Title, p. N]` stays in the text. The run
  card gains a row **"Reading your documents — N passages from M documents"**
  (status step `documents`, inserted between `profile` and `thinking` in
  `CHAT_STEPS` on both sides), expandable to the passages used. Each passage is a
  link that calls `GET /documents/:id/file` on click and opens the returned
  presigned URL with `#page=N` appended in a new tab (a plain `href` cannot
  carry a URL that expires in 10 minutes).
- **Cost:** ≤ 5 passages ≈ 1,500 prompt tokens, billed in the turn as today.
- Attached documents still `extracting` are skipped for that turn.

## 7. UI

**`/dashboard/documents`** — list: title, type badge, pages, status chip
(Extracting… · Ready · Failed with the reason and a Retry), size, uploaded
date, delete with confirm. **Upload**: file picker (PDF/DOCX/TXT/MD, 10 MB,
checked client-side) → presign → PUT with progress → register → the row
appears as Extracting and polls every 3 s until ready or failed. Header shows
"N of 20". A row in `pending` for over 60 s reads "Waiting…" (worker down;
nothing lost).

**In the dock**, above the conversation: a **Sources** strip — chips for
attached documents (title, page count, × to detach) and an **Attach** button
opening a picker of the library's ready documents (checkboxes) with an
"Upload new…" link to the library page. Empty state: "No sources attached —
the assistant writes from your own published work." Attachments save at once:
`PUT /articles/:id/documents { documentIds }` (owner of both required);
`GET /articles/:id/documents` lists them when the dock opens.

## 8. Errors and edge cases

| Case | Behaviour |
|---|---|
| 21st document | `409`; library shows "20 of 20 — delete one to upload another" |
| Over 10 MB | refused client-side before presign; server `413` as backstop |
| Scanned / empty PDF | `failed`, no-text-layer sentence; Retry offered (the row says why it will fail again) |
| Over 200 pages | `failed`, page-limit sentence |
| Document deleted while attached | excluded from retrieval from the soft delete on; the attachment row cascades away on purge; the chip disappears on the next attachment fetch |
| Attached document not `ready` at send | skipped for the turn; the chip shows its status |
| Owner mismatch on any route | `404`, never `403` |
| Same file uploaded twice | two documents; no dedup |
| Worker down | rows stay `pending`; "Waiting…" after 60 s |

## 9. Verification

- **Backend jest (real test DB):** `chunkText` page tracking; the ingestion
  processor with injected extractor and embedder fakes (status transitions,
  scan detection, page cap, failure rollback, retry); `findSimilarDocumentChunks`
  scoping (owner, attached, ready, soft-deleted) asserted against
  independently written SQL; the 20-document cap; the attach route refusing a
  document the caller does not own (`404`).
- **Frontend `node --test`:** the citation link builder.
- **Browser:** upload a real PDF → Extracting → Ready with pages; attach in
  the dock; a question cites `[Title, p. N]` and the row expands with links;
  a write draws on the material; detach; delete → gone from strip and
  retrieval.
- **Spike first:** extract one real PDF and one DOCX in the worker container
  with `pdf-parse` and `mammoth`; embed the chunks and measure on-topic vs
  off-topic similarity to confirm or move the 0.60 floor.

## 10. Out of scope

OCR; import by URL; sharing documents between writers; a per-document
style-vs-facts toggle; images inside PDFs; versioning a re-uploaded file;
editable titles.

## 11. Repos touched

backend (schema + migration: `documents`, `document_chunks`,
`article_documents`, enum `document_status`; `documents/` module: controller,
service, DTOs; worker processor + queue contract; `chunkText`;
`RetrievalService.findSimilarDocumentChunks`; prompt block; `CHAT_STEPS` +
status emission in the assistant turn; `UploadsService` bucket parameter;
bucket bootstrap) · frontend (`/dashboard/documents` page and hooks; Sources
strip + picker in the dock; `documents` step in `assistant-run.ts` and the
run card; citation links) · spec (`5-ai-design.md` new §9.5 "Document
sources" after the RAG layer, `2-features.md` new §3.7, `6-database-schema.md`
three tables, `3-user-flows.md` a new flow, `10-requirements.md` FR-84+ /
US-70+, `4-system-architecture.md` ingestion pipeline).
