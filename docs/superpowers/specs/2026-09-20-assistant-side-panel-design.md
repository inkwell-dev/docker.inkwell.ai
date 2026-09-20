# Assistant side panel — design

*2026-09-20. Approved in conversation, section by section; this is the written
form. Restructures the layout of the floating assistant (`2026-09-13`) after
the voice (`2026-09-14`) and document-sources (`2026-09-16`) tickets filled
it. Nothing the assistant does changes; only where its parts live.*

## 1. The request, in the user's words

> the chatbox is getting crowded with the message input and the documents
> section and voice input. it needs a redesign or better to say a layout
> restructure. … the approach of the UI of NotebookLM, like the side by side,
> side editor and side is agent. But keep the general sidebar on, of course.

## 2. The problem

The dock is a 380 × 560 px card. Between its header and the conversation sit
three permanent bands — the quota notice (when low), the corpus notice, and
the Sources strip — and its single input row carries the microphone, the text
field and Send, with the recording state swapping controls into the same row.
The conversation gets roughly half the card, and a two-sentence brief does not
fit in an `Input`.

## 3. Decisions

| Question | Decision |
|---|---|
| Layout | **Side by side on the editor page**: `[app sidebar] [editor] [assistant panel]`. The app sidebar stays. |
| Columns | **Two**, with the right panel **tabbed: Chat · Sources**. Not three — the editor keeps its width on a laptop. |
| Getting it out of the way | **Collapse to a 48 px rail** with Chat and Sources icons; the live step shows as a badge on Chat. The panel never closes. |
| Composer | **A composer card**: multi-line textarea (1 → 4 lines) with an action bar below — mic on the left, Send/Stop on the right, `📎 N` between. |
| Below desktop width | **The same panel in a bottom sheet**; the minimized pill survives only there. |
| Build | **One position-agnostic panel component, two containers** (column + rail on `lg+`, sheet + pill below). No new dependency; fixed 400 px width. |

Assumptions stated rather than asked:

- Panel state (expanded / rail, and the active tab) is per browser, not per
  article.
- Escape collapses to the rail exactly as it minimized the dock, including
  the refusal while a recording is in progress.
- The Keep/Discard bar, the write range and the run card are untouched.
- The `lg` breakpoint (1024 px) is the one the app sidebar already uses, so
  the panel is a column only when the sidebar is a column.

## 4. Page layout and states (desktop, `lg+`)

The editor page's content area — right of the 240 px sidebar, under the
navbar — becomes a flex row filling the viewport height below the navbar:

```
[app sidebar 240] [ editor column (flex-1, scrolls)          ][ assistant 400 ]
                   title / toolbar                              header + tabs
                   ┌─ document (max-w-4xl, centred) ─┐          Chat | Sources
                   │                                 │          …
                   └─────────────────────────────────┘          composer
```

**States**, persisted under `localStorage` key `inkwell.ai-panel.state` (the
dock's `inkwell.ai-dock.minimized` key is read once for migration, then
ignored):

- `expanded` — a 400 px column with its own vertical scroll. The editor
  column keeps its centred `max-w-4xl` document; on a 1440 px screen the
  document still has ~800 px.
- `rail` — a 48 px column: Chat and Sources icon buttons stacked at the top,
  the mute toggle at the bottom. While a run is in flight the Chat icon
  carries a badge: a spinner, and for a write the live word count ("240");
  the full step label is the button's tooltip. Clicking either icon expands
  the panel to that tab.

The editor toolbar's "AI Assistant" button toggles expanded ⇄ rail. The
panel is mounted for the editor's whole life, so the conversation and a
pending Keep/Discard survive a collapse. `AiAssistantPill` is not rendered on
desktop.

## 5. Panel anatomy

```
┌ header ────────────────────────────────┐
│ AI Writing Assistant   ● 18,240 tokens │  title, token indicator
│                          [🔊] [»]      │  mute, collapse-to-rail — no Close
├ tabs ──────────────────────────────────┤
│ [ Chat ]  [ Sources · 2 ]              │  Sources badge = attached count;
├────────────────────────────────────────┤  Chat badge = live step while active
│  CHAT TAB                              │
│  quota notice, only when low           │
│  conversation (flex-1, scrolls)        │
│  ─ "Drawing on 12 articles · 2 sources"│  one muted line above the composer
├ composer card ─────────────────────────┤
│ ┌────────────────────────────────────┐ │
│ │ textarea 1→4 lines; Enter sends,   │ │
│ │ Shift+Enter newline                │ │
│ ├────────────────────────────────────┤ │
│ │ [🎤]  📎 2                 [Send ➤] │ │  idle
│ │ [● 0:42] [✓] [×]           [Send ➤] │ │  recording — Send disabled
│ │ [🎤]  📎 2                 [Stop ■] │ │  streaming
│ └────────────────────────────────────┘ │
└────────────────────────────────────────┘
```

- **Header.** Title, token indicator, mute (only when speech is available,
  as today), and `»` collapse. The Play button appears beside mute only when
  autoplay was blocked, unchanged. No Close.
- **Tabs.** `Chat` and `Sources`. The Sources tab shows the attached count;
  the Chat tab shows a small spinner while a run is active.
- **Chat tab.** The quota notice renders only when the balance is low
  (unchanged rule). The conversation fills the rest. The corpus sentence is
  no longer a band: the empty state reads *"Ask anything about your article,
  or tell me what to write — I draw on your 12 published articles and 2
  attached sources."*; once messages exist, one muted line above the
  composer reads *"Drawing on 12 articles · 2 sources"* (numbers from the
  existing retrieval-debug query and the attached list; "no sources" when
  none; the publish-first sentence when the corpus is empty, as today).
