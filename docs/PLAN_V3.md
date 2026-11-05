# SplitEasy v3 plan: shared groups, settlements, SMS and UPI-share capture

Status: **PROPOSAL for approval.** Only Stage 1 (contact picker) is implemented. Nothing else below is built yet.
Marks: **[verified]** read from an official/primary page during planning. **[unverified]** could not be confirmed here and must be checked or tested on a device.

## Decisions log
5 Nov, from you:
1. **Storage:** use each user's own device storage (offline-first). Open question: is a cloud relay still wanted for cross-phone sync, or phone-to-phone only? Needed before Stage 3.
2. **SMS auto-read:** enabled in the current direct/test build. Implemented in Stage 4. A Play variant without the SMS permission is made before any Play upload; the SMS build must never go to Play.
3. **Sign-in:** existing sign-in first (Google/email); if not available, mobile number + OTP.
4. **Unconfirmed payments count toward balances** with an "unconfirmed" badge. Disputed ones do not.
5. **Stage 1** approved for merge to `main`.
6. **Release signing secrets** added to GitHub.
7. **Working style:** one stage at a time, short steps.

## Revision 2 (after your feedback on 5 Nov)

**Corrections**
- **Nobody installs PostgreSQL.** The database runs in the cloud. Users install only the APK. With Firebase there is no database for you to install or host either, only a project you create once.
- **Receiving an SMS is free for the user; sending one is not for the developer.** An OTP sign-in SMS is sent by Firebase to the user's phone; the user pays nothing, **you** pay per message sent.

**Backend changed to Firebase** (your constraints: free only, sign in with Google, email and phone OTP)
- [verified] Firebase/Identity Platform prices SMS verification in **India at $0.07 per SMS**. The page says "the first ten SMS that you send per day are not billed" (its own example treats 300 per month as free, so the exact quota is unclear; check your billing report). Google, email and phone sign-in are free up to 50,000 monthly users.
- [verified] Phone sign-in is "Not applicable" on the no-card Spark plan. You must switch the project to **Blaze** (card on file). Set a budget alert (for example Rs 100) so a surprise bill cannot happen.
- [verified] Supabase has no SMS of its own: you must bring Twilio, MessageBird, Vonage or Textlocal, and India's TRAI DLT rules apply. Its free projects pause after a week idle. That is why it no longer fits "free only".
- Firestore free quota [verified]: 50K reads, 20K writes, 20K deletes per day, 1 GiB. Offline support is built in. Nothing pauses.
- We keep the sync code behind a `SyncBackend` interface, so a later paid move to Supabase stays possible.

**"Existing sign-in"** is assumed to mean email + password. Tell me if you meant something else.

### Firebase mapping (replaces 2.4 to 2.6 for implementation; the sync principles in 2.2, 2.3 and 2.6 still apply)
- Collections: `groups/{gid}`; `groups/{gid}/members/{uid or inviteMemberId}`; `groups/{gid}/expenses/{eid}` with **payers and shares embedded in the same document** (an edit is one atomic write, so nobody sees a half-edited expense); `groups/{gid}/settlements/{sid}`; `.../topups`; `.../audit`; `invites/{tokenHash}`.
- **Duplicate payments without unique constraints:** Firestore has none, so each UTR gets a lock document `groups/{gid}/utrs/{utr}` created **in the same batch** as the settlement. Security rules allow `create` only if that document does not exist, so a second payment with the same UTR is rejected by the server. Same for screenshot hashes.
- **Safe offline retries:** every record has a client-generated UUID used as the document id and is written with `set()`, so replaying a queued write cannot create a second copy.
- **Rules:** only members read or write group data; no client deletes (soft delete); only an admin changes roles; only the **receiving** member can move a settlement to `confirmed`.
- **Invites without Cloud Functions** (Functions need Blaze and add moving parts): the invite document is readable only by its exact id; redeeming is one batch that creates the member document and marks the invite used, and the rules verify both with `getAfter()`. This is the most intricate rule set; it is tested with the Firebase emulator in CI (rules unit tests).
- **Real time:** Firestore snapshot listeners on my groups write changes into the local SQLite, which refreshes the screens. SQLite stays the source of truth, so the balance maths and all unit tests are unchanged.
- **Cost:** Rs 0 within the quotas. Above 10 OTPs per day, about Rs 6 per SMS (rough, at current exchange rates).

