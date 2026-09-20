# Assistant Side Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating assistant card with a docked, tabbed panel beside the editor — Chat and Sources tabs, a composer card, a 48 px rail when collapsed — and the same panel in a bottom sheet below desktop width.

**Architecture:** Pure re-homing of JSX. The dock's hooks and wiring move unchanged into a container (`AiAssistantHost`) that decides *where* the panel renders (column + rail on `lg+`, `Sheet` + pill below); a position-agnostic `AiAssistantPanel` owns the header, tabs and the two tab bodies; the composer and the Sources tab become their own components; the editor page becomes a two-column flex. No backend, hook, or API change.

**Tech Stack:** Next.js 16 / React 19 (React-compiler lint rules), shadcn on base-ui (`Tabs`, `Sheet`, `Textarea`, `Tooltip`), TanStack Query v5, Tailwind v4, `node --test` for the one pure helper.

**Spec:** `docs/superpowers/specs/2026-09-20-assistant-side-panel-design.md` (superproject `docker.inkwell.ai`). Read it first; it is the authority.

## Global Constraints

- **Nothing runs on the host.** Frontend gates: `docker exec -w /app inkwell-web-1 npx tsc --noEmit; echo "exit: $?"` and `docker exec -w /app inkwell-web-1 npx eslint . --max-warnings=0; echo "exit: $?"`; pure checks `docker exec -w /app inkwell-web-1 node --test <file>.check.ts`. Both gates must exit 0 before every commit.
- **React-compiler rules:** no impure reads (`Date.now`, `localStorage`) during render except in a `useState` lazy initializer; no `setState` synchronously inside an effect body; hooks before any early return; never mutate props/state.
- **Behaviour is unchanged.** Every hook (`useAiAssistant`, `useSpeechOut`, `useVoiceInput`, `useAiQuota`, `useAiTokens`, `useArticleDocuments`, `useSetArticleDocuments`, `useDocuments`, `useUploadDocument`), `assistant-run.ts`, `ai-run-card.tsx`, `article-writer.ts`, `ai-write-range.ts`, `ai-keep-discard-bar.tsx`, `voice-recorder-control.tsx` are **not modified**. The dock's guards move verbatim: Escape refused while recording; collapse allowed while a write awaits Keep/Discard; the input disabled while streaming / exhausted / a write is open; the mic additionally disabled below `VOICE_TOKENS_PER_MINUTE`; Enter submits only when not recording; the Keep/Discard bar renders regardless of panel state.
- **Layout numbers, verbatim:** panel column **400 px** (`w-[400px]`), rail **48 px** (`w-12`), `lg` (1024 px) is the only breakpoint; sheet `side="bottom"`, height **85 vh**; textarea grows **1 → 4 lines** then scrolls; Enter sends, Shift+Enter newline.
- **Copy, verbatim:** empty state `Ask anything about your article, or tell me what to write — I draw on your {N} published articles and {M} attached sources.`; footer `Drawing on {N} articles · {M} sources`; no-corpus sentence `Publish an article and I'll start drawing on your own writing when I answer.`; no-article Sources tab `Save the article once to attach sources`; Sources groups `Attached to this article` / `Your library`; link `Manage in library →`; error lines `Couldn't load sources` (+ Retry) and `Couldn't load your documents`; tab labels `Chat` / `Sources`.
- **Persistence:** `localStorage` key `inkwell.ai-panel.state` with values `expanded` | `rail`; on first read, if it is absent and the old `inkwell.ai-dock.minimized` is `'1'`, start as `rail` (migration), then never read the old key again.
- **Every function, logic block and non-obvious line gets a comment** matching the surrounding density (the dock is heavily commented — keep its comments when moving code).
- **No AI attribution anywhere** — commits, PRs, comments. Commit messages in the user's voice.
- **Branches:** frontend `feat/assistant-side-panel` from `origin/main` (`95c7cf2`); spec `docs/assistant-side-panel` from `origin/main` (`38b8940`). Do not merge or push unless the user says so.

---

## File map

| File | Role |
|---|---|
| `src/features/ai/ai-corpus-line.ts` (new) + `.check.ts` | `corpusLine(...)` → the empty-state sentence and the footer line |
| `src/features/ai/ai-composer.tsx` (new) | Composer card: textarea + action bar |
| `src/features/ai/ai-sources-tab.tsx` (new) | Sources tab body (attached list, library, upload) |
| `src/features/ai/ai-assistant-panel.tsx` (new) | Header, tabs, Chat tab body; owns `tab` state |
| `src/features/ai/ai-assistant-rail.tsx` (new) | The 48 px rail |
| `src/features/ai/use-panel-state.ts` (new) | Persisted `expanded` \| `rail` + migration |
| `src/features/ai/ai-assistant-host.tsx` (renamed from `ai-assistant-dock.tsx`) | Container: hooks, guards, breakpoint, column/rail vs sheet/pill |
| `src/features/editor/editor-shell.tsx` | Two-column flex; toolbar button toggles |
| `src/hooks/use-media-query.ts` (new) | `useIsDesktop()` on `(min-width: 1024px)` |
| deleted: `ai-sources-strip.tsx`, `ai-corpus-notice.tsx` | |
| spec: `2-features.md` §3.1, `3-user-flows.md` §5, `10-requirements.md` FR-81 | |

---

### Task 1: `corpusLine` — the pure text helper

**Files:**
- Create: `src/features/ai/ai-corpus-line.ts`, `src/features/ai/ai-corpus-line.check.ts`

**Interfaces:**
- Produces: `corpusLine(input: { articles: number; sources: number }): { empty: string; footer: string }` and `NO_CORPUS_SENTENCE`. Tasks 4 and 5 consume them.

- [ ] **Step 1: Write the failing check** `src/features/ai/ai-corpus-line.check.ts`:

```ts
// Run: docker exec -w /app inkwell-web-1 node --test src/features/ai/ai-corpus-line.check.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { corpusLine, NO_CORPUS_SENTENCE } from './ai-corpus-line.ts';

test('empty state names both counts with plurals', () => {
  assert.equal(
    corpusLine({ articles: 12, sources: 2 }).empty,
    'Ask anything about your article, or tell me what to write — I draw on your 12 published articles and 2 attached sources.',
  );
  assert.equal(
    corpusLine({ articles: 1, sources: 1 }).empty,
    'Ask anything about your article, or tell me what to write — I draw on your 1 published article and 1 attached source.',
  );
});

test('footer is the short form', () => {
  assert.equal(corpusLine({ articles: 12, sources: 2 }).footer, 'Drawing on 12 articles · 2 sources');
  assert.equal(corpusLine({ articles: 3, sources: 0 }).footer, 'Drawing on 3 articles · no sources');
});

test('no published articles falls back to the publish-first sentence', () => {
  const line = corpusLine({ articles: 0, sources: 2 });
  assert.equal(line.empty, NO_CORPUS_SENTENCE);
  assert.equal(line.footer, 'Drawing on 2 sources');
  assert.equal(corpusLine({ articles: 0, sources: 0 }).footer, '');
});
```

