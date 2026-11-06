import SwiftUI
import UIKit
#if canImport(SwiftMath)
import SwiftMath
#endif

// MARK: - Réflexion (<think>…</think>)

enum ThinkSplit {
    struct Parts {
        var think: String?
        var answer: String
        var thinkingOpen: Bool
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ raw: String, modelThinks: Bool, streaming: Bool) -> Parts {
        if let open = raw.range(of: "<think>") {
            let before = String(raw[..<open.lowerBound])
            let rest = String(raw[open.upperBound...])
            if let close = rest.range(of: "</think>") {
                let think = String(rest[..<close.lowerBound])
                let after = String(rest[close.upperBound...])
                return Parts(think: clean(think), answer: clean(before + after), thinkingOpen: false)
            }
            return Parts(think: clean(rest), answer: clean(before), thinkingOpen: true)
        }
        // Certains gabarits insèrent déjà <think> : seule la fermeture apparaît dans le texte généré.
        if let close = raw.range(of: "</think>") {
            let think = String(raw[..<close.lowerBound])
            let after = String(raw[close.upperBound...])
            return Parts(think: clean(think), answer: clean(after), thinkingOpen: false)
        }
        if streaming && modelThinks {
            return Parts(think: clean(raw), answer: "", thinkingOpen: true)
        }
        return Parts(think: nil, answer: raw, thinkingOpen: false)
    }
}

// MARK: - Analyse Markdown

enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullets([String])
    case numbered([String], Int)
    case quote(String)
    case code(String, String)
    case table([String], [[String]])
    case math(String)
    case rule
}

enum MD {
    enum Seg {
        case text(String)
        case math(String)
    }

    // MARK: blocs

    private static func displayDelimiters(_ t: String) -> (String, String)? {
        if t.hasPrefix("$$") { return ("$$", "$$") }
        if t.hasPrefix("\\[") { return ("\\[", "\\]") }
        return nil
    }

    private static func isBullet(_ t: String) -> Bool {
        t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") || t.hasPrefix("+ ")
    }

