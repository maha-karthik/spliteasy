# SplitEasy

Flutter (Android only) offline expense splitter with UPI proof OCR. Read `docs/DEV_GUIDE.md` before changing anything.

Non-negotiables: money is integer paise (use `parseMoney`); balances are recomputed in `Repo.ledger()`; every DB write bumps `Repo.changes`; pure logic lives in `lib/logic` with tests in `test/logic_test.dart`; members are archived, never hard-deleted.

Commands: `flutter pub get`, `flutter test`, `flutter analyze`. CI builds APK/AAB (`.github/workflows/build.yml`). No Flutter SDK may be available locally; when it is not, say that nothing was compiled.

Token-saving: read only the files the task touches, make the smallest change, do not re-explain unchanged code.
- When a stage is added or changes status, regenerate docs/blueprint (GIF + flowchart) in the same commit.