- [ ] **Step 2: Run it** → fails, module not found.

- [ ] **Step 3: Implement** `src/features/ai/ai-corpus-line.ts`:

```ts
/**
 * The one sentence that tells the writer what the assistant draws on.
 *
 * Replaces the permanent corpus band the dock carried: the same numbers now
 * appear once in the empty state and, once a conversation exists, as a
 * muted footer above the composer. Pure so it can be checked with node --test.
 */

/** Shown when the writer has published nothing yet — the corpus is empty. */
export const NO_CORPUS_SENTENCE =
  "Publish an article and I'll start drawing on your own writing when I answer.";

/** "1 article" / "12 articles" — the plural rule used by both lines. */
function count(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? '' : 's'}`;
}

export function corpusLine({ articles, sources }: { articles: number; sources: number }): {
  empty: string;
  footer: string;
} {
  // Footer: the short form, or nothing at all when there is nothing to say.
  const parts: string[] = [];
  if (articles > 0) parts.push(count(articles, 'article'));
  if (sources > 0) parts.push(count(sources, 'source'));
  else if (articles > 0) parts.push('no sources');
  const footer = parts.length ? `Drawing on ${parts.join(' · ')}` : '';

  // Empty state: the invitation plus the numbers, unless the corpus is empty,
  // in which case the useful thing to say is what would change that.
  const empty =
    articles === 0
      ? NO_CORPUS_SENTENCE
      : `Ask anything about your article, or tell me what to write — I draw on your ${count(articles, 'published article')} and ${count(sources, 'attached source')}.`;

  return { empty, footer };
}
```

- [ ] **Step 4: Run the check** → 3/3 pass. Then `tsc --noEmit` and `eslint` exit 0.

- [ ] **Step 5: Commit**: `git checkout -b feat/assistant-side-panel origin/main` (first task only), then `git add src/features/ai/ai-corpus-line.ts src/features/ai/ai-corpus-line.check.ts && git commit -m "feat: corpus line helper for the assistant's empty state and footer"`

---

### Task 2: Panel state and the desktop breakpoint hooks

**Files:**
- Create: `src/hooks/use-media-query.ts`, `src/features/ai/use-panel-state.ts`

**Interfaces:**
- Produces: `useIsDesktop(): boolean` (false during SSR and the first client render, then `matchMedia('(min-width: 1024px)')`); `usePanelState(): { state: PanelState; setState: (s: PanelState) => void }` with `type PanelState = 'expanded' | 'rail'`. Task 6 consumes both.

- [ ] **Step 1: `src/hooks/use-media-query.ts`**:

```ts
'use client';

import { useSyncExternalStore } from 'react';

/** The app sidebar's breakpoint (Tailwind `lg`). The panel is a column only when the sidebar is. */
const DESKTOP_QUERY = '(min-width: 1024px)';

/**
 * Subscribes to a media query with `useSyncExternalStore`, which is the
 * React 19 way to read browser state without an effect + setState pair.
 * The server snapshot is `false`, so SSR and the first client render agree
 * (no hydration mismatch) and the desktop layout appears on the first
 * client re-render after mount.
 */
function subscribe(callback: () => void): () => void {
  const mql = window.matchMedia(DESKTOP_QUERY);
  mql.addEventListener('change', callback);
  return () => mql.removeEventListener('change', callback);
}

export function useIsDesktop(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => window.matchMedia(DESKTOP_QUERY).matches,
    () => false,
  );
}
```

- [ ] **Step 2: `src/features/ai/use-panel-state.ts`**:

```ts
'use client';

import { useState } from 'react';

export type PanelState = 'expanded' | 'rail';

const KEY = 'inkwell.ai-panel.state';
/** The floating dock's key — read once so a writer who had it minimized starts on the rail. */
const LEGACY_KEY = 'inkwell.ai-dock.minimized';

/** Reads the persisted state during the lazy initializer — never during render proper. */
function readInitial(): PanelState {
  if (typeof window === 'undefined') return 'expanded';
  try {
    const stored = localStorage.getItem(KEY);
    if (stored === 'expanded' || stored === 'rail') return stored;
    // One-time migration from the dock: minimized → rail. The old key is
    // then left alone; nothing writes it any more.
    return localStorage.getItem(LEGACY_KEY) === '1' ? 'rail' : 'expanded';
  } catch {
    // Private mode etc. — default expanded.
    return 'expanded';
  }
}

/**
 * Expanded column or 48 px rail, remembered per browser (not per article —
 * a writer who collapsed it wants it collapsed on the next article too).
 */
export function usePanelState(): { state: PanelState; setState: (s: PanelState) => void } {
  const [state, set] = useState<PanelState>(readInitial);
  const setState = (next: PanelState) => {
    set(next);
    try {
      localStorage.setItem(KEY, next);
    } catch {
      /* ignore */
    }
  };
  return { state, setState };
}
```

- [ ] **Step 3: Gates** (`tsc`, `eslint`) exit 0. Note: `useSyncExternalStore`'s `getSnapshot` reads `window` only on the client, which is what the server snapshot argument guarantees.

- [ ] **Step 4: Commit**: `git add src/hooks/use-media-query.ts src/features/ai/use-panel-state.ts && git commit -m "feat: desktop breakpoint and persisted panel state hooks"`

---

### Task 3: `AiComposer` — the composer card

**Files:**
- Create: `src/features/ai/ai-composer.tsx`

**Interfaces:**
- Consumes: `VoiceRecorderControl` (props `disabled`, `disabledReason`, `onTranscript`, `onStateChange`), `Textarea`, `Button`.
- Produces:

```ts
export interface AiComposerProps {
  value: string;
  onChange: (value: string) => void;
  /** Called on Enter or the Send button; the host decides whether it may send. */
  onSubmit: () => void;
  onStop: () => void;
  streaming: boolean;
  /** Streaming / exhausted / a write awaiting Keep/Discard — the dock's rule. */
  disabled: boolean;
  placeholder: string;
  recording: boolean;
  /** Mic gate — the input rule plus the one-minute token floor. */
  canRecord: boolean;
  recordReason: string;
  onRecordingChange: (recording: boolean) => void;
  onTranscript: (text: string) => void;
  attachedCount: number;
  onOpenSources: () => void;
  /** The textarea, so the host can focus it and place the caret after a transcript. */
  textareaRef: React.RefObject<HTMLTextAreaElement | null>;
}
```
Task 6 passes these from the host.

- [ ] **Step 1: Implement** `src/features/ai/ai-composer.tsx`:

```tsx
'use client';

import { Paperclip, Send, Square } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { VoiceRecorderControl } from './voice-recorder-control';

