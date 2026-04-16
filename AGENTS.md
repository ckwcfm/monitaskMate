# AGENTS.md

## Fast facts
- This is a single-target macOS SwiftUI menu bar app (`MonitaskMate`) with source in `Sources/MonitaskMate`.
- Primary entrypoint is `Sources/MonitaskMate/MonitaskMateApp.swift`; UI/state wiring is centered in `TrackingViewModel`.
- Monitask data access is read-only and local-file based (`~/Library/Application Support/Monitask/...`) in `MonitaskReader`.

## Source of truth and project generation
- Treat `project.yml` as the editable project config; `MonitaskMate.xcodeproj` is generated output.
- After changing target structure/versioning or adding new source files, run `xcodegen generate` to sync the Xcode project.
- Release version lives in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), not in `Package.swift`.

## Build and verification commands
- Preferred verification command: `xcodebuild -project "MonitaskMate.xcodeproj" -scheme "MonitaskMate" -configuration Debug -destination 'platform=macOS' build`.
- Do not rely on `xcodebuild ... test`: current shared scheme has no test action configured and errors out.
- `swift test` is currently not a reliable gate: it compiles with Swift 6.3 package settings and currently fails on concurrency-safety errors in `MonitaskControlService`.

## Runtime/dev gotchas
- App behavior depends on local Monitask install and files; many flows are not meaningfully testable without Monitask data on the same Mac.
- Reminder notifications (`ReminderManager`) only request permissions when running as a real `.app` bundle.
- Tracking toggle automation (`MonitaskControlService`) depends on macOS Accessibility permission and Monitask UI automation state.