    private static func numberedItem(_ l: String) -> (Int, String)? {
        var digits = ""
        var idx = l.startIndex
        while idx < l.endIndex, l[idx].isNumber {
            digits.append(l[idx])
            idx = l.index(after: idx)
        }
        guard !digits.isEmpty, idx < l.endIndex, l[idx] == "." || l[idx] == ")" else { return nil }
        let after = l.index(after: idx)
        guard after < l.endIndex, l[after] == " " else { return nil }
        let text = String(l[l.index(after: after)...]).trimmingCharacters(in: .whitespaces)
        return (Int(digits) ?? 1, text)
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func startsBlock(_ l: String) -> Bool {
        isBullet(l) || numberedItem(l) != nil || l.hasPrefix("#") || l.hasPrefix(">")
            || l.hasPrefix("```") || l.hasPrefix("$$")
    }

    static func blocks(_ source: String) -> [MDBlock] {
        var out: [MDBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func flush() {
            if !paragraph.isEmpty {
                out.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)

            if t.isEmpty {
                flush()
                i += 1
                continue
            }

            // bloc de code
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(lang, code.joined(separator: "\n")))
                continue
            }

            // formule en bloc
            if let (open, close) = displayDelimiters(t) {
                flush()
                var content = String(t.dropFirst(open.count))
                if let r = content.range(of: close) {
                    content = String(content[..<r.lowerBound])
                } else {
                    var parts = [content]
                    i += 1
                    while i < lines.count {
                        if let r = lines[i].range(of: close) {
                            parts.append(String(lines[i][..<r.lowerBound]))
                            break
                        }
                        parts.append(lines[i])
                        i += 1
                    }
                    content = parts.joined(separator: "\n")
                }
                out.append(.math(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                i += 1
                continue
            }

            // titre
            if t.hasPrefix("#") {
                var level = 0
                for ch in t {
                    if ch == "#" { level += 1 } else { break }
                }
                if level <= 6, t.dropFirst(level).first == " " {
                    flush()
                    out.append(.heading(min(level, 4), String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // ligne horizontale
            if t == "---" || t == "***" || t == "___" {
                flush()
                out.append(.rule)
                i += 1
                continue
            }

            // citation
            if t.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // liste à puces
            if isBullet(t) {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if isBullet(l) {
                        items.append(String(l.dropFirst(2)))
                    } else if !l.isEmpty, !items.isEmpty, !startsBlock(l) {
                        items[items.count - 1] += " " + l
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.bullets(items))
                continue
            }

            // liste numérotée
            if let first = numberedItem(t) {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let item = numberedItem(l) {
                        items.append(item.1)
                    } else if !l.isEmpty, !items.isEmpty, !startsBlock(l) {
                        items[items.count - 1] += " " + l
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.numbered(items, first.0))
                continue
            }

            // tableau
            if t.contains("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(t)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(header, rows))
                continue
            }

            paragraph.append(raw)
            i += 1
        }
        flush()
        return out
    }

    // MARK: texte en ligne (gras, italique, code, liens, formules)

    private static func find(_ chars: [Character], from start: Int, _ a: Character, _ b: Character) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == a && chars[j + 1] == b { return j }
            j += 1
        }
        return nil
    }

    static func segments(_ s: String) -> [Seg] {
        var out: [Seg] = []
        var buf = ""
        let chars = Array(s)
        var i = 0

        func flush() {
            if !buf.isEmpty {
                out.append(.text(buf))
                buf = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                if let end = find(chars, from: i + 2, "\\", ")") {
                    flush()
                    out.append(.math(String(chars[(i + 2)..<end])))
                    i = end + 2
                    continue
                }
            }

            if c == "$" {
                var j = i + 1
                var found = -1
                while j < chars.count {
                    if chars[j] == "\\" {
                        j += 2
                        continue
                    }
                    if chars[j] == "$" {
                        found = j
                        break
                    }
                    if chars[j] == "\n" { break }
                    j += 1
                }
                if found > i + 1 {
                    let inner = String(chars[(i + 1)..<found])
                    let openOK = !(inner.first?.isWhitespace ?? true)
                    let closeOK = !(inner.last?.isWhitespace ?? true)
                    let nextIsDigit = found + 1 < chars.count && chars[found + 1].isNumber
                    if openOK && closeOK && !nextIsDigit {
                        flush()
                        out.append(.math(inner))
                        i = found + 1
                        continue
                    }
                }
            }

            buf.append(c)
            i += 1
        }
        flush()
        return out
    }

    static func attributed(_ t: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let a = try? AttributedString(markdown: t, options: options) { return a }
        return AttributedString(t)
    }

    static func mathText(_ tex: String, size: CGFloat, dark: Bool) -> Text {
        #if canImport(SwiftMath)
        if let image = MathCache.image(tex, size: size, dark: dark, display: false) {
            let drop: CGFloat = image.size.height > size * 1.7 ? 0.32 : 0.2
            return Text(Image(uiImage: image)).baselineOffset(-image.size.height * drop)
        }
        #endif
        return Text(LatexLite.convert(tex)).italic()
    }

    static func inlineText(_ s: String, size: CGFloat, dark: Bool) -> Text {
        var result = Text("")
        for seg in segments(s) {
            switch seg {
            case .text(let t):
                result = result + Text(attributed(t))
            case .math(let tex):
                result = result + mathText(tex, size: size, dark: dark)
            }
        }
        return result
    }
}

// MARK: - Formules : rendu natif (SwiftMath) avec repli en texte

#if canImport(SwiftMath)
enum MathCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ tex: String, size: CGFloat, dark: Bool, display: Bool) -> UIImage? {
        let key = "\(display)|\(Int(size))|\(dark)|\(tex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let label = MTMathUILabel()
        label.latex = tex
        label.fontSize = size
        label.textColor = dark ? UIColor.white : UIColor.black
        label.labelMode = display ? .display : .text

        let fit = label.sizeThatFits(CGSize(width: 2000, height: 2000))
        guard fit.width > 1, fit.height > 1 else { return nil }
        label.frame = CGRect(origin: .zero, size: fit)
        label.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: fit)
        let image = renderer.image { context in
            label.layer.render(in: context.cgContext)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
#endif

enum LatexLite {
    private static let replacements: [(String, String)] = [
        ("\\left", ""), ("\\right", ""),
        ("\\times", "×"), ("\\cdot", "·"), ("\\pm", "±"),
        ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\approx", "≈"), ("\\infty", "∞"),
        ("\\pi", "π"), ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"),
        ("\\Delta", "Δ"), ("\\delta", "δ"), ("\\theta", "θ"), ("\\lambda", "λ"),
        ("\\mu", "μ"), ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\sum", "∑"),
        ("\\int", "∫"), ("\\sqrt", "√"), ("\\rightarrow", "→"), ("\\to", "→"),
        ("\\Rightarrow", "⇒"), ("\\,", " "), ("\\ ", " "), ("\\quad", "  "),
        ("\\text", ""), ("\\mathrm", "")
    ]

    private static let sup: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ"
    ]

    private static let sub: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎"
    ]

    private static func scripts(_ s: String, marker: Character, table: [Character: Character]) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == marker, i + 1 < chars.count else {
                out.append(c)
                i += 1
                continue
            }
            var inner = ""
            if chars[i + 1] == "{" {
                var j = i + 2
                while j < chars.count && chars[j] != "}" {
                    inner.append(chars[j])
                    j += 1
                }
                i = j + 1
            } else {
                inner = String(chars[i + 1])
                i += 2
            }
            let mapped = inner.map { table[$0] }
            if !inner.isEmpty && mapped.allSatisfy({ $0 != nil }) {
                out += String(mapped.compactMap { $0 })
            } else {
                out += String(marker) + "(" + inner + ")"
            }
        }
        return out
    }