/** Lines the textarea grows to before it scrolls. */
const MAX_ROWS = 4;

export interface AiComposerProps {
  value: string;
  onChange: (value: string) => void;
  /** Called on Enter or the Send button; the host decides whether it may send. */
  onSubmit: () => void;
  onStop: () => void;
  streaming: boolean;
  /** Streaming / exhausted / a write awaiting Keep/Discard — the dock's rule. */
  disabled: boolean;
  placeholder: string;
  recording: boolean;
  /** Mic gate — the input rule plus the one-minute token floor. */
  canRecord: boolean;
  recordReason: string;
  onRecordingChange: (recording: boolean) => void;
  onTranscript: (text: string) => void;
  attachedCount: number;
  onOpenSources: () => void;
  /** The textarea, so the host can focus it and place the caret after a transcript. */
  textareaRef: React.RefObject<HTMLTextAreaElement | null>;
}

/**
 * The composer card: a textarea that grows to four lines, and an action bar
 * beneath it. The bar has three fixed slots — mic (left), sources chip
 * (middle), Send/Stop (right) — so the recording state only ever changes
 * the left slot; Send never moves under the writer's cursor, which is what
 * the single-row input could not promise.
 */
export function AiComposer({
  value,
  onChange,
  onSubmit,
  onStop,
  streaming,
  disabled,
  placeholder,
  recording,
  canRecord,
  recordReason,
  onRecordingChange,
  onTranscript,
  attachedCount,
  onOpenSources,
  textareaRef,
}: AiComposerProps) {
  // Grow with the content up to MAX_ROWS, then scroll. Done on each change
  // rather than in a layout effect: the browser has the new value here.
  const resize = (el: HTMLTextAreaElement) => {
    el.style.height = 'auto';
    const line = parseFloat(getComputedStyle(el).lineHeight) || 20;
    const max = line * MAX_ROWS + (el.offsetHeight - el.clientHeight);
    el.style.height = `${Math.min(el.scrollHeight, max)}px`;
  };

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit();
      }}
      className="border-t px-3 py-3"
    >
      <div className="rounded-lg border bg-background focus-within:ring-1 focus-within:ring-ring">
        <Textarea
          ref={textareaRef}
          value={value}
          rows={1}
          onChange={(e) => {
            onChange(e.target.value);
            resize(e.target);
          }}
          onKeyDown={(e) => {
            // Enter sends; Shift+Enter is a newline. Composition (IME) Enter
            // is ignored so a CJK writer's candidate confirmation never sends.
            if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              onSubmit();
            }
          }}
          placeholder={recording ? 'Listening… speak your prompt' : placeholder}
          disabled={disabled}
          readOnly={recording}
          className="max-h-none min-h-0 resize-none border-0 shadow-none focus-visible:ring-0"
        />
        <div className="flex items-center gap-2 px-2 pb-2">
          {/* Left slot: the recorder owns its own idle / recording / transcribing states. */}
          <VoiceRecorderControl
            disabled={!canRecord}
            disabledReason={recordReason}
            onStateChange={onRecordingChange}
            onTranscript={onTranscript}
          />
          {/* Middle: how many sources this article reads; a shortcut to the tab. */}
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-7 px-2 text-xs text-muted-foreground"
            aria-label={`${attachedCount} attached ${attachedCount === 1 ? 'source' : 'sources'} — open Sources`}
            onClick={onOpenSources}
          >
            <Paperclip className="mr-1 size-3.5" aria-hidden="true" />
            {attachedCount}
          </Button>
          <div className="ml-auto">
            {/* Right slot: Send, or Stop while streaming. Disabled — never
                hidden — while recording, so the bar keeps its shape. */}
            {streaming ? (
              <Button type="button" size="icon" variant="outline" aria-label="Stop" onClick={onStop}>
                <Square className="h-4 w-4" />
              </Button>
            ) : (
              <Button type="submit" size="icon" aria-label="Send message" disabled={disabled || recording || !value.trim()}>
                <Send className="h-4 w-4" />
              </Button>
            )}
          </div>
        </div>
      </div>
    </form>
  );
}
```
If `Textarea` does not forward `ref` as a prop in this shadcn version (check `src/components/ui/textarea.tsx` — React 19 components receive `ref` as a normal prop when they spread `...props` onto the element), it does; otherwise wrap with `React.forwardRef` is NOT needed in React 19 — just pass `ref`.

- [ ] **Step 2: Gates** exit 0.

- [ ] **Step 3: Commit**: `git add src/features/ai/ai-composer.tsx && git commit -m "feat: composer card with a growing textarea and a fixed action bar"`

---

### Task 4: `AiSourcesTab` — the Sources tab body

**Files:**
- Create: `src/features/ai/ai-sources-tab.tsx`
- Delete: `src/features/ai/ai-sources-strip.tsx` (its logic moves here; the delete lands in Task 6 when the dock stops importing it — in THIS task only create the new file)

**Interfaces:**
- Consumes: `useArticleDocuments(articleId)`, `useSetArticleDocuments(articleId)`, `useDocuments(enabled)`, `useUploadDocument()`, `DocumentStatusChip`, `DOCUMENT_ACCEPT`, `getApiErrorMessage`, `ROUTES.dashboardDocuments`.
- Produces: `AiSourcesTab({ articleId }: { articleId?: string })`.

- [ ] **Step 1: Implement** `src/features/ai/ai-sources-tab.tsx`:

```tsx
'use client';

import { useRef, useState } from 'react';
import Link from 'next/link';
import { Check, FileUp, X } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Progress } from '@/components/ui/progress';
import { ScrollArea } from '@/components/ui/scroll-area';
import { useDocuments, useUploadDocument } from '@/hooks/use-documents';
import { useArticleDocuments, useSetArticleDocuments } from '@/hooks/use-article-documents';
import { DocumentStatusChip } from '@/features/documents/document-status-chip';
import { DOCUMENT_ACCEPT } from '@/features/documents/document-types';
import { getApiErrorMessage } from '@/lib/api/error';
import { ROUTES } from '@/lib/constants';
import { cn } from '@/lib/utils';

/**
 * The Sources tab: what this article reads, and the library to pick from.
 *
 * The same data and the same optimistic attach/detach mutation the Sources
 * strip used, given a whole tab instead of one crowded line. Upload lives
 * here too — the writer curates sources while writing, and a round trip to
 * the library page for every file was the friction the strip had.
 */
