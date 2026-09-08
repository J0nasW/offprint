import Foundation
import Testing
@testable import OffprintCore

@Suite("Running headers and footers")
struct RunningContentFilterTests {

    func page(_ index: Int, header: String?, footer: String?, body: String)
        -> PageContent {
        var blocks: [Block] = []
        if let header {
            blocks.append(.heading(.init(level: 6, text: header,
                                         bbox: .init(x: 40, y: 20, width: 500, height: 10))))
        }
        blocks.append(.paragraph(.init(text: body,
                                       bbox: .init(x: 40, y: 200, width: 500, height: 300))))
        if let footer {
            blocks.append(.paragraph(.init(text: footer,
                                           bbox: .init(x: 40, y: 760, width: 500, height: 10))))
        }
        return PageContent(index: index, width: 595, height: 790,
                           blocks: blocks, engine: .textLayer)
    }

    @Test("A header repeated across pages is removed")
    func removesRepeatedHeader() {
        // The failure this prevents: a journal repeats its title and DOI on
        // every page, heading detection promotes each copy, and the document's
        // outline becomes the same line fifteen times.
        let pages = (0..<8).map {
            page($0, header: "Article https://doi.org/10.1038/s41562-024-02020-5",
                 footer: nil, body: "Body text for page \($0).")
        }
        let stripped = RunningContentFilter.strip(pages)
        #expect(stripped.allSatisfy { $0.blocks.count == 1 })
        #expect(stripped.allSatisfy { $0.blocks[0].typeName == "paragraph" })
    }

    @Test("Page numbers vary but the footer still matches")
    func ignoresDigitsWhenMatching() {
        // "…| 2281–2292 2283" differs on every page; without dropping digits,
        // no two footers would ever look alike.
        let pages = (0..<8).map {
            page($0, header: nil,
                 footer: "Nature Human Behaviour | Volume 8 | December 2024 | 2281–2292 228\($0)",
                 body: "Body \($0).")
        }
        let stripped = RunningContentFilter.strip(pages)
        #expect(stripped.allSatisfy { $0.blocks.count == 1 })
    }

    @Test("Body content is never removed, however often it repeats")
    func keepsBodyContent() {
        // Only the margins are considered, so a phrase repeated in running text
        // is safe.
        let pages = (0..<8).map {
            page($0, header: nil, footer: nil, body: "The same sentence on every page.")
        }
        #expect(RunningContentFilter.strip(pages).allSatisfy { $0.blocks.count == 1 })
    }

    @Test("A heading that appears once is kept")
    func keepsUniqueMarginText() {
        var pages = (0..<8).map {
            page($0, header: nil, footer: nil, body: "Body \($0).")
        }
        pages[0].blocks.insert(
            .heading(.init(level: 1, text: "Quantifying the use of AI",
                           bbox: .init(x: 40, y: 20, width: 500, height: 10))), at: 0)
        let stripped = RunningContentFilter.strip(pages)
        #expect(stripped[0].blocks.count == 2)
    }

    @Test("Short documents are left alone")
    func skipsShortDocuments() {
        // Two pages cannot establish that anything repeats.
        let pages = (0..<2).map {
            page($0, header: "Article", footer: nil, body: "Body \($0).")
        }
        #expect(RunningContentFilter.strip(pages).allSatisfy { $0.blocks.count == 2 })
    }

    @Test("Tables and figures in the margin are content, not furniture")
    func neverRemovesStructure() {
        let pages = (0..<8).map { index in
            PageContent(index: index, width: 595, height: 790, blocks: [
                .table(.init(rows: [[.init(text: "a"), .init(text: "b")]],
                             bbox: .init(x: 40, y: 20, width: 500, height: 10))),
            ], engine: .textLayer)
        }
        #expect(RunningContentFilter.strip(pages).allSatisfy { $0.blocks.count == 1 })
    }
}

@Suite("Heading false positives")
struct HeadingRejectionTests {

    func candidate(_ text: String, size: Double = 14) -> HeadingHeuristic.Candidate {
        .init(text: text, bbox: .init(x: 0, y: 0, width: 300, height: size),
              lineCount: 1, fontSize: size)
    }

    func body() -> HeadingHeuristic.Candidate {
        .init(text: String(repeating: "word ", count: 60),
              bbox: .init(x: 0, y: 0, width: 300, height: 40), lineCount: 4, fontSize: 10)
    }

    @Test("Bibliography entries are not section headings")
    func rejectsCitations() {
        // "13. Iansiti, M. & Lakhani, K. R. Competing in the Age of AI" has the
        // exact shape of a numbered section title.
        let result = HeadingHeuristic.classify([
            candidate("13. Iansiti, M. & Lakhani, K. R. Competing in the Age of AI"),
            candidate("21. Brynjolfsson, E., Li, D. & Raymond, L. R. Generative AI at Work"),
            candidate("3 Methodology"),
            body(),
        ])
        #expect(result[0] == .paragraph)
        #expect(result[1] == .paragraph)
        #expect(result[2] != .paragraph)
    }

