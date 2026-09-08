# Offprint

Turn PDFs into clean Markdown and structured JSON, entirely on your Mac.

Drop a PDF in. Nothing is uploaded, nothing is logged, no account is needed.

> **Status: in development.** The extraction engine and the Fast tier are working
> and tested. The app UI, the GLM-OCR tiers, and release automation are not built
> yet. See [Roadmap](#roadmap).

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
```

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

Measured on an M1 Pro, Fast tier: **0.015–0.13 s/page**.

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

## Roadmap

- [x] Block model, Markdown + JSON serialisers, figure extraction
- [x] Text-layer engine with column-aware reading order
- [x] Apple Vision engine (tables, lists, headings)
- [ ] SwiftUI app: drop zone, queue, quality slider, live preview
- [ ] GLM-OCR via MLX Swift (Balanced and Best tiers)
- [ ] Signed DMG, Homebrew tap, landing page

## Licence

MIT.
