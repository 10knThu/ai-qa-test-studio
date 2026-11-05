# AI QA Test Studio (native macOS, SwiftUI)

GitHub Issue (read-only) → local AI (Ollama) → test plan → xcodebuild → Simulator → Appium XCUITest → local results/report.

## Run
- Xcode: open `Package.swift`, choose the `AIQATestStudio` scheme, *My Mac*, Run.
- Terminal: `swift run` or `Scripts/make_app.sh` (creates `build/AI QA Test Studio.app`).
- Tests: `swift test` (set `AIQA_TEST_PROJECT=/path/to/ios/source` to also test project/scheme discovery).

## Prerequisites (nothing is installed automatically; Settings ▸ "Check dependencies" shows what is missing)
- Xcode + iOS Simulator runtime
- Ollama with a model: `ollama pull qwen2.5:7b-instruct` (or `qwen2.5:3b-instruct` on low-RAM Macs)
- Appium: `npm i -g appium && appium driver install xcuitest`, then `appium --port 4723`

## Verify Phase 2 (no GitHub / AI needed)
1. Source Project ▸ Select Source Folder → workspace/project, schemes, configurations and bundle id appear.
2. Pick the Simulator (default iPhone 17 Pro, iOS 26.2) ▸ **Build & Run**.
3. Build log streams live; then the Simulator opens in its own window, the app installs and launches.
   Each stage shows its real status; Cancel stops xcodebuild.

## Safety
GitHub is GET-only. Token lives in the Keychain. Ticket text is passed to the model as data and the output must
decode into the fixed action schema. The source project is never modified (DerivedData is under
`~/Library/Application Support/AIQATestStudio`).