- **Sources tab.** Two groups. *Attached to this article*: title, page count,
  status chip when not ready, × to detach. *Your library*: every document
  with a checkbox for ready ones (attach/detach saves at once through the
  existing optimistic mutation) and the status chip for pending / failed
  ones (not toggleable). An **Upload** button runs the same presign → PUT →
  register flow as the library page, with the progress bar, so the writer
  never leaves the editor. *Manage in library →* links to
  `/dashboard/documents` for retry and delete. The error lines added on
  2026-09-20 ("Couldn't load sources" + Retry; "Couldn't load your
  documents") render in the tab. The Sources strip is removed.
- **Composer.** A `Textarea` that grows from one to four lines and then
  scrolls; Enter sends, Shift+Enter inserts a newline. The action bar's left
  slot is `VoiceRecorderControl` (idle / recording / transcribing exactly as
  now — only that slot changes while recording); the middle is the `📎 N`
  chip, which switches to the Sources tab; the right slot is Send, or Stop
  while streaming. The disabled rules are the dock's (streaming, exhausted,
  a write awaiting Keep/Discard).
- **Run card.** Unchanged.

## 6. Small screens (below `lg`)

The same `AiAssistantPanel` renders inside the app's `Sheet` (`side="bottom"`,
85 vh, rounded top). The toolbar button opens it; the header's `»` becomes
`⌄` and closes it. While closed with a run in flight, `AiAssistantPill` shows
the live step bottom-right — kept for this breakpoint only. Tabs, composer
and Sources tab are identical.

## 7. Code shape

All under `src/features/ai/` unless noted.

| File | Role |
|---|---|
| `ai-assistant-panel.tsx` (new) | Position-agnostic: header, tabs, the two tab bodies. Owns `tab: 'chat' \| 'sources'`. |
| `ai-composer.tsx` (new) | The composer card. Props: `value`, `onChange`, `onSubmit`, `onStop`, `streaming`, `disabled`, `disabledReason`, `attachedCount`, `onOpenSources`, plus the voice-input handle it renders in its left slot. |
| `ai-sources-tab.tsx` (new) | The Sources tab body; reuses `useArticleDocuments`, `useSetArticleDocuments`, `useDocuments`, `useUploadDocument`, `DocumentStatusChip`, `uploadDocument`. |
| `ai-assistant-rail.tsx` (new) | The 48 px rail with its badge. |
| `ai-corpus-line.ts` (new, pure) | `corpusLine({ articles, chunks, sources })` → the sentence / footer text; `node --test` checked. |
| `ai-assistant-host.tsx` (renamed from `ai-assistant-dock.tsx`) | The container: breakpoint, persisted state, column + rail on `lg+`, Sheet + pill below. Keeps all today's wiring: `useAiAssistant`, `useSpeechOut`, `useVoiceInput`, the recording guards, `onWriteOpenChange`. |
| `ai-sources-strip.tsx`, `ai-corpus-notice.tsx` | Deleted (their content moves to the Sources tab and `ai-corpus-line.ts`). |
| `src/features/editor/editor-shell.tsx` | The page becomes the two-column flex; the toolbar button toggles the host state. |

Unchanged: every hook, `assistant-run.ts`, `ai-run-card.tsx`,
`article-writer.ts`, `ai-write-range.ts`, `ai-keep-discard-bar.tsx`,
`voice-recorder-control.tsx`, the backend, the API.

## 8. Errors and edge cases

| Case | Behaviour |
|---|---|
| Escape while recording | Refused with the existing tooltip, as the dock did |
| Collapse while a write awaits Keep/Discard | Allowed; the bar stays in the editor; the Chat badge shows the pending state |
| Article not yet saved (no id) | Sources tab shows "Save the article once to attach sources"; composer works as today |
| Window resized across `lg` | The host switches container. The conversation, run state and recorder live in the host's hooks, which are never unmounted, so they persist; the panel itself may remount, which only resets scroll position and the active tab |
| Sources tab open when a run starts | Chat tab badge spins; the writer switches back by hand — no auto-switch |
| Upload from the tab fails | Same toasts as the library page |

## 9. Verification

- `tsc --noEmit` and `eslint . --max-warnings=0` in `inkwell-web-1`;
  `node --test` on `ai-corpus-line.check.ts`.
- Browser pass at 1440 and 1280 px: expand ⇄ rail with a run in flight
  (badge shows the step; conversation survives); Chat/Sources switch; attach
  from the Sources tab and see `📎 N` and the tab badge update; upload from
  the tab; composer growing to four lines and scrolling after; Shift+Enter;
  recording swaps only the left slot; a second turn after a write. At 390 px:
  sheet opens with tabs; minimize → pill with the live step.
- Spec repo: `2-features.md` §3.1 rewritten for the docked panel;
  `3-user-flows.md` §5 updated; figures `writer-05`/`writer-06` re-captured;
  `10-requirements.md` FR-81 amended (dock → side panel with rail).

## 10. Out of scope

Drag-resizable split (a follow-up if 400 px proves wrong); per-article panel
state; any change to what the assistant does or how it bills.

## 11. Repos touched

frontend (files in §7) · spec (`2-features.md`, `3-user-flows.md`,
`10-requirements.md`, two figures). No backend change.
