# SplitEasy

Offline-first expense splitter (Flutter, Android). No server, no login, ₹0/month to run.

## Features
- Groups, members (with UPI IDs), equal / exact / percent / share splits, categories, notes
- Balances with minimum-transaction settle-up suggestions
- **Proof upload**: payment screenshot (GPay, PhonePe, Paytm), pasted bank/UPI SMS, or bill photo
  - On-device OCR (ML Kit), extracts amount, UTR, UPI ID, date and direction
  - Auto-matches the receiver by UPI ID or name, with a manual selector fallback
  - Duplicate protection: UTR column is `UNIQUE` in SQLite, plus a pre-check
  - Verified vs unverified status on every payment
  - Bill photos pre-fill the expense total (grand total preferred over subtotal)
- Android Share Sheet target: share a screenshot or SMS text straight into the app
- Partial payments and advance overpayments handled by the ledger
- Trip kitty pool (members top up, expenses draw from it first)
- "Pay via UPI" deep link, spoken + sound confirmation, PDF ledger export

## Build (no local toolchain needed)
1. Push this folder to a new GitHub repo (branch `main`).
2. Actions tab -> "Build SplitEasy" -> Run workflow. Download the `spliteasy-release` artifact.
3. For a Play-Store-signed build, create a keystore once and add repo secrets:
   `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.

```
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
base64 -w0 upload-keystore.jks    # paste into KEYSTORE_BASE64
```

Local build (optional): `flutter create --org com.karthik --project-name spliteasy --platforms android . && python3 tools/apply_android.py && flutter build appbundle`

## Play Store checklist
- Upload the `.aab` (Play requires AAB for new apps)
- Privacy policy URL (data stays on device; camera/gallery used only for proofs)
- Data safety form: "no data collected or shared"
- New personal developer accounts must run a closed test (12 testers, 14 days) before production access
- Keep the keystore backed up; enroll in Play App Signing

## Not in v1
- Nearby Connections peer-to-peer sync (planned: JSON export/import first)
- Cloud sync / multi-device live balances