### Pay the remaining amount from inside the app (new Stage 3c)
- A "Pay Rs X to Name" screen with tiles for **Google Pay, PhonePe, Paytm, BHIM and any UPI app**, paying to the member's **UPI ID** (or mobile number, see below).
- It builds a `upi://pay?pa=...&pn=...&am=...&cu=INR&tn=...` link. Targeting one specific app needs its Android package name in the manifest `<queries>` list. [unverified] Package names I expect: `com.google.android.apps.nbu.paisa.user` (Google Pay), `com.phonepe.app` (PhonePe), `net.one97.paytm` (Paytm), `in.org.npci.upiapp` (BHIM). Verify on your phone.
- **Mobile number limitation:** the UPI link needs a UPI ID. A mobile number cannot be pre-filled reliably. For a number-only member the app copies the number, opens the chosen app, and shows the amount in a banner for you to enter.
- Some UPI apps return a status and transaction id to the calling app. [unverified] for payments to personal UPI IDs; Google Pay and PhonePe may restrict third-party intents. Test on your phone. If the app returns "success" we use it only as a hint, never as proof.
- After you return, the app asks "Did you complete the payment?" and moves straight into confirmation below.

### Confirming a payment (replaces the Stage 4 and 5 wording)
Two ways, as you described, with one safeguard: **a screenshot or SMS alone never makes a payment "verified"** (screenshots can be edited).
1. **Share the payment screenshot to SplitEasy.** The app reads amount, UTR, payee and time, checks that you are a member of a group with a **pending payment** to that payee, and shows a confirmation screen. After you confirm, the payment is added as **recorded (matched)** and counts in balances.
2. **Pay from the app, then paste the debit SMS** (or share it from Messages if your Messages app allows it).
- **Verified status:** the receiver confirms with one tap, **or** the receiver's own credit SMS/screenshot carries the **same UTR** as the payer's evidence (two independent sources). Either one makes it verified.

### SMS auto-read: your idea and the Play Store problem
- Technically possible: declare `READ_SMS`/`RECEIVE_SMS`, ask the user in the app, and read bank transaction messages on the phone.
- [verified] Google Play allows these permissions only to the default SMS/Phone/Assistant app, with narrow exceptions where there is "no alternative method". Because sharing and pasting are alternatives, a Play upload declaring SMS permissions would most likely be **rejected**. I cannot predict the outcome of a permissions declaration.
- **Proposed solution, needs your decision:** build **two variants** from the same code. **(A) Play build:** no SMS permission; screenshot sharing and paste. **(B) Direct APK** (shared by link or WhatsApp, outside Play): optional auto-read of transaction SMS from bank senders only, processed on the phone, never uploaded. CI builds both; the Play variant never contains the SMS permission.
- If you only want one build for Play, choose (A).

### Updated stages
| Stage | Scope |
|---|---|
| 1 | Contact picker (done, device test pending) |
| 2 | Signing keystore, UUIDs and timestamps, offline write queue, `SyncBackend` interface, pure merge logic and tests |
| 3a | Local settlement upgrade: methods, date and time, statuses, evidence label, audit fields |
| 3 | Firebase project, security rules and emulator tests, 3 sign-in methods, share group, invites, sync |
| 3c | Pay from app (UPI app tiles) |
| 4 | Share-screenshot capture with pending-payment matching, paste/share SMS, optional direct-APK SMS auto-read |
| 5 | Diagnostic panel for what each UPI app shares, then parser tuning from your real samples |
| 6 | Proof image sync (Firebase Storage pricing to check) and the 15-scenario device checklist |

## 0. Decisions needed from you

| # | Decision | Recommendation |
|---|---|---|
| 1 | Backend | **Firebase (Auth + Firestore)**. Changed from Supabase after your free-only + phone-OTP requirement. See Revision 2 |
| 2 | Sign-in | **Google + email/password + phone OTP** (your requirement). Phone OTP needs the Firebase Blaze plan (card on file, budget alert) |
| 3 | Budget | **Free version now**, paid later. Expected cost: Rs 0 while within the free quotas |
| 4 | Who creates the cloud project | You (about 10 minutes, steps in Revision 2). I cannot reach your cloud accounts |
| 5 | Signing | Create the keystore + 4 GitHub secrets **before Stage 2**, so new builds install over old ones (see section 7) |
| 6 | Unconfirmed payments | Default proposed: they **count** in balances with an "unconfirmed" badge; **disputed** ones do not count until resolved |

## 1. Android and Play constraints (researched)

