# SplitEasy Developer Guide (read this first, for humans and AI agents)

Offline-first Flutter (Android) expense splitter with UPI proof verification.
No backend, no login, no recurring cost. All data lives in on-device SQLite.

## 1. Folder map

| Path | Purpose | Flutter imports? |
|---|---|---|
| `lib/logic/settle.dart` | Balances, settle-up simplification, split math, strict money parsing | No (pure Dart, unit-testable) |
| `lib/logic/proof_parser.dart` | Regex extraction from OCR text/SMS, member matching, bill totals | No |
| `lib/data/repo.dart` | SQLite schema + all queries + `Repo.changes` notifier | Yes (sqflite) |
| `lib/services/services.dart` | OCR, image downscale + fingerprint, TTS, UPI deep link, PDF, formatters | Yes |
| `lib/ui/*` | Screens: group, add/edit expense, proof, members | Yes |
| `lib/main.dart` | App, Home screen, Share Sheet intake | Yes |
| `test/*_test.dart` | Unit tests for `lib/logic` (`logic_test.dart`, `contact_utils_test.dart`) | |
| `tools/apply_android.py` | Patches the generated `android/` (manifest, R8, signing, minSdk 23) | |
| `.github/workflows/build.yml` | CI: test, build APKs + AAB, upload logs | |

## 2. Rules that must not be broken

1. **Money is integer paise everywhere.** Never store or add doubles. Parse user text only with `parseMoney()` / `parseWeight()` (never `double.parse`).
2. **Balances are always recomputed** from raw rows in `Repo.ledger()`. Never store a running balance. This is why edit/delete cannot leave stale totals.
3. **Every DB write calls `_bump()`** so `Repo.changes` fires and open screens refresh. New write methods must do the same.
4. **Logic stays pure.** Anything testable goes in `lib/logic/` with a test in `test/logic_test.dart`.
5. **Duplicates are blocked twice**: app pre-check and `UNIQUE` columns (`settlement.ref`, `settlement.proof_hash`).
6. **Members are never hard-deleted.** `active=0` hides them but keeps history. Removal is refused while their balance is non-zero.
7. **Schema change = bump `version` in `_open()` and add `onUpgrade` migration** (the app is unreleased at v1, so v1 is still editable; after the first Play release it is not).
8. **PDF text uses `Rs`**, not the rupee symbol (base PDF fonts lack the glyph).
9. No new dependency without a clear reason; keep the APK small.

## 3. Data model (SQLite)

`grp(id,name,kitty)` > `member(id,group_id,name,upi_id,phone,active)` (phone = optional E.164, added in schema v2 via `onUpgrade`)
`expense(id,group_id,title,amount,category,note,split_type,proof_path,date)` with `payer(expense_id,member_id,amount)` (empty = paid from kitty) and `share(expense_id,member_id,amount)`
`settlement(id,group_id,from_id,to_id,amount,ref UNIQUE,proof_hash UNIQUE,method,status,proof_path,note,date)`; status is `verified` (proof + UTR), `unverified` (proof, no UTR) or `manual` (cash/offline)
`topup(id,group_id,member_id,amount,date)` for the kitty pool

Net balance = paid + top-ups + settlements sent - owed - settlements received. Positive = gets money.
Kitty is pseudo-member `kittyId = 0` whose net is the negative of the members' total.

## 4. Proof pipeline

pick / camera / Share Sheet / pasted SMS -> `OcrService.keep` (downscale to 1080x2400, fingerprint) -> `OcrService.read` (ML Kit, on device) -> `ProofParser.parse` -> user confirms -> `Repo.addSettlement` (dup checks) -> `Soundbox.announce`.
Bills: `ProofParser.parseBillTotal` pre-fills the amount, then the normal expense form opens.

## 5. Verification status (14-point checklist)

Legend: **Done** = implemented and unit-tested logic. **Needs device** = implemented, can only be proven after the first build runs on a phone.

