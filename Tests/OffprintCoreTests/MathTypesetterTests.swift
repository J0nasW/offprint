import Foundation
import Testing
@testable import OffprintCore

@Suite("Maths for display")
struct MathTypesetterTests {

    @Test("Script and blackboard alphabets are rendered")
    func rendersAlphabets() {
        #expect(MathTypesetter.unicode("\\mathcal{A}") == "𝒜")
        #expect(MathTypesetter.unicode("\\mathbb{R}") == "ℝ")
        #expect(MathTypesetter.unicode("\\mathcal{ABC}") == "𝒜ℬ𝒞")
    }

    @Test("Subscripts and superscripts use real Unicode where it exists")
    func rendersScripts() {
        #expect(MathTypesetter.unicode("A_{1}") == "A₁")
        #expect(MathTypesetter.unicode("x^{2}") == "x²")
        #expect(MathTypesetter.unicode("i_{j}") == "iⱼ")
        #expect(MathTypesetter.unicode("e^{-x}") == "e⁻ˣ" || MathTypesetter.unicode("e^{-x}") == "e⁻x")
    }

    @Test("A script Unicode cannot express is kept as plain characters")
    func degradesGracefully() {
        // Better a readable approximation than a dropped subscript: there is no
        // subscript "w", so the letters stay inline rather than vanishing.
        let out = MathTypesetter.unicode("T_{i j}")
        #expect(out.contains("T"))
        #expect(!out.contains("_"))
        #expect(!out.contains("{"))
    }

    @Test("Greek letters and operators become symbols")
    func rendersSymbols() {
        #expect(MathTypesetter.unicode("\\alpha \\leq \\beta") == "α ≤ β")
        #expect(MathTypesetter.unicode("\\sum \\times \\infty") == "∑ × ∞")
        // Longest name first, or \subseteq would match \subset and leave "eq".
        #expect(MathTypesetter.unicode("\\subseteq") == "⊆")
    }

    @Test("Only maths spans are touched")
    func leavesProseAlone() {
        let text = "The cost is $5 and the set is $\\mathcal{A}$ throughout."
        let out = MathTypesetter.display(text)
        #expect(out.contains("𝒜"))
        #expect(out.hasPrefix("The cost is "))
    }

    @Test("Text without maths is returned unchanged")
    func passesThroughPlainText() {
        let text = "No mathematics here at all."
        #expect(MathTypesetter.display(text) == text)
    }

    @Test("A real formula from a paper reads as mathematics")
    func rendersARealFormula() {
        // The exact string the model returns for this paper's method section.
        let out = MathTypesetter.display("$\\mathcal{A}={A_{1}, A_{2}, \\dots, A_{n}}$")
        #expect(out == "𝒜={A₁, A₂, …, Aₙ}")
    }

    @Test("Unknown commands lose the backslash rather than showing markup")
    func stripsUnknownCommands() {
        let out = MathTypesetter.unicode("\\widehat{y}")
        #expect(!out.contains("\\"))
        #expect(!out.contains("{"))
        #expect(out.contains("y"))
    }
}

@Suite("Maths span scanning")
struct MathSpanTests {

    @Test("Display maths uses its own delimiter and survives a round trip")
    func handlesDisplayDelimiters() {
        // `$$…$$` was being read as an empty `$…$` span, so the formula fell
        // outside maths, got escaped, and rendered with stray dollar signs.
        let spans = MathTypesetter.spans(in: "before $$\\mathcal{L}(x)=1$$ after")
        #expect(spans.count == 3)
        #expect(spans[1].isMath)
        #expect(spans[1].delimiter == "$$")

        let out = MarkdownWriter().write(blocks: [
            .paragraph(.init(text: "before $$\\mathcal{L}(x)=1$$ after")),
        ])
        #expect(out.contains("$$\\mathcal{L}(x)=1$$"))
    }

    @Test("Display maths renders without leftover delimiters")
    func rendersDisplayMaths() {
        let out = MathTypesetter.display("$$\\mathcal{L}(e_{a})=1$$")
        #expect(!out.contains("$"))
        #expect(out.contains("ℒ"))
    }

    @Test("A lone dollar is prose")
    func keepsLoneDollars() {
        #expect(MathTypesetter.display("costs $5 today") == "costs $5 today")
        #expect(MathTypesetter.spans(in: "a $ b").allSatisfy { !$0.isMath })
    }
}