    @Test("Chart axis labels and legends are not headings")
    func rejectsChartLabels() {
        let result = HeadingHeuristic.classify([
            candidate("0.5 Engineering Physics Pearson's r = 0.841 ring 0.4"),
            candidate("Political science 0.5 27%"),
            candidate("Results"),
            body(),
        ])
        #expect(result[0] == .paragraph)
        #expect(result[1] == .paragraph)
        #expect(result[2] != .paragraph)
    }

    @Test("Ordinary titles containing a number survive")
    func keepsLegitimateHeadings() {
        // The digit test has to tolerate a title that mentions a figure or year.
        #expect(!HeadingHeuristic.looksLikeChartLabel("Growing knowledge demands for AI"))
        #expect(!HeadingHeuristic.looksLikeChartLabel("4 Model Training"))
        #expect(!HeadingHeuristic.looksLikeCitation("Data availability"))
    }
}

@Suite("Body size and paragraph splitting")
struct BodySizeTests {

    func page(_ blocks: [Block]) -> PageContent {
        PageContent(index: 0, width: 595, height: 790, blocks: blocks, engine: .textLayer)
    }

    @Test("Body size is the size most of the document's characters are set in")
    func measuresByCharacterMass() {
        // Counting blocks would let a figure page full of two-word labels
        // outvote the body text.
        let pages = [page([
            .paragraph(.init(text: String(repeating: "a", count: 4000), fontSize: 8.2)),
            .paragraph(.init(text: "x", fontSize: 6.5)),
            .paragraph(.init(text: "y", fontSize: 6.5)),
            .paragraph(.init(text: "z", fontSize: 6.5)),
        ])]
        #expect(HeadingHeuristic.documentBodySize(pages) == 8.25)
    }

    @Test("Headings smaller than body text are demoted")
    func demotesSmallHeadings() {
        // Chart labels on a figure-heavy page: the page's own median is 6.5, so
        // they look like headings until the whole document is consulted.
        let pages = [page([
            .paragraph(.init(text: String(repeating: "a", count: 3000), fontSize: 8.2)),
            .heading(.init(level: 3, text: "Publication year", fontSize: 6.5)),
            .heading(.init(level: 2, text: "Results", fontSize: 10.8)),
        ])]
        let out = HeadingHeuristic.demoteBelowBodySize(pages)
        #expect(out[0].blocks[1].typeName == "paragraph")
        #expect(out[0].blocks[2].typeName == "heading")
    }

    @Test("A numbered subsection survives even at body size")
    func keepsNumberedSubsections() {
        // Plenty of styles set a subsection at the body size and distinguish it
        // only by its number; demoting those empties the outline.
        let pages = [page([
            .paragraph(.init(text: String(repeating: "a", count: 3000), fontSize: 11.0)),
            .heading(.init(level: 3, text: "4.1 Dataset", fontSize: 10.9)),
        ])]
        #expect(HeadingHeuristic.demoteBelowBodySize(pages)[0].blocks[1].typeName == "heading")
    }

    @Test("A section number does not make a title look like an axis label")
    func ignoresSectionNumberInDigitRatio() {
        // "4.1 Dataset" is 22% digits; measured on the title alone it is none.
        #expect(!HeadingHeuristic.looksLikeChartLabel("4.1 Dataset"))
        #expect(HeadingHeuristic.looksLikeChartLabel("Political science 0.5 27%"))
    }

    // MARK: - Paragraph splitting

    func line(_ text: String, x: Double, y: Double, width: Double, size: Double)
        -> TextLayerGeometry.Line {
        .init(text: text, bbox: .init(x: x, y: y, width: width, height: size),
              column: 0, fontSize: size)
    }

    @Test("A wrapped heading stays one paragraph despite its indent")
    func keepsWrappedHeadingTogether() {
        // The second line of a centred heading starts further right, which the
        // indent rule reads as a new paragraph and cuts the title in half.
        //
        // Page context matters here and the test supplies it: "heading sized"
        // only means anything relative to the body around it, so the run
        // includes the body lines that set the page's measure.
        var lines = (0..<6).map { index in
            line("body text filling the whole measure of this column here",
                 x: 306, y: 400 + Double(index) * 13, width: 219, size: 11)
        }
        lines.append(line("5 Evaluating Semantic Embedding", x: 306, y: 548, width: 185, size: 12))
        lines.append(line("Capabilities", x: 325, y: 561, width: 60, size: 12))

        let paragraphs = TextLayerGeometry.paragraphs(from: lines)
        let title = paragraphs.last
        #expect(title?.text == "5 Evaluating Semantic Embedding Capabilities")
    }

    @Test("A body-sized section title separates from the paragraph beneath it")
    func splitsTitleFromBody() {
        // Nothing but line length distinguishes them in this style, and merged
        // the title stops being a heading at all.
        let lines = [
            line("5.1 Generalization to Longer Texts", x: 306, y: 583, width: 169, size: 10.9),
            line("Since our model is trained exclusively on individual", x: 306, y: 596, width: 219, size: 10.9),
            line("sentences, it is essential to evaluate its ability to", x: 306, y: 609, width: 219, size: 10.9),
        ]
        let paragraphs = TextLayerGeometry.paragraphs(from: lines)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].text == "5.1 Generalization to Longer Texts")
    }
}