export function AiSourcesTab({ articleId }: { articleId?: string }) {
  const attached = useArticleDocuments(articleId);
  // Always enabled here: the tab is only mounted while it is visible.
  const library = useDocuments(true);
  const setDocuments = useSetArticleDocuments(articleId);
  const upload = useUploadDocument();
  const inputRef = useRef<HTMLInputElement>(null);
  const [progress, setProgress] = useState<number | null>(null);

  // Hooks above; the early return below is the only one.
  if (!articleId) {
    return <p className="px-4 py-6 text-sm text-muted-foreground">Save the article once to attach sources</p>;
  }

  const attachedIds = new Set((attached.data ?? []).map((d) => d.id));

  const save = (ids: string[]) =>
    setDocuments.mutate(ids, {
      onError: (err) => toast.error(getApiErrorMessage(err, 'Could not update the sources')),
    });

  // A PUT built from an empty placeholder would carry only the toggled id and
  // wipe the rest server-side, so nothing toggles until the list has loaded.
  const toggle = (id: string) => {
    if (attached.data === undefined) return;
    const next = new Set(attachedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    save([...next]);
  };

  const onPick = async (file: File | undefined) => {
    if (!file) return;
    setProgress(0);
    try {
      await upload.mutateAsync({ file, onProgress: setProgress });
    } catch (err) {
      // Client-side refusals are plain Errors with the message to show;
      // everything else is an Axios failure with an API message or the fallback.
      toast.error(err instanceof Error && !('isAxiosError' in err) ? err.message : getApiErrorMessage(err, 'Could not upload the document'));
    } finally {
      setProgress(null);
      if (inputRef.current) inputRef.current.value = '';
    }
  };

  const full = !!library.data && library.data.count >= library.data.max;

  return (
    <ScrollArea className="min-h-0 flex-1">
      <div className="space-y-5 px-4 py-4 text-sm">
        {/* Attached */}
        <section>
          <h3 className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Attached to this article</h3>
          {attached.isError && attached.data === undefined ? (
            <p className="flex items-center gap-2 text-muted-foreground">
              Couldn&apos;t load sources
              <Button variant="ghost" size="sm" className="h-6 px-2 text-xs" onClick={() => void attached.refetch()}>
                Retry
              </Button>
            </p>
          ) : attached.data?.length ? (
            <ul className="space-y-1">
              {attached.data.map((doc) => (
                <li key={doc.id} className="flex items-center gap-2 rounded-md border px-2 py-1.5">
                  <span className="min-w-0 flex-1 truncate">{doc.title}</span>
                  {doc.pageCount && doc.pageCount > 1 ? (
                    <span className="shrink-0 text-xs text-muted-foreground">{doc.pageCount} p.</span>
                  ) : null}
                  {doc.status !== 'ready' && <DocumentStatusChip doc={doc} />}
                  <button
                    type="button"
                    aria-label={`Detach ${doc.title}`}
                    onClick={() => toggle(doc.id)}
                    disabled={attached.data === undefined}
                    className="text-muted-foreground hover:text-foreground disabled:pointer-events-none disabled:opacity-50"
                  >
                    <X className="size-4" />
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-muted-foreground">No sources attached — the assistant writes from your own published work.</p>
          )}
        </section>

        {/* Library */}
        <section>
          <div className="mb-2 flex items-center justify-between">
            <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Your library</h3>
            <div className="flex items-center gap-2">
              {progress !== null && <Progress value={Math.round(progress * 100)} className="w-20" />}
              <input ref={inputRef} type="file" accept={DOCUMENT_ACCEPT} className="hidden" onChange={(e) => void onPick(e.target.files?.[0])} />
              <Button
                variant="outline"
                size="sm"
                className="h-7 px-2 text-xs"
                onClick={() => inputRef.current?.click()}
                disabled={full || progress !== null}
                title={full ? `${library.data?.max} of ${library.data?.max} — delete one to upload another` : undefined}
              >
                <FileUp className="mr-1 size-3.5" /> Upload
              </Button>
            </div>
          </div>
          {library.isPending ? (
            <p className="text-muted-foreground">Loading…</p>
          ) : library.isError ? (
            <p className="text-muted-foreground">Couldn&apos;t load your documents</p>
          ) : library.data.items.length === 0 ? (
            <p className="text-muted-foreground">No documents yet — upload a PDF, DOCX, TXT or MD file.</p>
          ) : (
            <ul role="group" aria-label="Attach documents" className="space-y-0.5">
              {library.data.items.map((doc) => {
                const ready = doc.status === 'ready';
                const on = attachedIds.has(doc.id);
                return (
                  <li key={doc.id}>
                    {ready ? (
                      <button
                        type="button"
                        role="checkbox"
                        aria-checked={on}
                        onClick={() => toggle(doc.id)}
                        disabled={attached.data === undefined}
                        className={cn(
                          'flex w-full items-center gap-2 rounded px-2 py-1.5 text-left hover:bg-muted disabled:pointer-events-none disabled:opacity-50',
                          on && 'font-medium',
                        )}
                      >
                        <span className={cn('flex size-4 shrink-0 items-center justify-center rounded border', on && 'bg-primary text-primary-foreground')}>
                          {on && <Check className="size-3" />}
                        </span>
                        <span className="min-w-0 flex-1 truncate">{doc.title}</span>
                        {doc.pageCount && doc.pageCount > 1 ? (
                          <span className="shrink-0 text-xs text-muted-foreground">{doc.pageCount} p.</span>
                        ) : null}
                      </button>
                    ) : (
                      // Pending / failed: shown so the writer sees it exists, but not toggleable.
                      <div className="flex items-center gap-2 px-2 py-1.5 text-muted-foreground">
                        <span className="size-4 shrink-0" />
                        <span className="min-w-0 flex-1 truncate">{doc.title}</span>
                        <DocumentStatusChip doc={doc} />
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <Link href={ROUTES.dashboardDocuments} className="mt-3 inline-block text-xs text-primary hover:underline">
            Manage in library →
          </Link>
        </section>
      </div>
    </ScrollArea>
  );
}
```

- [ ] **Step 2: Gates** exit 0 (the file is not yet imported anywhere; that is fine).

- [ ] **Step 3: Commit**: `git add src/features/ai/ai-sources-tab.tsx && git commit -m "feat: Sources tab — attached list, library with upload, no more strip"`

---

### Task 5: `AiAssistantPanel` and `AiAssistantRail`

**Files:**
- Create: `src/features/ai/ai-assistant-panel.tsx`, `src/features/ai/ai-assistant-rail.tsx`

**Interfaces:**
- Consumes: `AiComposer` + `AiComposerProps` (Task 3), `AiSourcesTab` (Task 4), `corpusLine` (Task 1), existing `AiRunCard`, `AiChatMessage`, `AiQuotaNotice`, `AiTokenIndicator`, `Notice`, `Tabs*`, `ScrollArea`.
- Produces:

```ts
export type PanelTab = 'chat' | 'sources';
export interface AiAssistantPanelProps {
  articleId?: string;
  /** Desktop: collapse to the rail. Sheet: close. The host decides the icon. */
  onCollapse: () => void;
  collapseLabel: 'Collapse' | 'Minimize';
  /** Refused while recording — the host passes the same reason the dock used. */
  collapseDisabledReason?: string;
  speech: { available: boolean; pending: boolean; muted: boolean; playPending: () => void; toggleMuted: () => void };
  /** Everything the Chat tab renders, straight from the host's hooks. */
  chat: {
    messages: ReadonlyArray<{ id: string; role: string; parts: unknown }>;
    runs: Record<string, RunState>;
    currentRunId: string | null;
    activeRun: RunState | null;
    streaming: boolean;
    error: Error | undefined;
    exhausted: boolean;
    spentByReply: boolean;
    corpus: { articles: number; sources: number };
  };
  composer: AiComposerProps;
  /** Controlled tab so the rail and the 📎 chip can open a specific one. */
  tab: PanelTab;
  onTabChange: (tab: PanelTab) => void;
}
export function AiAssistantRail(props: { activeLabel: string | null; wordCount: number | null; unread: boolean; attachedCount: number; speech: AiAssistantPanelProps['speech']; onOpen: (tab: PanelTab) => void }): JSX.Element
```
Task 6 wires them. Check the exact `useAiAssistant` return types (`messages` is `UIMessage[]`; `runs` is `Record<string, RunState>`; `currentRunId: string | null`; `activeRun: RunState | null`) in `use-ai-assistant.ts` and match them — do not widen with `unknown` if the real type imports cleanly.

- [ ] **Step 1: Implement** `src/features/ai/ai-assistant-panel.tsx`:

```tsx
'use client';

import { useEffect, useRef } from 'react';
import { AlertCircle, ChevronDown, ChevronsRight, Loader2, Play, Volume2, VolumeX } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Notice } from '@/components/shared/notice';
import { AiChatMessage } from './ai-chat-message';
import { AiRunCard } from './ai-run-card';
import { AiTokenIndicator } from './ai-token-indicator';
import { AiQuotaNotice } from './ai-quota-notice';
import { AiComposer, type AiComposerProps } from './ai-composer';
import { AiSourcesTab } from './ai-sources-tab';
import { corpusLine } from './ai-corpus-line';
import type { RunState } from './assistant-run';

export type PanelTab = 'chat' | 'sources';

/** Extracts text content from a UIMessage's parts array. */
function getMessageText(parts: Array<{ type: string; text?: string }>): string {
  return parts.filter((p) => p.type === 'text' && p.text).map((p) => p.text!).join('');
}

export interface AiAssistantPanelProps {
  articleId?: string;
  onCollapse: () => void;
  collapseLabel: 'Collapse' | 'Minimize';
  collapseDisabledReason?: string;
  speech: { available: boolean; pending: boolean; muted: boolean; playPending: () => void; toggleMuted: () => void };
  chat: {
    messages: ReadonlyArray<{ id: string; role: string; parts: unknown }>;
    runs: Record<string, RunState>;
    currentRunId: string | null;
    activeRun: RunState | null;
    streaming: boolean;
    error: Error | undefined;
    exhausted: boolean;
    spentByReply: boolean;
    corpus: { articles: number; sources: number };
  };
  composer: AiComposerProps;
  tab: PanelTab;
  onTabChange: (tab: PanelTab) => void;
}

/**
 * The assistant panel with no opinion about where it sits: header, the
 * Chat | Sources tabs, and the two tab bodies. The host renders it as a
 * 400 px column on desktop and inside a bottom sheet below that; the only
 * difference it can see is the collapse button's label and icon.
 */
export function AiAssistantPanel({
  articleId,
  onCollapse,
  collapseLabel,
  collapseDisabledReason,
  speech,
  chat,
  composer,
  tab,
  onTabChange,
}: AiAssistantPanelProps) {
  const endRef = useRef<HTMLDivElement>(null);
  const { messages, runs, currentRunId, activeRun, streaming, error, exhausted, spentByReply, corpus } = chat;

  // Total characters rendered — changes per streamed token, so the view
  // stays pinned to the bottom throughout a reply (moved from the dock).
  const renderedLength = messages.reduce((t, m) => t + getMessageText(m.parts as never).length, 0);
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' });
  }, [renderedLength, messages.length, streaming, exhausted, activeRun]);

  const lastMessage = messages[messages.length - 1];
  // The turn is out and nothing has come back: the run's early rows live in
  // `runs` under a placeholder id and render after the user's message until
  // the assistant message appears (moved from the dock).
  const awaitingReply = lastMessage?.role === 'user';
  const pendingRun = streaming && awaitingReply ? activeRun : null;
  const line = corpusLine(corpus);
  const attachedCount = composer.attachedCount;

  return (
    <div className="flex h-full min-h-0 flex-col">
      <header className="flex items-start justify-between border-b px-4 py-3">
        <div>
          <h2 className="text-base font-medium text-foreground">AI Writing Assistant</h2>
          <AiTokenIndicator />
        </div>
        <div className="flex items-center gap-1">
          {/* Play appears only for a blocked autoplay; mute always mutes (unchanged from the dock). */}
          {speech.available && speech.pending && (
            <Button variant="ghost" size="icon-sm" aria-label="Play the reply" title="Play the reply" onClick={speech.playPending}>
              <Play />
            </Button>
          )}
          {speech.available && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-pressed={speech.muted}
              aria-label={speech.muted ? "Unmute the assistant's voice" : "Mute the assistant's voice"}
              onClick={speech.toggleMuted}
            >
              {speech.muted ? <VolumeX /> : <Volume2 />}
            </Button>
          )}
          {/* No Close: a docked panel collapses. Refused while a recording is open — same rule as the dock. */}
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={collapseLabel}
            disabled={!!collapseDisabledReason}
            title={collapseDisabledReason}
            onClick={onCollapse}
          >
            {collapseLabel === 'Collapse' ? <ChevronsRight /> : <ChevronDown />}
          </Button>
        </div>
      </header>

      <Tabs value={tab} onValueChange={(v) => onTabChange(v as PanelTab)} className="min-h-0 flex-1 gap-0">
        <TabsList variant="line" className="w-full justify-start border-b px-2">
          <TabsTrigger value="chat" className="gap-1.5">
            Chat
            {streaming && <Loader2 className="size-3 animate-spin" aria-label="working" />}
          </TabsTrigger>
          <TabsTrigger value="sources" className="gap-1.5">
            Sources
            {attachedCount > 0 && <span className="rounded-full bg-muted px-1.5 text-xs">{attachedCount}</span>}
          </TabsTrigger>
        </TabsList>

        <TabsContent value="chat" className="flex min-h-0 flex-1 flex-col">
          <AiQuotaNotice className="mx-4 mt-3" />
          {/* min-h-0 is load-bearing — a flex child cannot shrink below its content otherwise. */}
          <ScrollArea className="min-h-0 flex-1 px-4 py-4">
            {messages.length === 0 ? (
              <div className="flex h-full items-center justify-center text-center text-sm text-muted-foreground">
                <p>{line.empty}</p>
              </div>
            ) : (
              <div className="space-y-4">
                {messages.map((msg) => {
                  const text = getMessageText(msg.parts as never);
                  if (msg.role === 'user') return <AiChatMessage key={msg.id} role="user" content={text} />;
                  const run = runs[msg.id] ?? (msg.id === messages.at(-1)?.id && currentRunId ? runs[currentRunId] : undefined);
                  return run ? <AiRunCard key={msg.id} run={run} text={text} /> : <AiChatMessage key={msg.id} role="assistant" content={text} />;
                })}
                {pendingRun && <AiRunCard run={pendingRun} text="" />}
                {/* The request failed before any assistant message existed (moved from the dock). */}
                {error && awaitingReply && (
                  <div className="flex items-start gap-2 rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                    <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                    <span>{error.message || 'Something went wrong. Please try again.'}</span>
                  </div>
                )}
                {/* The reply above spent the balance — the debt notice (moved from the dock). */}
                {exhausted && spentByReply && !streaming && (
                  <Notice tone="locked">That reply used the last of today&apos;s tokens. Chat resumes at 00:00 UTC.</Notice>
                )}
                <div ref={endRef} />
              </div>
            )}
          </ScrollArea>
          {/* The corpus line, once a conversation exists; the empty state already carries it. */}
          {messages.length > 0 && line.footer && (
            <p className="px-4 pb-1 text-xs text-muted-foreground">{line.footer}</p>
          )}
          <AiComposer {...composer} />
        </TabsContent>

        <TabsContent value="sources" className="flex min-h-0 flex-1 flex-col">
          <AiSourcesTab articleId={articleId} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
```
Check `TabsList`'s `variant` prop and `TabsContent`'s default classes in `src/components/ui/tabs.tsx` and adjust class names so the tab list is a full-width underline row and the content fills the remaining height (`TabsContent` may need `data-[state=inactive]:hidden` or `forceMount` semantics — base-ui unmounts inactive panels by default, which is what we want: the Sources tab's queries run only while visible).

- [ ] **Step 2: Implement** `src/features/ai/ai-assistant-rail.tsx`:

```tsx
'use client';

import { Loader2, MessageSquare, Paperclip, Volume2, VolumeX } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';
import type { AiAssistantPanelProps, PanelTab } from './ai-assistant-panel';

interface AiAssistantRailProps {
  /** Current step while a request is in flight; null when idle. */
  activeLabel: string | null;
  /** Live word count during a write, shown on the badge instead of a spinner. */
  wordCount: number | null;
  /** A run finished while collapsed and has not been looked at. */
  unread: boolean;
  attachedCount: number;
  speech: AiAssistantPanelProps['speech'];
  onOpen: (tab: PanelTab) => void;
}

/**
 * The collapsed panel: a 48 px column with Chat and Sources at the top and
 * mute at the bottom. The Chat button carries the live step as a badge so
 * the writer can collapse and still watch it work — the pill's job, in the
 * dock's place.
 */
export function AiAssistantRail({ activeLabel, wordCount, unread, attachedCount, speech, onOpen }: AiAssistantRailProps) {
  return (
    <div className="flex h-full w-12 flex-col items-center border-l bg-popover py-2">
      <Tooltip>
        <TooltipTrigger render={<Button variant="ghost" size="icon" className="relative" aria-label={activeLabel ? `AI assistant: ${activeLabel}` : 'Open chat'} onClick={() => onOpen('chat')} />}>
          <MessageSquare className="size-5" />
          {activeLabel && (
            <span className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[10px] text-primary-foreground">
              {wordCount !== null ? wordCount.toLocaleString('en-US') : <Loader2 className="size-3 animate-spin" />}
            </span>
          )}
          {unread && !activeLabel && (
            <span aria-hidden="true" className="absolute right-1 top-1 h-2 w-2 rounded-full bg-ink-warning-text ring-2 ring-background" />
          )}
        </TooltipTrigger>
        <TooltipContent side="left">{activeLabel ?? 'Chat'}</TooltipContent>
      </Tooltip>
      <Tooltip>
        <TooltipTrigger render={<Button variant="ghost" size="icon" className="relative" aria-label="Open sources" onClick={() => onOpen('sources')} />}>
          <Paperclip className="size-5" />
          {attachedCount > 0 && (
            <span className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-muted px-1 text-[10px]">{attachedCount}</span>
          )}
        </TooltipTrigger>
        <TooltipContent side="left">Sources</TooltipContent>
      </Tooltip>
      <div className="mt-auto">
        {speech.available && (
          <Button
            variant="ghost"
            size="icon"
            aria-pressed={speech.muted}
            aria-label={speech.muted ? "Unmute the assistant's voice" : "Mute the assistant's voice"}
            onClick={speech.toggleMuted}
          >
            {speech.muted ? <VolumeX className="size-5" /> : <Volume2 className="size-5" />}
          </Button>
        )}
      </div>
    </div>
  );
}
```
Check `TooltipTrigger`'s API in `src/components/ui/tooltip.tsx` (base-ui: `render=` like Popover; if the wrapper expects children-as-trigger, adapt) and whether a `TooltipProvider` is mounted at the app root (grep `TooltipProvider` in `src/app`); if not, wrap the rail's root in one.

- [ ] **Step 3: Gates** exit 0 (nothing imports these yet).

- [ ] **Step 4: Commit**: `git add src/features/ai/ai-assistant-panel.tsx src/features/ai/ai-assistant-rail.tsx && git commit -m "feat: assistant panel with Chat and Sources tabs, and its collapsed rail"`

---

### Task 6: `AiAssistantHost` — the container (dock → host)

**Files:**
- Rename: `src/features/ai/ai-assistant-dock.tsx` → `src/features/ai/ai-assistant-host.tsx` (`git mv`, then edit)
- Delete: `src/features/ai/ai-sources-strip.tsx`, `src/features/ai/ai-corpus-notice.tsx`
- Modify: `src/features/ai/ai-assistant-pill.tsx` (unchanged code; only its doc comment says "below desktop width")

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `AiAssistantHost({ articleId, editor, onWriteOpenChange, expanded, onExpandedChange })` — the shell (Task 7) owns `expanded` for the desktop toggle button and the sheet's open flag alike.

```ts
interface AiAssistantHostProps {
  articleId: string;
  editor: Editor | null;
  onWriteOpenChange: (open: boolean) => void;
  /** Desktop: expanded column vs rail. Below lg: sheet open vs closed. */
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}
```

- [ ] **Step 1: `git mv src/features/ai/ai-assistant-dock.tsx src/features/ai/ai-assistant-host.tsx`**, then rewrite the file. Keep — verbatim, comments included — everything from the dock between the top of the component and `const keepDiscardBar = …`: `useAiAssistant`, `useSpeechOut` (`enabled: expanded`), `useAiQuota`, `useAiTokens`, `input`, `recording`, `handleTranscript` (the ref becomes `useRef<HTMLTextAreaElement>(null)`), `unread` + `prevStreaming`, the `onWriteOpenChange` effect, `spentByReply` + `balanceReadAtSend` and their render-time adjustment, the Escape effect (now `if (!isDesktop || !expanded || recording) return;` and it calls `collapse()`), `handleSubmit`, `keepDiscardBar`, `placeholder`, `inputDisabled`, `canRecord`, `recordReason`. Remove `minimized`/`MINIMIZED_KEY` (replaced by `usePanelState`), the auto-scroll effect and `renderedLength` (moved into the panel), and the whole JSX. Add:

```tsx
import { useIsDesktop } from '@/hooks/use-media-query';
import { usePanelState } from './use-panel-state';
import { AiAssistantPanel, type PanelTab } from './ai-assistant-panel';
import { AiAssistantRail } from './ai-assistant-rail';
import { AiAssistantPill } from './ai-assistant-pill';
import { Sheet, SheetContent, SheetTitle } from '@/components/ui/sheet';
import { useAiRetrieval } from './use-ai-retrieval';
import { useArticleDocuments } from '@/hooks/use-article-documents';
import { currentStepLabel } from './assistant-run';
```

and, inside the component (hooks first, before `keepDiscardBar`):

```tsx
  const isDesktop = useIsDesktop();
  const [tab, setTab] = useState<PanelTab>('chat');
  // The corpus numbers for the empty state / footer, and the attached count
  // for the 📎 chip and the tab badge. Both already cached by their queries.
  const retrieval = useAiRetrieval();
  const attached = useArticleDocuments(articleId);
  const corpus = {
    articles: retrieval.data?.corpus.articles ?? 0,
    sources: attached.data?.length ?? 0,
  };
  const collapse = () => {
    // Playback is stopped on the sheet only: on desktop the rail keeps the
    // mute control visible, so a voice may carry on while collapsed.
    if (!isDesktop) speech.stop();
    onExpandedChange(false);
    setUnread(false);
  };
  const openTab = (next: PanelTab) => {
    setTab(next);
    onExpandedChange(true);
    setUnread(false);
  };
```

Note `expanded` here is the prop; `setUnread(true)` fires when a run ends while `!expanded` (replace `minimized` with `!expanded` in the `prevStreaming` block).

The composer props object:

```tsx
  const composer = {
    value: input,
    onChange: setInput,
    onSubmit: handleSubmit,        // handleSubmit no longer takes an event
    onStop: () => { speech.stop(); stop(); },
    streaming: isStreaming,
    disabled: inputDisabled,
    placeholder,
    recording,
    canRecord,
    recordReason,
    onRecordingChange: setRecording,
    onTranscript: handleTranscript,
    attachedCount: corpus.sources,
    onOpenSources: () => openTab('sources'),
    textareaRef: inputRef,
  };
  const panel = (
    <AiAssistantPanel
      articleId={articleId}
      onCollapse={collapse}
      collapseLabel={isDesktop ? 'Collapse' : 'Minimize'}
      collapseDisabledReason={recording ? 'Finish or cancel the recording first' : undefined}
      speech={speech}
      chat={{ messages, runs, currentRunId, activeRun, streaming: isStreaming, error, exhausted, spentByReply, corpus }}
      composer={composer}
      tab={tab}
      onTabChange={setTab}
    />
  );
  const activeLabel = activeRun ? currentStepLabel(activeRun) : null;
  const wordCount = activeRun?.writing && !activeRun.writing.done ? activeRun.writing.words : null;
```

and the return:

```tsx
  return (
    <>
      {keepDiscardBar}
      {isDesktop ? (
        expanded ? (
          <aside aria-label="AI Writing Assistant" className="flex h-full w-[400px] shrink-0 flex-col border-l bg-popover text-sm text-popover-foreground">
            {panel}
          </aside>
        ) : (
          <AiAssistantRail activeLabel={activeLabel} wordCount={wordCount} unread={unread} attachedCount={corpus.sources} speech={speech} onOpen={openTab} />
        )
      ) : (
        <>
          {!expanded && <AiAssistantPill label={activeLabel} unread={unread} onClick={() => openTab('chat')} />}
          <Sheet open={expanded} onOpenChange={(o) => (o ? onExpandedChange(true) : collapse())}>
            <SheetContent side="bottom" showCloseButton={false} className="h-[85vh] gap-0 rounded-t-xl p-0">
              <SheetTitle className="sr-only">AI Writing Assistant</SheetTitle>
              {panel}
            </SheetContent>
          </Sheet>
        </>
      )}
    </>
  );
```
`handleSubmit` becomes `() => { if (recording || !input.trim() || isStreaming || exhausted || openWrite) return; speech.stop(); const sent = sendMessage(input.trim()); if (sent) { setBalanceReadAtSend(balanceReadAt); setInput(''); if (inputRef.current) inputRef.current.style.height = 'auto'; } }` — the last line resets the grown textarea. The Sheet's `onOpenChange(false)` while recording: the collapse button is disabled, but Escape/backdrop still fire `onOpenChange(false)` — guard `collapse` with `if (recording) return;` at its top so the recorder is never unmounted mid-dictation (same rule the dock enforced through its disabled buttons).

- [ ] **Step 2: Delete** `src/features/ai/ai-sources-strip.tsx` and `src/features/ai/ai-corpus-notice.tsx` (`git rm`). Grep for remaining importers: `grep -rn "ai-sources-strip\|ai-corpus-notice\|AiAssistantDock" src` → only the editor shell's dock import may remain (fixed in Task 7; the gates will fail until then — do Task 7 before running them, OR temporarily keep the shell compiling by doing Task 7's edit in this task). **Ruling for the executor:** do Tasks 6 and 7 as one dispatch and one commit if the intermediate state cannot compile.

- [ ] **Step 3: Pill comment**: in `ai-assistant-pill.tsx` change the doc comment's first line to "The minimized assistant below desktop width." — no code change.

- [ ] **Step 4: Gates** (after Task 7's shell edit) exit 0.

- [ ] **Step 5: Commit** (with Task 7): see Task 7.

---

### Task 7: Editor shell — two columns, toggle button

**Files:**
- Modify: `src/features/editor/editor-shell.tsx`

**Interfaces:**
- Consumes: `AiAssistantHost` (Task 6).

- [ ] **Step 1: Replace the dock import** with `import { AiAssistantHost } from '@/features/ai/ai-assistant-host';` and rename the state: `const [aiExpanded, setAiExpanded] = useState(true);` (the host's `usePanelState` seeds the desktop default; the shell's flag is the *session* flag — see Step 3).

- [ ] **Step 2: Layout.** The returned tree becomes:

```tsx
  return (
    // Two columns on desktop: the document and the assistant. The row fills
    // the height under the sticky 4 rem navbar so the panel scrolls on its
    // own while the document keeps the page scroll.
    <div className="flex min-h-[calc(100vh-4rem)] lg:h-[calc(100vh-4rem)]">
      <div className="min-w-0 flex-1 lg:overflow-y-auto">
        <div className="mx-auto max-w-4xl space-y-4 px-4 py-8">
          {/* … the existing toolbar, title input, TipTapEditor, PublishDialog — unchanged … */}
        </div>
      </div>
      {currentId && (
        <AiAssistantHost
          articleId={currentId}
          editor={editor}
          onWriteOpenChange={handleWriteOpenChange}
          expanded={aiExpanded}
          onExpandedChange={setAiExpanded}
        />
      )}
    </div>
  );
```
The toolbar button: `onClick={() => setAiExpanded((v) => !v)}`, label `AI Assistant` unchanged, `aria-pressed={aiExpanded}`.

- [ ] **Step 3: Persisted default.** The host owns persistence: on mount it calls `onExpandedChange(state === 'expanded')` once and writes through `setState` whenever `expanded` changes on desktop. Implement in the host with the "adjust state from a previous render" pattern, not an effect:

```tsx
  const { state: persisted, setState: persist } = usePanelState();
  // Seed the shell's flag from the persisted state exactly once — the same
  // "derived from a previous render" pattern the dock used for `unread`.
  const [seeded, setSeeded] = useState(false);
  if (!seeded) {
    setSeeded(true);
    onExpandedChange(persisted === 'expanded');
  }
  // Mirror the shell's flag into storage on desktop (the sheet's open flag is not remembered).
  const [prevExpanded, setPrevExpanded] = useState(expanded);
  if (prevExpanded !== expanded) {
    setPrevExpanded(expanded);
    if (isDesktop) persist(expanded ? 'expanded' : 'rail');
  }
```
(`onExpandedChange` inside render is a parent setState during a child's render — React allows it for a component rendering *its own* subtree only. If the compiler/lint objects, replace the seed with: the shell initialises `aiExpanded` from `usePanelState().state === 'expanded'` itself and passes `persist` down; do whichever the gates accept and say which in the report.)

- [ ] **Step 4: Gates** exit 0; then `docker exec -w /app inkwell-web-1 node --test src/features/ai/ai-corpus-line.check.ts src/features/ai/assistant-run.check.ts` still green.

- [ ] **Step 5: Commit** (Tasks 6+7 together): `git add -A src && git commit -m "feat: dock the assistant beside the editor — tabbed panel, rail, sheet below desktop"`

---

### Task 8: Spec repo

**Files (in `spec.inkwell.ai`, branch `docs/assistant-side-panel` from `origin/main`):** `2-features.md` §3.1, `3-user-flows.md` §5, `10-requirements.md` FR-81.

- [ ] **Step 1: `2-features.md` §3.1** — rewrite the paragraph describing the floating dock (it currently says a bottom-right card that minimizes to a pill): the assistant is a **400 px panel docked beside the editor** with **Chat and Sources tabs**; a **composer card** (multi-line, Enter sends / Shift+Enter newline; mic, 📎 count, Send/Stop in a fixed action bar); collapses to a **48 px rail** whose Chat icon carries the live step; below `lg` the same panel opens as a bottom sheet and the pill shows the live step while closed. Mark *(2026-09-20)*. Keep the step-list sentence (draft → profile → documents → thinking → …) as is.
- [ ] **Step 2: `3-user-flows.md` §5** — update the "open the assistant" steps: toolbar button toggles the panel/rail; Sources tab for attach/upload; the rail badge while writing.
- [ ] **Step 3: `10-requirements.md`** — FR-81 becomes: `The assistant is a panel docked beside the editor with Chat and Sources tabs; it collapses to a rail that carries the live step, and opens as a bottom sheet below desktop width *(amended 2026-09-20; was a floating dock)*`. Do not renumber.
- [ ] **Step 4: Commit**: `git add . && git commit -m "docs: assistant becomes a docked, tabbed side panel"`

---

### Task 9: Browser pass (controller, Chrome extension)

- [ ] 1440 px: open an article → panel column beside the document, sidebar intact; toolbar button → rail; send a write from the rail state (open, send, collapse) → Chat badge shows the word count climbing; expand → conversation intact, Keep/Discard bar in the editor.
- [ ] Chat ⇄ Sources; attach two documents from the Sources tab → `📎 2` in the composer and `Sources · 2` on the tab; upload a `.md` from the tab → row appears, polls to Ready.
- [ ] Composer: type five lines → grows to four then scrolls; Shift+Enter inserts a newline; Enter sends; record → only the left slot changes, Send stays disabled; a second turn after a write → 200.
- [ ] Escape while recording → refused; Escape otherwise → rail. Reload → the rail/expanded state persists.
- [ ] 390 px (device toolbar): toolbar button → bottom sheet with tabs; minimize → pill; pill shows the step during a run.
- [ ] Clean up probe rows in `ai_interactions`, restore the token balance, detach/delete the test documents.

---

## Self-review

**Spec coverage.** §4 layout/states/persistence/migration → Tasks 2, 6, 7. §5 header (no Close, Play/mute rules) / tabs with badges / Chat tab (quota only when low, empty state, footer) / Sources tab (two groups, upload, manage link, error lines) / composer (textarea 1→4, Enter/Shift+Enter, three slots, disabled rules) → Tasks 1, 3, 4, 5. §6 sheet 85 vh + pill below `lg` → Task 6. §7 file shape → the file map (one addition: `use-media-query.ts`, `use-panel-state.ts` split out of the host for testability). §8 edge cases: Escape while recording (host effect), collapse during a pending write (allowed; badge — the rail shows `activeLabel` which `currentStepLabel` reports as null once `done`; the pending Keep/Discard state is visible via the bar itself — **accepted deviation**: no extra badge for "awaiting decision"), no article id (Sources tab copy), resize across `lg` (host never unmounts; panel remounts), Sources tab open when a run starts (Chat badge spins, no auto-switch), upload failure toasts → Tasks 4–7. §9 verification → Tasks 1, 9. §10 out of scope respected.

**Placeholders.** None. Two "check the real API" notes name the file to read (`tabs.tsx`, `tooltip.tsx`) and the fallback.

**Type consistency.** `PanelTab` defined in Task 5, used in 6; `AiComposerProps` defined in 3, spread in 5, built in 6; `corpusLine` shape `{empty, footer}` used in 5; `usePanelState` returns `{state, setState}` consumed in 6/7; `useIsDesktop` boolean in 6; `AiAssistantHost` props match the shell's call in 7; `speech` shape (`available, pending, muted, playPending, toggleMuted`) is the subset of `useSpeechOut`'s return the dock already used.