- **Contacts:** Android's own contact picker returns only the contact the user taps, so no `READ_CONTACTS` permission is needed. Implemented in Stage 1.
- **SMS inbox picker is not compliant for this app.** [verified] Google Play restricts SMS permissions (`READ_SMS` etc.) to apps that are the default SMS/Phone/Assistant handler. A non-default app may get a temporary exception only if the feature is a listed core function and "there's currently no alternative method". SplitEasy has alternatives (share, paste, screenshot), so it would be rejected. **We will not declare SMS permissions.**
- The SMS User Consent API [verified] gives access to a single SMS but is documented for verification flows and waits for an incoming message. It is not an inbox picker, so it is not used.
- **Compliant SMS options (Stage 4):** share the message from the Messages app into SplitEasy; one-tap paste with clipboard detection (existing Paste SMS stays); SMS screenshot through Gallery/OCR (existing).
  [unverified] whether the Messages app on your iQOO exposes a Share action for a single message. Needs a test on your phone.
- **Share Intent:** `ACTION_SEND` / `ACTION_SEND_MULTIPLE` for `text/plain` and `image/*` already work through `receive_sharing_intent`. We only receive what the other app chooses to share.
  - PhonePe [verified]: History > Share, "email or any other available option". The help page does not say whether the shared item is an image, PDF, text or link. [unverified] Google Pay, Paytm, BHIM formats.
  - PDF or link shares are **not** handled today.

## 2. Shared groups

### 2.1 Backend comparison (SUPERSEDED by Revision 2: Firebase is now recommended; the Postgres schema in 2.4 applies only if we move to Supabase later)

| | Supabase | Firebase |
|---|---|---|
| Free tier [verified] | 50K auth MAU, 500 MB DB, 2M realtime messages/month, 200 realtime connections, **project paused after 1 week of inactivity**, 2 active projects | Spark: Firestore 50K reads and 20K writes/day, 1 GiB, 50K auth MAU. **Phone Auth is "Not applicable" on Spark**, needs Blaze (pay per SMS) |
| Paid [verified] | Pro $25/month: 8 GB DB, 100K MAU, 500 realtime connections, never paused | Blaze pay-as-you-go. India per-SMS rate not on the pricing page [unverified] |
| Data model | Relational. UNIQUE constraints, foreign keys, SQL | Documents. No unique constraints or joins |
| Authorization | Row Level Security in SQL | Security rules language |
| Offline | Not built in (we build it) | Built in, but our balance logic and unit tests need the local SQLite anyway |

Why Supabase: our data is relational; duplicate protection across members needs a **server-enforced UNIQUE(group, UTR)**, which Postgres does natively; RLS expresses "only members of this group" in a few SQL lines; and it is SQL, which is easy for you to maintain and audit. Trade-off: the free tier pauses when idle, so use Pro before real users. Firebase is the cheaper choice at tiny scale, but the unique-constraint gap and SMS-auth billing make it a worse fit.

### 2.2 Local-first design (keeps all existing logic and tests)

- On-device SQLite stays the source of truth for the UI. Balances are still computed by `computeNet()` locally, so the ₹3,000 / ₹600 tests and all unit tests are untouched.
- Every write goes to local tables **and** an `outbox` table. A sync engine pushes the outbox and pulls changes.
- Groups stay **local-only** until you tap "Share this group". Existing groups keep working offline.

### 2.3 Identity

Every record gets a client-generated **UUID** (`uid`): group, member, expense, payer, share, settlement, top-up. Existing rows get UUIDs in a migration (local integer ids stay for the UI). Every synced table also gets `updated_at`, `deleted_at` (soft delete; tombstones sync), `version`.

### 2.4 Cloud schema (Postgres, sketch)

```sql
profiles(id uuid pk references auth.users, display_name, phone, created_at)
groups(id uuid pk, name, kitty bool, created_by, created_at, updated_at, deleted_at)
group_members(id uuid pk, group_id, user_id null, display_name, phone, upi_id,
              role check in ('admin','member'), status check in ('invited','active','removed'),
              unique(group_id, user_id), unique(group_id, phone))
invites(token_hash pk, group_id, member_id, expires_at, redeemed_by, redeemed_at)
expenses(id uuid pk, group_id, title, amount_paise bigint check > 0, category, note, split_type,
         spent_at, created_by, created_at, updated_at, deleted_at, version)
expense_payers(expense_id, member_id, amount_paise, pk(expense_id, member_id))
expense_shares(expense_id, member_id, amount_paise, pk(expense_id, member_id))
settlements(id uuid pk, group_id, from_member, to_member, amount_paise check > 0,
            method check in ('upi','cash','bank','other'), upi_app, paid_at,
            utr, proof_path, proof_hash,
            status check in ('recorded','confirmed','disputed'),
            recorded_by, confirmed_by, confirmed_at, created_at, updated_at, deleted_at,
            unique(group_id, utr) where utr is not null,
            unique(group_id, proof_hash) where proof_hash is not null)
topups(id uuid pk, group_id, member_id, amount_paise, created_at, ...)
audit_log(id bigint identity pk, group_id, actor, action, entity, entity_id, at, detail jsonb)
applied_ops(op_id uuid pk)           -- replay protection
```