| # | Item | Status |
|---|---|---|
| 1 | Groups / members: create, rename, add, edit, remove (history kept) | Done |
| 2 | Add expense: single or multiple payers, equal/exact/percent/shares, sum validation | Done |
| 3 | Edit and delete expense, balances recompute | Done |
| 4 | Minimum-transaction "who pays whom" | Done |
| 5 | Manual cash/offline payment with any amount | Done |
| 6 | Persistence (SQLite, no mock data) | Done; confirm by force-close on device |
| 7 | Input validation (empty names, letters, negatives, multiple dots, zero, Infinity) | Done (unit-tested parsing); UI messages **Needs device** |
| 8 | Build/compile, plugin versions, Gradle | **Needs first CI build** (never compiled yet) |
| 9 | OCR off UI thread, large-image downscale (also Share Sheet images) | Implemented; **Needs device** for memory behaviour |
| 10 | Regex across GPay / PhonePe / Paytm / BHIM, OCR digit confusion | GPay, PhonePe, SMS and synthetic Paytm/BHIM tested; **real Paytm/BHIM screenshots Needs device** |
| 11 | Duplicate prevention: UTR UNIQUE + screenshot fingerprint UNIQUE | Done |
| 12 | Balance math (3000 / 600 partial scenario = B -400, A +1400, C -1000) | Done (unit test) |
| 13 | UI reactivity (`Repo.changes` listeners, including after Share Sheet) | Done; **Needs device** |
| 14 | Share Sheet: cold start, running app, multiple images, text | Implemented; **Needs device** |

When an item is proven on a device, change its status here.

## 6. First-build troubleshooting (most likely failures)

- Dependency solve errors: relax the caret version of the named package in `pubspec.yaml`.
- `receive_sharing_intent` Gradle/namespace error: bump to the newest 1.8.x or newer; keep `launchMode=singleTask` in the manifest.
- `TableHelper` not found in `pdf`: use `pw.Table.fromTextArray` or upgrade `pdf`.
- minSdk errors: `tools/apply_android.py` sets 23; raise if a plugin demands more.
- Always paste the **last 60 lines of `build.log`** (downloaded from the Actions artifact) to the agent.

## 7. Ready-to-use prompts

Paste one of these with the zip/repo attached. Each tells the agent to follow section 2.

**Fix a build error**
> Read docs/DEV_GUIDE.md. The GitHub Actions build failed. Here are the last 60 lines of build.log: <paste>. Find the root cause, fix it with the smallest change, run no new features, and update section 6 if it is a new known issue.

**Add a feature (template)**
> Read docs/DEV_GUIDE.md and follow its rules. Add: <feature>. Put pure logic in lib/logic with unit tests, any DB change in repo.dart with a migration, and refresh UI via Repo.changes. List files changed and update the status table.

**JSON backup and restore**
> Add Export backup (all groups, members, expenses, payers, shares, settlements, topups as one JSON file shared via share_plus) and Import backup (file picker, validate schema version, merge or replace with confirmation). Keep proof images out of the JSON but list their filenames. Add unit tests for the encode/decode round trip.

**Nearby peer-to-peer sync (offline)**
> Add offline sync between two phones using Nearby Connections: advertise/discover, exchange the JSON backup, and merge by record id plus timestamp with conflict rules documented in DEV_GUIDE. Add the required Android permissions to tools/apply_android.py. Show a clear failure state.

**Recurring expenses (rent, subscriptions)**
> Add recurring expenses (weekly/monthly) per group. Generate due entries on app start through a pure function in lib/logic with tests, and let the user pause or delete a rule.

**UPI QR for settle-up**
> On a suggested settle-up row, show a QR code containing the upi://pay link for the receiver and amount, using a small QR package or a pure Dart encoder. No network calls.

**Analytics screen**
> Add a screen with category-wise spend and per-member paid vs owed bars per group, using plain Flutter widgets (no chart package). Logic for aggregates in lib/logic with tests.

**Reminders**
> Add a "Remind" button on settle-up rows that opens a share sheet with a prefilled message including amount and the receiver's UPI link. No background services.

**App lock**
> Add optional biometric/PIN app lock using local_auth, toggled from a settings screen, off by default.

**Localisation (Tamil / Hindi)**
> Move all UI strings to ARB files with flutter_localizations, add ta and hi, and keep number formatting Indian-style via rupees().

**Play Store assets**
> Draft the Play Store listing: short description (80 chars), full description, feature bullets, data safety answers (no data collected), a privacy policy page text for on-device-only data, and a list of screenshots to capture.

**Release hardening**
> Review the release build: R8 rules for ML Kit and plugins, signing config, app icon and name, versionCode bump procedure, and a pre-release checklist run against the status table.

## 8. Release checklist

1. Green CI build, install the per-ABI APK on a phone, tick every "Needs device" row above.
2. Create the keystore, add the 4 secrets, rebuild, keep the keystore backed up.
3. Bump `version:` in `pubspec.yaml` (e.g. `1.0.1+2`) for every upload; Play rejects a repeated versionCode.
4. Upload the `.aab` to a closed test first. Check Play Console for the current testing requirements for new personal accounts before planning dates.
