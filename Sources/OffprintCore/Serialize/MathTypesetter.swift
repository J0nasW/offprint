import Foundation

/// Renders LaTeX as Unicode, for display only.
///
/// The exported Markdown keeps real LaTeX, because that is what a downstream
/// renderer or model expects. On screen, though, `$\mathcal{A}=\{A_{1}, \dots\}$`
/// is worse than the PDF it came from — a preview exists to show whether the
/// conversion worked, and raw markup cannot answer that.
///
/// This is an approximation, not a typesetting engine: Unicode has one script
/// alphabet and a partial set of sub- and superscripts, so anything it cannot
/// express is left as plain characters rather than faked. That is the right
/// trade for a preview and the wrong one for an export, which is why the two
/// are kept apart.
public enum MathTypesetter {

    /// One run of a line: either maths, or the prose around it.
    public struct Span: Sendable, Equatable {
        public var text: String
        public var isMath: Bool
        /// The delimiter it was written with, so it can be put back unchanged.
        public var delimiter: String
    }

    /// Splits a line into maths and prose, handling `$$…$$` and `$…$`.
    ///
    /// Shared with the writer, which must not escape inside maths, and with the
    /// preview, which renders it — the two have to agree on where maths starts
    /// and stops or they corrupt each other's output.
    public static func spans(in text: String) -> [Span] {
        guard text.contains("$") else {
            return text.isEmpty ? [] : [Span(text: text, isMath: false, delimiter: "")]
        }
        var out: [Span] = []
        var prose = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "$" else {
                prose.append(text[index])
                index = text.index(after: index)
                continue
            }
            let after = text.index(after: index)
            let isDisplay = after < text.endIndex && text[after] == "$"
            let delimiter = isDisplay ? "$$" : "$"
            let contentStart = isDisplay ? text.index(after: after) : after

            if let close = text.range(of: delimiter, range: contentStart..<text.endIndex) {
                let body = String(text[contentStart..<close.lowerBound])
                if isMath(body) {
                    if !prose.isEmpty { out.append(Span(text: prose, isMath: false, delimiter: "")) }
                    prose = ""
                    out.append(Span(text: body, isMath: true, delimiter: delimiter))
                    index = close.upperBound
                    continue
                }
            }
            // Not maths: keep the dollar and carry on from just after it, since
            // the dollar that would have closed it may open a real formula.
            prose.append("$")
            index = after
        }
        if !prose.isEmpty { out.append(Span(text: prose, isMath: false, delimiter: "")) }
        return out
    }

    /// Replaces every maths span in a line with its Unicode rendering.
    public static func display(_ text: String) -> String {
        spans(in: text).map { $0.isMath ? unicode($0.text) : $0.text }.joined()
    }

    /// Replaces every remaining `\command{argument}` with its argument.
    static func unwrapRemainingCommands(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[rest.startIndex..<slash]
            var cursor = rest.index(after: slash)
            while cursor < rest.endIndex, rest[cursor].isLetter {
                cursor = rest.index(after: cursor)
            }
            guard cursor > rest.index(after: slash), cursor < rest.endIndex,
                  rest[cursor] == "{", let end = matchingBrace(in: rest, from: cursor) else {
                out += "\\"
                rest = rest[rest.index(after: slash)...]
                continue
            }
            out += rest[rest.index(after: cursor)..<end]
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Whether a `$…$` span is a formula rather than a stray dollar sign.
    static func isMath(_ span: String) -> Bool {
        guard !span.isEmpty, !span.contains("\n") else { return false }
        return span.contains(where: { "\\_^{}".contains($0) })
    }

    /// Converts one LaTeX fragment to its closest Unicode form.
    public static func unicode(_ latex: String) -> String {
        var text = latex

        // Alphabets first: they consume their braces, so later brace stripping
        // does not swallow the argument.
        text = mapAlphabet(text, command: "mathcal", table: script)
        text = mapAlphabet(text, command: "mathbb", table: doubleStruck)
        for wrapper in ["mathrm", "mathbf", "mathit", "text", "textrm", "operatorname"] {
            text = unwrap(text, command: wrapper)
        }

        text = replaceFractions(text)
        for (command, replacement) in symbols {
            text = text.replacingOccurrences(of: "\\" + command, with: replacement)
        }

        text = applyScript(text, marker: "^", table: superscripts)
        text = applyScript(text, marker: "_", table: subscripts)

        // Any command still carrying an argument — \widehat{y} and the like —
        // gives up its braces here, so that the braces surviving to the end are
        // only the literal ones.
        text = unwrapRemainingCommands(text)

        // Whatever is left: drop grouping braces and any command that has no
        // Unicode form, keeping its letters rather than showing a backslash.
        text = text.replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\;", with: " ")
            .replacingOccurrences(of: "\\!", with: "")
            .replacingOccurrences(of: "\\", with: "")
        // Braces that survive are literal. Grouping braces always follow a
        // command or a script marker, and those have already been consumed, so
        // what is left is set notation — dropping it turns {A₁, A₂} into a list.
        return text
    }

    // MARK: - Pieces

    /// `\mathcal{ABC}` → `𝒜ℬ𝒞`
    static func mapAlphabet(_ text: String, command: String, table: [Character: String]) -> String {
        transform(text, command: command) { argument in
            String(argument.map { table[$0].map(Character.init) ?? $0 })
        }
    }

    static func unwrap(_ text: String, command: String) -> String {
        transform(text, command: command) { $0 }
    }

    /// `\frac{a}{b}` → `a⁄b`
    static func replaceFractions(_ text: String) -> String {
        transform(text, command: "frac") { numerator in numerator + "⁄" }
    }

    /// Applies `body` to the braced argument of every `\command{…}`.
    static func transform(_ text: String, command: String,
                          _ body: (String) -> String) -> String {
        let needle = "\\" + command
        var out = ""
        var rest = Substring(text)
        while let found = rest.range(of: needle) {
            out += rest[rest.startIndex..<found.lowerBound]
            var cursor = found.upperBound
            guard cursor < rest.endIndex, rest[cursor] == "{",
                  let end = matchingBrace(in: rest, from: cursor) else {
                out += rest[found]
                rest = rest[found.upperBound...]
                continue
            }
            let argument = String(rest[rest.index(after: cursor)..<end])
            out += body(argument)
            cursor = rest.index(after: end)
            rest = rest[cursor...]
        }
        return out + rest
    }

    /// Index of the `}` closing the `{` at `start`.
    static func matchingBrace(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `x_{1}` → `x₁`, `x^2` → `x²`. Anything without a Unicode form keeps its
    /// characters inline rather than being dropped.
    static func applyScript(_ text: String, marker: Character,
                            table: [Character: String]) -> String {
        var out = ""
        var rest = Substring(text)
        while let found = rest.firstIndex(of: marker) {
            out += rest[rest.startIndex..<found]
            var cursor = rest.index(after: found)
            guard cursor < rest.endIndex else { rest = rest[cursor...]; break }

            var argument = ""
            if rest[cursor] == "{" {
                guard let end = matchingBrace(in: rest, from: cursor) else {
                    rest = rest[cursor...]
                    continue
                }
                argument = String(rest[rest.index(after: cursor)..<end])
                cursor = rest.index(after: end)
            } else {
                argument = String(rest[cursor])
                cursor = rest.index(after: cursor)
            }

            if argument.allSatisfy({ table[$0] != nil }) {
                out += argument.map { table[$0]! }.joined()
            } else {
                out += argument
            }
            rest = rest[cursor...]
        }
        return out + rest
    }

    // MARK: - Tables

    static let superscripts: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
        "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ",
        "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ",
        "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "z": "ᶻ",
        "T": "ᵀ", ",": ",",
    ]

    static let subscripts: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
        "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌",
        "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "n": "ₙ",
        "o": "ₒ", "x": "ₓ", "k": "ₖ", "m": "ₘ", "p": "ₚ", "s": "ₛ", "t": "ₜ",
        ",": ",",
    ]

    static let script: [Character: String] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵",
    ]

    static let doubleStruck: [Character: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ",
    ]

    /// Longest names first, so `\subseteq` is not matched as `\subset`.
    static let symbols: [(String, String)] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
        ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"),
        ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"),
        ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"), ("pi", "π"),
        ("rho", "ρ"), ("sigma", "σ"), ("tau", "τ"), ("upsilon", "υ"),
        ("phi", "φ"), ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
        ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"),
        ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
        ("leftrightarrow", "↔"), ("Rightarrow", "⇒"), ("Leftarrow", "⇐"),
        ("rightarrow", "→"), ("leftarrow", "←"), ("mapsto", "↦"),
        ("subseteq", "⊆"), ("supseteq", "⊇"), ("subset", "⊂"), ("supset", "⊃"),
        ("approx", "≈"), ("equiv", "≡"), ("simeq", "≃"), ("propto", "∝"),
        ("times", "×"), ("cdots", "⋯"), ("cdot", "·"), ("ldots", "…"),
        ("dots", "…"), ("div", "÷"), ("pm", "±"), ("mp", "∓"),
        ("leq", "≤"), ("geq", "≥"), ("le", "≤"), ("ge", "≥"), ("neq", "≠"),
        ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("forall", "∀"),
        ("exists", "∃"), ("notin", "∉"), ("emptyset", "∅"),
        ("sum", "∑"), ("prod", "∏"), ("int", "∫"), ("sqrt", "√"),
        ("in", "∈"), ("cup", "∪"), ("cap", "∩"), ("to", "→"),
        ("langle", "⟨"), ("rangle", "⟩"), ("quad", "  "),
    ]
}