    static func convert(_ tex: String) -> String {
        var s = tex
        for (key, value) in replacements {
            s = s.replacingOccurrences(of: key, with: value)
        }
        for _ in 0..<3 {
            s = s.replacingOccurrences(
                of: "\\\\frac\\{([^{}]*)\\}\\{([^{}]*)\\}",
                with: "($1)/($2)",
                options: .regularExpression
            )
            s = s.replacingOccurrences(
                of: "√\\{([^{}]*)\\}",
                with: "√($1)",
                options: .regularExpression
            )
        }
        s = scripts(s, marker: "^", table: sup)
        s = scripts(s, marker: "_", table: sub)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.replacingOccurrences(of: "\\", with: "")
    }
}

// MARK: - Vues

struct DisplayMath: View {
    let tex: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var image: UIImage? {
        #if canImport(SwiftMath)
        return MathCache.image(tex, size: size * 1.15, dark: scheme == .dark, display: true)
        #else
        return nil
        #endif
    }

    var body: some View {
        if let image = image {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: image)
                    .padding(.vertical, 4)
            }
        } else {
            Text(LatexLite.convert(tex))
                .font(.system(size: size * 1.1, design: .serif))
                .italic()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct BlockView: View {
    let block: MDBlock
    let size: CGFloat
    let dark: Bool
    let design: Font.Design
    let accent: Color

    private var bodyFont: Font { .system(size: size, design: design) }

    private func inline(_ s: String) -> Text {
        MD.inlineText(s, size: size, dark: dark)
    }

    var body: some View {
        switch block {
        case .heading(let level, let s):
            let scale: [CGFloat] = [1.5, 1.3, 1.15, 1.05]
            inline(s)
                .font(.system(size: size * scale[min(max(level, 1), 4) - 1], weight: .bold, design: design))
                .padding(.top, 4)

        case .paragraph(let s):
            inline(s).font(bodyFont)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(accent).font(bodyFont)
                        inline(item).font(bodyFont)
                    }
                }
            }

        case .numbered(let items, let start):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .foregroundStyle(accent)
                            .font(bodyFont)
                            .monospacedDigit()
                        inline(item).font(bodyFont)
                    }
                }
            }

        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inline(s)
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
            }

        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(lang.isEmpty ? "code" : lang)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copier", systemImage: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: size * 0.85, design: .monospaced))
                        .padding(12)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.system(size: size, weight: .semibold, design: design))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inline(cell).font(bodyFont)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        case .math(let tex):
            DisplayMath(tex: tex, size: size)

        case .rule:
            Divider()
        }
    }
}

