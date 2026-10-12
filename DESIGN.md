# Pluck's design language

Every window looks and feels like the main window: glass bars at one height, cards with the
download rows' fill, round glass buttons, short words. New features follow this from the start.
The pieces live in `Sources/Pluck/DesignTokens.swift`; use them instead of building your own.

## Tokens

Sizes, spacing, radii and type come from `Design` (`Design.Size.control`, `Design.Spacing.window`,
`Design.Radius.card`, `Design.Typography.control`…). No loose numbers in views.

## Three kinds of window

- **Tool pages** (Brand Pack, Logo Animator, Delivery Check, Fit Music, Edit Anywhere): one
  thing in, one thing out. A scrolling page of cards, described below.
- **Workspaces** (Live Recorder, Derush, Find Shots): a bar on top, panes side by side, a footer
  with the status on the left and the actions on the right. Panes are `Pane { List … }`, with a
  `PaneSearchField` on top when they can be searched. Before there's anything to show, the panes
  make way for a `ToolWelcome` and a `DropZone`.
- **Browsers** (Library): a macOS sidebar (`NavigationSplitView`), search and sort in the toolbar,
  a grid of cards.
- **The Editor** (one video or song): the picture on black at the top, the transport (round
  `BarButtonStyle` buttons, the play button prominent, a frame-accurate timecode), the timeline
  (`EditorTimeline`: ruler, filmstrip, waveform, the range in yellow with the rest dimmed, a red
  playhead) and an export bar at the bottom. Keys work like an editing program: Space, J K L,
  ← →, I and O. Tools that work on part of a file belong in it, not in a sheet.

## A tool page

- **Window:** `.windowToolbarStyle(.unified)`, the title in the title bar. No big header in the
  content (`SheetHeader` is for sheets only).
- **Modes** (Render / Search, Use Another Mac / Share This Mac): a segmented `Picker` in the toolbar's
  `.principal` slot, or under the welcome when it belongs to the content.
- **Page:** `ToolPage { … }`: scrolls, keeps the window margin and a readable width (760). Pass
  `maxWidth: nil` for full-width media (grids, previews, timelines).
- **Nothing in it yet:** `ToolWelcome` (symbol in a tinted circle, title, one line) with the tool's
  main `InputBar` under it, like the main window's link field, or a `DropZone` and a
  `BarCapsuleButtonStyle` button ("Choose Logo…") for tools that start from a file.
- **The action bar:** once there's a file, a bar like the main window's: `FileCapsule` (the file),
  `BarPicker`s for choices that change the result ("Going to: Online"), a glass "Change…" and the
  main action on the right. Progress and the result (`DoneLabel`) go right under it.
- **Blocks:** `Card { CardHeader(symbol:title:subtitle:) { accessory } … }`. One card per subject.
  The accessory is a `StatusChip`, a `Toggle` (switch), or a `RowButton`. Settings inside a card
  are `CardField(label:) { Picker … }` rows: the name on the left, the control on the right.
- **Lists:** `ItemRow` (icon tile, title, a line under it, progress, round actions on the right),
  the same look as a download row.
- **Status:** `StatusChip` ("Ready", "Off", "12 of 40"). Problems: `ProblemLabel`, an orange
  triangle and one sentence; never red walls of text. Done: `DoneLabel` with Show in Finder.
- **Nothing found** inside a pane or a result list may use `ContentUnavailableView`; a tool's
  first view uses `ToolWelcome`.

## Controls

- **Fields and menus:** capsules at the shared height: `InputBar`, `.capsuleField()` on a
  `TextField`, `BarPicker` for a menu, `FileCapsule` for a file, `.textBox(height:)` on a
  `TextEditor`. Inside cards, `CardField` rows with a plain `Picker` are fine.
- **Switches:** option toggles are `.toggleStyle(.switch)` with `.controlSize(.small)`.
- **The main action:** `BarCapsuleButtonStyle()` (accent fill), or `BarButtonStyle(prominent: true)`
  when it's a symbol (like the download arrow).
- **Secondary actions:** `GlassCapsuleButtonStyle()` (Choose…, Add Folder…).
- **Small actions in rows and cards:** `RowButton(symbol:label:)`, a round glass button with a hint.
- **Minor toggles of what's shown:** a `.link` button ("Pair with a code instead").
- Don't use `.borderedProminent`, `.bordered`, `GroupBox` or a grouped `Form` in tool windows.
  (Settings is the exception: it's a macOS settings window and uses a grouped `Form`.)

## Words

- Short. A card's subtitle is one line; explanations go in `.help` hints.
- One note at the bottom of a page at most (`PageNote`, e.g. "Runs on this Mac.").
- Neutral: no assumptions about the user's setup ("the host Mac", not "the office Mac").
- AI features say they run locally on the Mac.

## Sheets

Dialogs opened from the main window (convert, subtitles, shorts…) keep `SheetHeader` on top, the
settings in a grouped `Form` in between, and standard macOS buttons at the bottom right: Cancel
and the main action (`.borderedProminent`, the default action).

## Checking

Build a test copy and look at every new or changed window in light and dark, at its smallest size,
and with `-PluckOldLook YES` (the macOS 14–15 look). Every tool window has a `-PluckScreenshot`
scene (see ScreenshotMode.swift); add one for a new window. Window definitions in PluckApp.swift
use `.windowToolbarStyle(.unified)`.