Every synced table also has `server_seq bigint` filled by a trigger from one global sequence. It is the pull cursor.

**Row Level Security**
- `is_group_member(gid)` (security definer): the caller has an `active` membership.
- SELECT, INSERT and UPDATE on group data require `is_group_member(group_id)`. **No hard DELETE** for clients.
- Only an `admin` can change roles or remove members.
- A settlement moves `recorded -> confirmed | disputed` only when `auth.uid()` is the **receiving** member's user. The payer cannot confirm their own payment.
- `redeem_invite(token)` is an RPC; clients cannot write `group_members.user_id` directly.
- Tests: SQL tests (pgTAP-style) run in CI against a local Postgres.

### 2.5 Authentication and invitation flow

1. User signs in with **Google** (Supabase Auth). A `profiles` row is created.
2. Admin adds a member (contact picker gives name and mobile) and taps **Invite**.
3. The app creates a random single-use token (the server stores only its hash, expires in 7 days) and opens the **Android share sheet** with a ready message and link/code, addressed to that mobile via WhatsApp or the SMS app. The user taps send. **No SMS is sent by our servers: no SMS cost, no SMS permission.**
4. The invitee installs the app, signs in with Google, opens the link or pastes the invite code, and `redeem_invite` links their account to the member slot and activates it.
5. They now see the group, because RLS lets active members read it.

Notes: the token is a capability (anyone holding it can join once), so it is single-use and expiring, and the admin can revoke it. Binding the invite to a verified phone number needs phone OTP, which we defer. [unverified] Verified App Links need a domain; the first version uses a custom scheme plus a pasteable code.

### 2.6 Synchronization design

- **Push:** the outbox (`op_id`, table, uid, op, JSON payload, created_at) is sent in order to an `apply_ops(jsonb)` function. Each op is applied with `insert ... on conflict (id) do update where excluded.updated_at > current.updated_at`, and its `op_id` is recorded in `applied_ops`, so **a retry can never create a duplicate**.
- **Duplicate payments:** the UNIQUE `(group_id, utr)` and `(group_id, proof_hash)` indexes reject a repeat. The server answers "duplicate"; the client marks the local row as duplicate and tells the user instead of retrying forever. Payments with no UTR also get a soft warning when the same payer, receiver and amount appear within 10 minutes.
- **Pull:** per-group cursor on `server_seq`, with a small overlap window (re-pulling is harmless because writes are idempotent).
- **Near-real-time:** a Supabase Realtime subscription filtered to my groups triggers an immediate pull. Fallbacks: pull on app resume and every few minutes.
- **Conflicts:** last-writer-wins per row (`updated_at`, then device id). Exceptions: deletes win (tombstones), and settlement status follows the state machine above. An expense edit replaces the expense, its payers and its shares as **one op**, so nobody sees a half-edited expense.
- **Offline:** everything works offline; the outbox flushes when connectivity returns, with backoff. The UI shows "n changes pending" and "last synced".
- **Balances:** computed locally from the same synced rows, so every phone shows the same numbers once synced.

### 2.7 Cost estimate

| Phase | Monthly | Notes |
|---|---|---|
| Development and closed test | $0 | Supabase free tier. Risk: paused after 1 week idle |
| Launch | **$25** (Supabase Pro) | Covers 100K auth MAU and 8 GB. Our rows are small (about 1 KB per expense) |
| Google Sign-In | $0 | |
| Phone OTP (optional, later) | per-SMS fee + India DLT registration | [unverified] rates |
| Proof image storage | [unverified] | Plan: compress to about 200 KB and keep in a private bucket behind RLS. Check storage pricing when we reach Stage 6 |

### 2.8 Privacy

