# Demo script — a three-minute recording

The defence plays a recorded video, not a live demo. It follows one writer,
Nadia Belhaj, through both sides of the product: she writes with the assistant,
then a magazine evaluates her and licenses one of her articles. The narration is
given live during the defence, so the video carries no sound.

| Part | What it shows | Time |
|---|---|---|
| 1 · The writer | the assistant writes into the draft, grounded in her work; Keep | ~1m 15s |
| 2 · The magazine | evaluation, portfolio insights, preview, purchase, exclusivity | ~1m 45s |

---

## Before you record

**1. The stack is up, and port 80 is free.** If the host's own nginx holds
port 80, the inkwell nginx container starts without its ports; recreate it:

```bash
sudo systemctl stop nginx
docker compose -f .infra/compose/docker-compose.dev.yml --env-file .env \
  up -d --force-recreate --no-deps nginx
```

**2. Reset the data** (also between takes — every take spends real credits):

```bash
../demo-snapshots/reset.sh
```

It restores `ready-to-record.dump`: The Longform Review at 1,738 credits,
*Keeping One Fish* unsold, Nadia's draft untouched, her tokens at 20,000 and her
style profile in place. That snapshot also has the seeded reading events moved
forward to end on the recording day, so her audience card shows readers rather
than 0 (the seed ends on 31 July, and the card counts the last 30 days).
Close the editor tab before a reset and reload after: an open editor autosaves
its old content over the restored draft.

**3. Two Chrome profiles, signed in and parked.**

| Window | Account | Parked on |
|---|---|---|
| A | `nadia@example.com` | `/editor/9c984b16-a6b1-51db-93e9-f161b10cb29a` (*Against the Tackle Industry*), assistant panel open |
| B | `editors@longformreview.example.com` | `/discover/writers/nadia-belhaj`, scrolled to the top |

Passwords: `.claude/skills/inkwell-ticket/references/environment.md`.

**4. Clean the frame.**

- Close the red **"1 Issue"** badge (bottom left) with its ✕ in both windows.
  It is a hydration warning caused by a browser extension writing
  `bis_skin_checked` into the page, not an application error. Recording in a
  profile without that extension removes it for good.
- Disable **Grammarly** for the site: its icons sit inside the editor.
- Full screen (F11), bookmarks bar hidden, browser zoom 100%, light theme.
- Copy the assistant prompt of step 1.3 to the clipboard: pasting it reads
  better on screen than typing it.

**5. Record** at 1920×1080, 30 fps (OBS: *Display capture*). The deck accepts a
video of 20 MB at most; record at normal quality and compress afterwards.

---

## 1 · The writer — ~1m 15s (window A)

1. **Hold on the editor** for 3 seconds: the draft, and the assistant panel
   reading *"I draw on your 5 published articles"*.
2. **Finish the broken sentence by hand.** Click at the very end of the
   paragraph that stops at *"… refusing to go out unless four"* and type
   ` conditions line up at once.`
   This also puts the cursor where the assistant will write: a write is
   inserted after the paragraph holding the cursor. With the cursor anywhere
   else, the paragraph lands in the wrong place.
3. **Ask the assistant** — paste, then Enter:

   > Write a short closing paragraph that ties this back to the fish being closer than I think.

4. **Let the steps run** (~10 s): words read, *style profile loaded*, passages
   from her articles, words written. Do not move the mouse.
5. **The paragraph appears highlighted** below the one you finished, with
   **Keep** and **Discard**. Hold 2 seconds, then click **Keep**.
6. Hold 2 seconds on the result. Cut to window B.

## 2 · The magazine — ~1m 45s (window B)

1. **The evaluation page**, top: *Marketplace eligible*, then Audience, Quality
   and Content. Scroll slowly; about 10 seconds.
2. **Portfolio insights → Generate insights.** It answers in under 10 seconds.
   Scroll through Voice, Subject expertise, Voice consistency and Commission
   ideas; about 15 seconds.
3. **Available to license → *Keeping One Fish* → Preview · 7.** The dialog
   shows *7 credits, balance 1738 → 1731*. Hold 2 seconds, **Confirm**.
4. The card now reads **PREVIEWED** and its button **Buy · 69**. Optional,
   15 seconds: click the title to show the article is now readable, then
   go back.
5. **Buy · 69.** The dialog is the two-stage purchase in one view: *price 76,
   already paid at preview −7, you pay now 69, balance 1731 → 1662*. Hold
   3 seconds, **Confirm**.
6. **The card disappears** from *Available to license*: one buyer only. The top
   bar reads 1,662. Hold 3 seconds. End of the recording.

---

## If a take goes wrong

| If | Do |
|---|---|
| The write lands after the wrong paragraph | Discard, click at the end of the right paragraph, ask again |
| The steps say *no profile yet* | The snapshot was not restored; run `reset.sh` |
| The audience card shows 0 readers | Same: the reset was skipped, or the snapshot is older than this file |
| A model call hangs | Stop, run `reset.sh`, take again |
| Anything else | `reset.sh` and start the take over: it takes under a minute |

## After recording

Send the file over for compression under 20 MB and a still frame; both are
uploaded to slide 25 of the deck.

---

## Questions you should expect

- *"What stops two magazines buying the same article?"* — A row lock plus a
  single ownership rule at the only place credits move. Worth knowing: the
  obvious lock-free version is not atomic under Postgres' default isolation,
  because a sub-select in an `UPDATE` re-reads the statement's original
  snapshot. It was reproduced with two connections before the lock went in.
- *"What happens to a magazine that previewed and then lost the article?"* — It
  keeps the read forever and is refused the purchase. No refund: the preview fee
  bought reading access, and it still has it.
- *"How do you know the ledger is right?"* — Balances are recomputed from
  transactions and asserted. The check is in the test suite, and the negative
  tests corrupt a row deliberately to prove the check fires.
