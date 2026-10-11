# Pluck

A macOS app (SwiftUI) for downloading videos and music, in two editions built from one codebase:
Pluck (basic) and Pluck Studio (everything; `PLUCK_EDITION`, see Package.swift and Edition.swift).

- **Design:** every window follows `DESIGN.md`. Use the shared pieces in
  `Sources/Pluck/DesignTokens.swift` (ToolPage, Card, CardHeader, StatusChip, InputBar, ItemRow,
  RowButton, the button styles) for every page, including new features.
- **Studio-only code** lives in `Sources/Pluck/{AI,Edit,Remote,Studio}` and is left out of basic
  Pluck; shared files guard Studio parts with `#if STUDIO`.
- **Strings:** run `scripts/update-strings.sh`, then translate new keys into de, es, fr, it, ja, ko,
  nl, pt-BR and zh-Hans.
- **Building and releasing:** `scripts/build-app.sh [--edition basic]`, `scripts/release.sh`.
