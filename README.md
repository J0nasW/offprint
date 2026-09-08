# Offprint

Turn PDFs into clean Markdown and structured JSON, entirely on your Mac.

Drop a PDF in. Nothing is uploaded, nothing is logged, no account is needed.

> **Status: early.** The engine, the Fast tier, the app, and the release pipeline
> are working. The GLM-OCR tiers (Balanced and Best) are not implemented yet — the
> slider moves, but all three stops currently run the Fast pipeline. See
> [Roadmap](#roadmap).

## Install

```sh
brew install --cask J0nasW/offprint/offprint
```

Or download `Offprint.dmg` from [the latest release](https://github.com/J0nasW/offprint/releases/latest).

Builds are **ad-hoc signed rather than notarised**, so on first launch macOS says
it cannot verify the developer. Open **System Settings → Privacy & Security**,
scroll to Security, and choose **Open Anyway**. Homebrew does not avoid this —
`--no-quarantine` was removed from Homebrew in July 2026.

## Why local

A 0.9B open model now scores **95.22** on OmniDocBench v1.6 — above Gemini 3 Pro
(92.91) and GPT-5.2 (86.59) — and it runs on a laptop. For this particular task,
local is not the private-but-worse option; it is simply the better one.

## How it works

Offprint routes **each page** independently, because hybrid documents — a
born-digital report with scanned appendices — are common, and treating a document
as one thing gets half of it wrong.

| Tier | Pipeline | Download |
|---|---|---|
| **Fast** | Embedded text layer where it is trustworthy, Apple Vision where it is not | none |
| **Balanced** | GLM-OCR full page for anything the text layer cannot describe | 1.25 GB |
| **Best** | Vision locates regions, GLM-OCR reads each with the matching task prompt | same 1.25 GB |

The idea the design turns on: **Apple's Vision framework supplies layout, GLM-OCR
supplies recognition.** GLM-OCR was built to sit behind a layout detector rather
than to read whole pages. Rather than port that detector, Offprint uses
`RecognizeDocumentsRequest` (macOS 26+), which already returns tables with
merged-cell ranges, lists with marker types, and paragraph grouping — on the
Neural Engine, at no download cost.

## Output

Markdown and JSON are rendered from the same block tree, so they cannot disagree.

```json
{
  "source": { "filename": "paper.pdf", "pages": 22 },
  "engine": { "tier": "fast", "appVersion": "0.1.0" },
  "pages": [{
    "index": 0, "width": 595, "height": 841,
    "blocks": [
      { "type": "heading", "level": 1, "text": "…", "bbox": [74, 71, 447, 12.8] },
      { "type": "table", "rows": [[{ "text": "…", "rowSpan": 1, "colSpan": 2 }]] }
    ]
  }]
}
```

Column spans survive into JSON. Markdown cannot express them, so a spanned region
carries its text in the top-left cell — lossy, but visibly so.

## Building

Requires macOS 26, Xcode 26, Apple Silicon.

```bash
swift build          # engine + harness
swift test           # 28 tests, no Metal toolchain needed

brew install xcodegen
xcodegen generate    # writes Offprint.xcodeproj from project.yml
xcodebuild -project Offprint.xcodeproj -scheme Offprint build
```

The Xcode project is generated rather than checked in: SwiftPM's CLI cannot
compile MLX's Metal shaders, so `xcodebuild` is required, but a checked-in
`.xcodeproj` is unreadable in review.

The engine splits into `OffprintCore` (no MLX — models, layout, serialisers) and,
once the model tiers land, `OffprintML`. Everything valuable is in Core, so most
of the project stays testable with a plain fast `swift test`.

## The harness

Quality and speed are measured before they are promised anywhere in the UI.

```bash
offprint-harness convert  paper.pdf --json -o out/
offprint-harness classify paper.pdf        # per-page routing decision
offprint-harness report   ~/papers/        # timing and block counts
offprint-harness lines    paper.pdf        # line geometry, for debugging
```

Measured on an M1 Pro, Fast tier:

| Document | Pages | s/page | Tables | Figures |
|---|---|---|---|---|
| Two-column ML paper | 22 | 0.29 | 2 | 1 |
| Springer journal article | 19 | 0.18 | 2 | 4 |
| 99-page stakeholder registry | 99 | 0.58 | 201 | 27 |
| Slide deck | 35 | 0.10 | 6 | 27 |
| German working paper | 3 | 0.35 | 2 | 2 |

Prose-only pages run at **0.04–0.15 s/page**. Pages that look tabular cost more,
because they are handed to Vision for a real table read — see below.

## Notes from building it

Three things cost real time and are worth writing down:

- **`PDFPage.string` cannot be trusted for order.** It returns characters in
  content-stream order, so a two-column page interleaves its columns into fluent
  text that says something the document never said.
- **`characterBounds(at:)` does not share an index space with `string`.** The
  association drifts by a couple of characters per line, silently truncating every
  line. Offprint takes only geometry from it and reads each row's text back with
  `selection(for:)`.
- **Vision can split a table down the wrong axis**, and the result is still valid
  Markdown — nothing downstream can detect it. Tables carry a `structureSuspect`
  flag, and the Markdown says so.
- **Table columns are found by whitespace corridors, not by wide gaps.** A dense
  results table sets its numeric columns barely wider than a word space, so a
  gap-width threshold either merges them all or shreds justified prose into
  cells. What separates the two is that a table's column boundary is empty on
  *every* row, while the gaps in justified text land wherever the line breaks
  put them.
- **Section numbering beats typography for outlines.** Many styles mark a
  subsection with its number alone, at body size and weight, so `3.2.1 Embedding
  layer` is invisible to any size-based test — and the number also states the
  nesting depth directly, which font size can only approximate.
- **An ad-hoc signed app cannot use the App Sandbox.** Sandbox setup needs a team
  identity to anchor the container, so the app traps in `libsecinit` before
  `main()`. The sandbox is off until there is a Developer ID;
  `Offprint.entitlements` documents exactly how to turn it back on.

## Roadmap

- [x] Block model, Markdown + JSON serialisers, figure extraction
- [x] Text-layer engine with column-aware reading order
- [x] Apple Vision engine (tables, lists, headings)
- [x] SwiftUI app: drop zone, queue, quality slider, live preview
- [x] Release pipeline, Homebrew cask, landing page
- [ ] GLM-OCR via MLX Swift (Balanced and Best tiers)
- [ ] Notarised builds (needs an Apple Developer Program membership)

## Licence

MIT.