Names, mobile numbers and payment records will now leave the phone. Required: updated privacy policy, Play **Data safety** form changed from "no data collected", clear consent text, and data deletion on request (account deletion path is a Play requirement). Invitee numbers should be stored only where needed. Recommend a legal review before a wide release (India's DPDP Act applies to personal data).

### 2.9 Cloud setup steps for you (when approved)

1. Create a Supabase account and a project (region: Mumbai if offered).
2. Auth > Providers: enable Google; add the Android OAuth client (SHA-1 of the release key).
3. I will give you one SQL migration file to paste in the SQL editor (tables, RLS, functions).
4. Send me the **project URL and the anon (public) key only**. Never share the `service_role` key.

## 3. Settlements (Stage 3)

- **Methods:** UPI (with app: Google Pay, PhonePe, Paytm, BHIM, other), Cash, Bank transfer, Other.
- **Captured:** amount, date and time (default now, editable), optional UTR, optional image, optional note.
- **Status:** `recorded` -> `confirmed` (only by the receiver) or `disputed`. Attaching a UTR or screenshot **never** sets "confirmed". It only shows an "evidence attached" label.
- **Existing behaviour to change:** v1 currently saves `status = verified` when a UTR and proof are present. That contradicts your rule, so the first change in Stage 3 renames it to "evidence attached" and migrates existing rows.
- **Audit trail:** `recorded_by`, `recorded_at`, `confirmed_by`, `confirmed_at` plus `audit_log`; a payment detail screen lists the events.
- **History list:** shows method and status on every row. Partial payments keep working unchanged.
- **Split:** 3a (local: methods, editable date/time, statuses, labels) can ship before the cloud; 3b adds sync and confirmation by the receiver.

## 4. SMS capture (Stage 4)

- Share-from-Messages and one-tap paste with clipboard detection, parsed on the phone. Raw text is **discarded after you confirm**; only parsed fields are saved.
- Parser extends to bank SMS formats ("debited by", "credited", "Ref No", "UPI/…/…"), sender header classification, status words (success, failed, declined, reversed), and ignores balance text.
- Confirm/edit screen, then choose group and member. Unrelated messages are never read, stored or uploaded.
- Needs real (redacted) samples from you to tune: HDFC, SBI, ICICI, Axis, Kotak, etc.

## 5. UPI share capture (Stage 5)

1. **5a diagnostic build:** when you share from Google Pay, PhonePe, Paytm or BHIM, a developer panel shows what actually arrived (type, size, text snippet, OCR text) with a copy button. You do this once per app and send me redacted samples.
2. **5b parsers:** tuned from those real samples. Detects amount, UTR, recipient (UPI ID / name / phone), date and time, and the source app from text patterns (Android does not reliably tell us the sending app).
3. Suggests group and member, and matches the amount to the outstanding suggested transfer. Always shows a confirmation screen; status stays `recorded`.
4. Fallback screen for manual confirmation when an app shares nothing useful. Gallery, Camera and Paste SMS stay.
5. Known gap: PDF or link receipts need extra work.

## 6. Stages, tests and release rule

| Stage | Scope | Tests |
|---|---|---|
| 1 (done) | Contact picker, `member.phone`, schema v2 | Analyze, unit tests (phone normalisation), CI build. **Device test pending** |
| 2 | Signing keystore; UUID and timestamp migration; outbox tables; pure sync-merge logic | Unit tests for merge, dedupe, ordering, idempotent replay |
| 3a | Local settlement upgrade | Unit tests; all old tests unchanged |
| 3 | Supabase project, SQL + RLS, Google sign-in, share group, invites, push/pull, realtime | SQL/RLS tests; sync unit tests; device checks |
| 4 | SMS share/paste capture | Parser unit tests on samples |
| 5 | UPI share diagnostic then parsers | Parser tests; device checks |
| 6 | Proof images sync; full review | 15-scenario checklist on 2+ phones |

Every stage: its own branch, CI (analyze, all unit tests, **ARM64 APK + AAB uploaded as artifacts**), a summary (features, files, DB changes, backend needs, security, test results, limitations), your OK, then merge to `main`. A feature is marked complete only after it is implemented **and** tested. Multi-device scenarios (invites on different phones, real-time sync, offline then reconnect) need real phones and the live cloud project. I can run unit tests, SQL tests and the CI build, but I cannot run those end to end myself.

## 7. Risks and limitations

- Nothing can be compiled locally; verification is through GitHub Actions.
- **Update-in-place:** CI builds use a debug signing key created fresh on each runner, so a new APK may refuse to install over the old one ("signature mismatch"). You would have to uninstall first, which deletes local data. Fix: the keystore secrets (decision 5).
- Free-tier pausing; unverified storage and India SMS pricing.
- `system_contact_picker` is a new, low-adoption package (version 0.0.4). If it misbehaves on your phone, manual entry still works, and the fallback is a small custom platform channel.
- Realtime is "near real time". Delivery depends on connectivity and Android background limits.
