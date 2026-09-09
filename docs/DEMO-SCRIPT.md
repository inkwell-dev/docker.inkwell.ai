# Demo script — ten minutes

One article's journey, from a writer's draft to a magazine's masthead. That
journey *is* the product's argument, and it is the only path that touches every
subsystem: AI-assisted writing, hybrid search, the credit ledger, exclusivity,
and publication.

Everything else is a detour. If you are short on time, cut §6 and §7 first —
they are the least surprising parts.

---

## Before you start

Run these. Do not skip them; three of the four have bitten a run.

```bash
docker ps                       # seven containers, all Up
make dci-migrate                # no-op if current, but proves the schema matches
```

**Check the demo magazine can still afford to buy something on camera.** It
spends real credits and they do not come back:

```bash
docker exec inkwell-db-1 psql -U inkwell -d inkwell -t -A -F' | ' -c \
"SELECT mp.credit_balance,
        (SELECT count(*) FROM articles a
          WHERE a.placement='marketplace' AND a.status='published'
            AND a.deleted_at IS NULL
            AND a.marketplace_price <= mp.credit_balance
            AND NOT EXISTS (SELECT 1 FROM article_purchases p
                             WHERE p.article_id=a.id AND p.stage='full_purchase'))
   FROM magazine_profiles mp WHERE mp.slug='the-longform-review';"
```

If the balance is low or nothing is affordable, reseed — **with the preset, or
you get a four-article corpus**:

```bash
make dci-seed SEED_ARGS="--preset=full"
```

Reseeding regenerates identical row ids (they derive from a fixed seed), so any
browser session you already have stays signed in.

**Open two browser profiles before you start**, signed in and parked on the
right pages. Switching accounts live costs thirty seconds of dead air each time,
and the login form is not part of the story.

| Window | Account | Parked on |
|---|---|---|
| A | a writer — e.g. `chauncey-wiza@example.com` | their own profile |
| B | the magazine — `the-longform-review` | `/marketplace` |

Passwords for every seeded account are in
`.claude/skills/inkwell-ticket/references/environment.md`.

---

## 1 · The problem, in one screen — 45s

Open the **home feed** signed out, in a private window.

> "Independent writers publish into a void, and magazines commission by
> reputation because they have no way to evaluate the work. Inkwell is a
> marketplace between them, and everything you are about to see exists to make
> one transaction trustworthy: a magazine licensing an article from a writer it
> has never met."

Do not linger. The feed is the least interesting screen in the product.

## 2 · Writing, with the AI that knows your work — 2m

Window A. Open the editor on an existing draft rather than a blank one — a blank
editor demos nothing and costs you thirty seconds of typing.

1. **Inline actions.** Select a paragraph → *reformulate* / *shorten* /
   *expand*. Say what is happening underneath while it streams:

   > "This is not a generic completion. Each request carries a retrieved slice
   > of this writer's own published work, so the suggestion sounds like them and
   > not like a model."

2. **Chat.** Ask something that requires knowing their corpus — *"what have I
   already argued about parking minimums?"* — and let it cite.

3. **The quota.** Point at the token counter. One sentence:

   > "Every account has a daily allowance, reset by a background job. The
   > guard runs before the model call, not after, so an exhausted account costs
   > nothing."

**If a model call fails or hangs**, do not retry on camera. Say *"there is a
liveness check that fails over between providers, and I will show the
architecture for it in a moment"* and move on. §8 covers it properly.

## 3 · Publishing, and the choice that matters — 1m

Still window A. Publish, and stop on the placement dialog.

> "Public, or marketplace. This is the fork the whole product turns on. Public
> means readers. Marketplace means the article is not readable by anyone — it
> is inventory, and only subscribing magazines can even see it exists."

Show that the marketplace listing is **absent from the writer's own public
profile** for a visitor, and present for the author. One sentence:

> "A listing is a private commercial offer. Until somebody buys it, it is not
> part of the writer's public shelf — and it carries no comments, no likes and
> no reposts, because those are all forms of publication."

## 4 · Evaluating a writer — 1m 30s

Window B, the magazine. Go to **Find writers**, open the writer from §2.