/// Affiche un texte Markdown complet : titres, listes, citations, tableaux, code et formules.
struct RichText: View {
    let text: String
    @EnvironmentObject private var vm: VM
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MD.blocks(text).enumerated()), id: \.offset) { _, block in
                BlockView(
                    block: block,
                    size: vm.cfg.fontSize,
                    dark: scheme == .dark,
                    design: vm.fontDesign,
                    accent: vm.cfg.accent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

struct ThinkBlock: View {
    let text: String
    let seconds: Double?
    let open: Bool
    @EnvironmentObject private var vm: VM
    @State private var expanded = false

    private var title: String {
        if open { return "Réflexion en cours" }
        if let s = seconds { return String(format: "Réflexion %.0f s", s) }
        return "Réflexion"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    if open { ProgressView().scaleEffect(0.6) }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees((expanded || vm.prefs.thinkDisplay == 1) ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if (expanded || vm.prefs.thinkDisplay == 1) && !text.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 2)
                    Text(text)
                        .font(.system(size: vm.cfg.fontSize * 0.9, design: vm.fontDesign))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct MessageView: View {
    let message: Msg
    let isLast: Bool
    let streaming: Bool
    @EnvironmentObject private var vm: VM
    @EnvironmentObject private var speaker: Speaker

    private var parts: ThinkSplit.Parts {
        ThinkSplit.parse(message.text, modelThinks: vm.modelThinks, streaming: streaming)
    }

    var body: some View {
        if message.role == "user" {
            userBubble
        } else {
            assistantView
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .font(.system(size: vm.cfg.fontSize, design: vm.fontDesign))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .contextMenu {
                    Button("Copier") { UIPasteboard.general.string = message.text }
                    if isLast || vm.messages.last(where: { $0.role == "user" })?.id == message.id {
                        Button("Modifier") { vm.editLast() }
                    }
                }
        }
    }

    private var assistantView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let think = parts.think, vm.prefs.thinkDisplay != 2 || parts.thinkingOpen {
                ThinkBlock(text: think, seconds: message.thinkSeconds, open: parts.thinkingOpen)
            }
            if !parts.answer.isEmpty {
                RichText(text: parts.answer)
            } else if streaming && parts.think == nil {
                Text("…").foregroundStyle(.secondary)
            }
            if !streaming && !parts.answer.isEmpty {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isSpeaking: Bool { speaker.speakingText == parts.answer }

    private func toggleSpeech() {
        if isSpeaking {
            speaker.stop()
        } else {
            speaker.speak(parts.answer, voiceID: vm.prefs.ttsVoice, rate: vm.prefs.ttsRate)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 18) {
                Button { UIPasteboard.general.string = parts.answer } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copier")
                if isLast {
                    Button { vm.regenerate() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.generating)
                    .accessibilityLabel("Régénérer")
                }
                Button { toggleSpeech() } label: {
                    Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2")
                }
                .accessibilityLabel(isSpeaking ? "Arrêter la lecture" : "Lire à voix haute")
            }
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)

            if let stat = message.stat {
                Text(stat)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
