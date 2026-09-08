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
| **Balanced** | GLM-OCR reads anything the text layer cannot describe | 1.25 GB |
| **Best** | GLM-OCR reads every page, text layer or not | same 1.25 GB |

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

## Counts

Extraction is usually a step on the way to a model, so the numbers that decide
whether output fits a context window ship with it — in the JSON, and in the
window:

```
41,096 words · 285,085 chars · ~63,708 tokens · 55 tables
```

The token figure is labelled an estimate because that is what it is: an exact
count is exact for exactly one tokenizer, and models disagree.

## For retrieval

Chunking by a fixed window is what makes retrieval brittle. A paragraph lifted
out of a 125-page report says almost nothing on its own, and a chunk that
straddles a section boundary answers questions about neither section.

So chunks are cut **by section first**, then by size within a section. Each one
carries the breadcrumb trail of its section, its position in it, and links to its
neighbours — enough for an agent to know what it is holding, whether it is
holding all of it, and where to look next.

```json
{ "id": 6, "sectionID": "3.1", "partIndex": 1, "partCount": 2,
  "headingPath": ["Defining Artificial Intelligence 2.0", "Foreword"],
  "pages": [5], "estimatedTokens": 491, "previousID": 5, "nextID": 7 }
```

An `.outline.json` ships alongside: the section tree with token counts and the
chunk ids under each heading, so an agent can *look at the structure and choose
what to read* rather than embedding everything and hoping similarity finds it.

```
3   Defining Artificial Intelligence 2.0   [4 chunks]
  3.1 Foreword                             [2 chunks]
  3.3 Abstract                             [2 chunks]
```

## For agents (MCP)

Offprint speaks the Model Context Protocol over stdio, so Claude Code, Claude
Desktop, or any MCP client can read PDFs on this Mac.

```sh
claude mcp add offprint -- "/Applications/Offprint PDF to Markdown.app/Contents/MacOS/offprint" --mcp
```

The tools are deliberately not "convert this PDF and give me the text". A
125-page report is ~64,000 tokens; returning it in one call spends most of an
agent's context to answer something one section would have answered. So:

| Tool | What it is for |
|---|---|
| `open_document` | Counts and the section outline. Start here. |
| `get_outline` | Just the outline, with tokens and page ranges per section |
| `read_section` | One section by id, e.g. `3.1` |
| `search_document` | Ranked passages, with breadcrumb, pages and chunk id |
| `read_chunk` | One chunk, optionally with neighbours, to widen a hit |
| `export_document` | Write the full conversion to disk, return the paths |

```
eu_example.pdf — 125 pages, 41,022 words, ~63,582 tokens, 55 tables (1 unverified)

OUTLINE
3 Defining Artificial Intelligence 2.0     [1394 tokens · p.1–5]
  3.7 1 Introduction                       [1490 tokens · p.12–13]
  3.8 2 AI definitions                     [4 tokens · p.14]
    3.8.1 2.1 Definitions in market, policy and research  [425 tokens · p.14]
```

Search is lexical, not semantic, on purpose: embedding a document would mean a
second model download and an index, for a question usually answered by "which
section mentions this". Heading matches score higher, because a term in a
heading describes the whole section.

## Scripting

The app doubles as its own CLI, which is also how the model tiers are measured:

```sh
"/Applications/Offprint PDF to Markdown.app/Contents/MacOS/offprint" \
  --convert paper.pdf --tier balanced --json --chunks --out ./out
```

## The harness

Quality and speed are measured before they are promised anywhere in the UI.

```bash
offprint-harness convert  paper.pdf --json --chunks -o out/
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
- [x] Table of contents, bullet lists, word/character/token counts
- [x] SwiftUI app: drop zone, queue, quality slider, live preview
- [x] Release pipeline, Homebrew cask, landing page
- [x] GLM-OCR via MLX Swift — **4.3 s/page** measured on an M1 Pro
- [x] Section-aware chunking and a navigable outline, for retrieval
- [ ] MCP server, so an agent on this Mac can convert a PDF on demand
- [ ] Notarised builds (needs an Apple Developer Program membership)

## Licence

MIT.