- The evaluation panel: unique readers, engagement, cadence, quality signals.
- **Portfolio Insights** — the AI-generated report. Let it read for a beat.

> "This is the decision-support layer, and it is the reason the analytics exist
> at all. A magazine is about to spend real money on someone it has never
> commissioned."

Then the **Available to license** panel underneath.

## 5 · The transaction — 2m · *the centrepiece*

The only part you must not rush.

1. **Preview** an article. Watch the credit balance drop by 10%.

   > "Ten percent buys the right to read it. Not to publish it — to read it, so
   > the decision is informed rather than blind."

2. **Purchase** the remainder. Balance drops by the other 90%.

   > "The writer is paid immediately, minus the platform fee, and every credit
   > movement here is a double-entry ledger row. There is an invariant check
   > that recomputes every balance from its transactions; it runs in the test
   > suite and as a background job."

3. **Show that it is now exclusive.** Go back to the marketplace browse — the
   article is **gone**. Not greyed out. Gone.

   > "One buyer. The listing leaves the market the moment it sells, so no second
   > magazine can spend credits discovering it is already taken."

## 6 · The library, and the act that publishes — 1m 30s

**Your Library** → two tabs, **Unpublished** and **Published**.

> "Buying does not publish. The article sits here until an editor decides it
> runs — which is what a magazine actually does. Buying and publishing are
> different decisions, so they are different actions."

Hit **Publish**. Read the dialog aloud — it is doing real work:

> "It becomes publicly readable by everyone including signed-out visitors, and
> there is no un-publish."

Confirm. The row moves tabs.

## 7 · Where it lands — 1m

Three surfaces, quickly, and the point lands on its own:

1. **The magazine's public profile** — the article is on its shelf.
2. **The writer's profile** — it is *back*, now reading *writer* **in**
   *publication*.
3. **The article itself, in a private window** — readable with no account.

> "One column records who published it, and every surface that shows an article
> shows the pairing. The writer keeps the credit; the magazine gets the
> masthead."

## 8 · What is underneath — 45s

No clicking. One architecture slide, three claims:

- **Hybrid retrieval.** Postgres full-text and pgvector, fused with reciprocal
  rank fusion — lexical alone misses paraphrase, vector alone misses names.
- **Model liveness.** Providers are probed on a schedule and requests fail over,
  so a dead provider degrades rather than breaks.
- **The ledger.** Balances are never the source of truth; transactions are, and
  an invariant asserts the two agree.

## 9 · Close — 30s

> "Four rules make the marketplace trustworthy: a listing is private until it
> sells, one buyer only, publication is a deliberate act, and the credit is
> shared. Each one was a separate change, and each shipped with the tests that
> prove it."

---

## If something breaks

**Have a fallback for each beat.** The demo is a live system.

| If | Do |
|---|---|
| A model call hangs | Do not retry. Move to §3; cover the AI in §8 instead |
| `/library` bounces you to the login page | Load any other page first, then return — the access token refreshes on the next API call and the proxy cookie comes back with it. This is a known split between the token in storage and the cookie the proxy reads |
| A purchase is refused | Check the balance. Credits are spent for real and do not reset |
| The magazine profile looks empty | You are on a magazine that has published nothing. Use `the-longform-review` |

**Reseeding mid-demo is a last resort** — it takes minutes and rewrites the
corpus. Prefer moving on.

---

## Do not click these

Not defects to hide — things with nothing behind them yet, which will cost you
credibility if an examiner sees them and asks.

- **The `Writers` tab** on a magazine profile. Placeholder names; there is no
  contributor endpoint.
- **Anything about *when* a magazine published something.** Nothing records it —
  a licensed article sorts by the writer's original date, so an old essay
  licensed today appears far down the magazine's shelf. If asked: it needs a
  column that was deliberately not added, and the honest reason is that the
  alternative decays.
- **Token top-up.** Not implemented, deliberately — the daily allowance job
  would erase topped-up tokens at midnight. Magazine *credit* top-up is a
  different thing and does work.
- **Admin article management.** Removed from scope; moderation acts through the
  reports queue.

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
