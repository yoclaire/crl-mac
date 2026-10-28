import AppKit
import CRLKit

/// Renders entry markup the way CRL32 displayed it: serif body text, red pronunciations, blue
/// italic parts of speech in a left margin column, numbered senses and magenta bracketed
/// etymologies (matched against a screenshot of the original reading "eighty-six").
///
/// The markup is SGML with mostly omitted end tags, so most tags style the text up to the next tag;
/// tags in `scoped` really are closed (`<EM1>…</EM1>`) and nest.
struct ArticleRenderer {
    let book: Book
    let scale: CGFloat

    static let red = NSColor(srgbRed: 0.72, green: 0.05, blue: 0.05, alpha: 1)
    static let blue = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.75, alpha: 1)
    static let magenta = NSColor(srgbRed: 0.85, green: 0.0, blue: 0.85, alpha: 1)
    static let ink = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)

    struct Style: Equatable {
        var bold = false, italic = false, size: CGFloat = 1, color: NSColor? = nil, superscript = false, hidden = false
        var smallCaps = false
        var link: URL? = nil
    }

    var marginWidth: CGFloat { 58 * scale }
    var bodySize: CGFloat { 11.5 * scale }

    func font(_ s: Style) -> NSFont {
        let size = bodySize * s.size * (s.superscript ? 0.7 : 1)
        var f = NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        var traits: NSFontTraitMask = []
        if s.bold { traits.insert(.boldFontMask) }
        if s.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { f = NSFontManager.shared.convert(f, toHaveTrait: traits) }
        return f
    }

    // Tags whose closing tag is present in the data.
    static let scoped: Set<String> = ["EM1", "EM3", "E0", "I", "B", "BI", "BLD", "IT", "TITLE", "XR", "DXR", "CAT", "OGEO",
                                      "DQ", "SUP", "SUB", "TERM", "U", "SC", "BODY", "TBODY", "TABLE", "L", "SEC", "SS1",
                                      "ST", "HW", "IWD", "WD", "SY", "SS2", "TITLE1", "PARA"]

    func render(_ a: Library.Article) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, part) in a.parts.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(book.id == "dictionary" ? renderDictionary(part) : renderGeneric(part, first: i == 0))
        }
        return out
    }

    // MARK: paragraph styles

    func paragraph(hanging: Bool, extraIndent: CGFloat = 0, spacingBefore: CGFloat = 2) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        if hanging {
            p.headIndent = marginWidth + extraIndent
            p.firstLineHeadIndent = 0
            p.tabStops = [NSTextTab(textAlignment: .left, location: marginWidth), NSTextTab(textAlignment: .left, location: marginWidth + extraIndent)]
        }
        p.paragraphSpacingBefore = spacingBefore * scale
        p.lineHeightMultiple = 1.0
        return p
    }

    func attrs(_ s: Style, _ p: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font(s), .foregroundColor: s.color ?? Self.ink, .paragraphStyle: p]
        if s.superscript { a[.baselineOffset] = bodySize * 0.35 }
        if let l = s.link { a[.link] = l; a[.underlineStyle] = 0 }
        return a
    }

    // MARK: American Heritage Dictionary

    func renderDictionary(_ src: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var para = paragraph(hanging: true, spacingBefore: 0)
        var style = Style()                          // style of text until the next tag
        var stack: [(String, Style)] = []
        var region: (suffix: String, style: Style)?  // PR "(…)" / ETYSEG "[…]"
        var headwords = 0, sense = 0, subsense = 0, pendingLabel = "", inINFL = false, lastWasTab = false

        func current() -> Style {
            var s = region?.style ?? Style()
            let merge = stack.last?.1 ?? style
            s.bold = s.bold || merge.bold || style.bold; s.italic = s.italic || merge.italic || style.italic
            s.size = max(merge.size, style.size); s.color = merge.color ?? style.color ?? s.color
            s.superscript = merge.superscript || style.superscript; s.hidden = style.hidden || merge.hidden
            s.link = merge.link ?? style.link
            return s
        }
        func emit(_ t: String, _ s: Style? = nil) {
            let st = s ?? current()
            guard !st.hidden, !t.isEmpty else { return }
            out.append(NSAttributedString(string: t, attributes: attrs(st, para)))
            lastWasTab = t.hasSuffix("\t")
        }
        func closeRegion() { if let r = region { emit(r.suffix, r.style); region = nil } }
        func newParagraph(_ p: NSParagraphStyle) {
            closeRegion()
            if out.length > 0 { emit("\n", Style()) }
            para = p
        }

        for tok in Markup.tokens(src) {
            switch tok {
            case .text(let t):
                emit(inINFL && style.bold && out.string.last.map({ !$0.isWhitespace }) == true && !lastWasTab ? " " + t : t)
            case .glyph(let g):
                emit(Markup.glyphs[g] ?? "")
            case .newline:
                break                                    // structure comes from tags
            case .close(let n):
                if let i = stack.lastIndex(where: { $0.0 == n }) { stack.remove(at: i) }
                if n == "INFL" { inINFL = false }
                style = Style()
            case .open(let n, let attr):
                switch n {
                case "WD":
                    headwords += 1
                    style = Style(bold: true, size: headwords == 1 ? 1.35 : 1)
                    if headwords == 1 { para = paragraph(hanging: false, spacingBefore: 0) }
                case "UP": style = Style(bold: true, superscript: true)
                case "EQ": style = Style(); emit(" or ", Style())
                case "PR": emit(" ", Style()); region = (")", Style(color: Self.red)); emit("(", Style(color: Self.red)); style = Style(color: Self.red)
                case "PRBODY", "PRON": style = Style(color: Self.red)
                case "PSEG":
                    newParagraph(paragraph(hanging: true, spacingBefore: 3)); sense = 0; pendingLabel = ""
                    style = Style()
                case "POS": style = Style(italic: true, color: Self.blue)
                case "SPOS": emit(" ", Style()); style = Style(italic: true, color: Self.blue)
                case "INFL": emit("\t", Style()); inINFL = true; style = Style()
                case "INF": style = Style(bold: true); if !lastWasTab { emit(" ", Style()) }
                case "LAB":
                    if inINFL || out.string.hasSuffix("\t") || attr["TYPE"] == "US" && sense == 0 {
                        // Usage/field label at sense level: shown in the margin column of the next sense.
                        style = Style(hidden: true); pendingLabel = "LAB"
                        inINFL = false
                    } else { style = Style(italic: true) }
                case "DS":
                    sense += 1; subsense = 0
                    newParagraph(paragraph(hanging: true, extraIndent: 14 * scale))
                    emit(pendingLabelText(&pendingLabel, src: src, around: sense), Style(italic: true))
                    emit("\t", Style()); emit("\(sense).", Style(bold: true)); emit("\t", Style())
                    style = Style()
                case "SDS":
                    subsense += 1
                    let letter = String(UnicodeScalar(UInt8(96 + min(subsense, 26))))
                    if subsense > 1 || !out.string.hasSuffix("\t") {
                        newParagraph(paragraph(hanging: true, extraIndent: 28 * scale))
                        emit("\t\t", Style())
                    }
                    emit("\(letter). ", Style(bold: true)); style = Style()
                case "ETYSEG":
                    newParagraph(paragraph(hanging: true, spacingBefore: 3))
                    emit("\t", Style())
                    region = ("]", Style(color: Self.magenta)); emit("[", Style(color: Self.magenta)); style = Style(color: Self.magenta)
                case "EMON", "EX", "EM1", "OGEO", "IT", "I": stack.append((n, Style(italic: true, color: region?.style.color)))
                    if !Self.scoped.contains(n) { style = Style(italic: true) }
                case "GL": style = Style(); emit(", “", Style()); stack.append(("GL", Style()))
                case "KW", "IEKW", "B": style = Style(bold: true)
                case "LD", "LANG", "ORIG", "LFORM", "TX", "DEF", "DEFTX", "ETYS", "SETYS": style = Style()
                    if n == "LANG" { emit(" ", Style()) }
                case "SEEREF": emit(" See ", Style(italic: true)); style = Style(bold: true)
                case "NAMEFORM", "NAME", "BIOVAR", "DATES": style = Style(bold: n == "NAME"); emit(" ", Style())
                case "USAGE", "USG", "SYN", "SYNSEG", "REGION", "ORIGIN":
                    newParagraph(paragraph(hanging: false, spacingBefore: 4)); style = Style()
                default: style = Style()
                }
                if n != "GL", case .open = tok, stack.last?.0 == "GL", n != "EMON" { stack.removeLast(); emit("”", Style()) }
            }
        }
        closeRegion()
        return out
    }

    /// The sense-level label (e.g. "Slang", "Law") that CRL32 drew in the margin before a sense.
    func pendingLabelText(_ pending: inout String, src: String, around sense: Int) -> String {
        guard !pending.isEmpty else { return "" }
        pending = ""
        // Labels are the text right after the last <LAB …> before this sense.
        let parts = src.components(separatedBy: "<DS>")
        guard sense - 1 < parts.count else { return "" }
        let before = parts[sense - 1]
        guard let r = before.range(of: "<LAB", options: .backwards), let gt = before[r.upperBound...].firstIndex(of: ">") else { return "" }
        return String(before[before.index(after: gt)...].prefix { $0 != "<" && $0 != "\n" })
    }

    // MARK: everything else

    static let block: Set<String> = ["HW", "P", "PARA", "ROW", "LI", "SEC", "ST", "SS1", "SS2", "TITLE1", "SUBTITLE", "NAME", "ADDRESS1",
                                     "ADDRESS2", "CSZ", "PHONE", "FAX", "CT", "SRC", "SY", "DS", "DEF", "LEV", "TABLE", "L", "LONG-ART",
                                     "COUNTRY-SEC", "FAM", "TERM", "DF", "BODY", "TBODY", "LINEB", "SEEALSO", "PS", "AL"]
    static let hiddenUntilTag: Set<String> = ["CS", "CE", "PAR", "COLS", "COLSPEC", "PS", "DXR", "CAT"]

    /// Tags that are always closed in the data, so they can nest on a stack.
    static let closed: Set<String> = ["EM1", "EM3", "E0", "I", "B", "BI", "BLD", "IT", "TITLE", "XR", "SUP", "SUB", "DQ", "OGEO", "U", "SC", "TERM"]

    func renderGeneric(_ src: String, first: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var para = paragraph(hanging: false, spacingBefore: 0)
        var style = Style(), stack: [(String, Style)] = []

        func current() -> Style {
            var s = style
            for (_, st) in stack {
                s.bold = s.bold || st.bold; s.italic = s.italic || st.italic; s.size = max(s.size, st.size)
                s.color = st.color ?? s.color; s.superscript = s.superscript || st.superscript; s.hidden = s.hidden || st.hidden
                s.smallCaps = s.smallCaps || st.smallCaps
            }
            return s
        }
        func emit(_ t: String, _ s: Style? = nil) {
            var st = s ?? current()
            guard !st.hidden, !t.isEmpty else { return }
            if st.smallCaps { st.size *= 0.82 }
            out.append(NSAttributedString(string: st.smallCaps ? t.uppercased() : t, attributes: attrs(st, para)))
        }
        func push(_ n: String, _ st: Style) {
            if Self.closed.contains(n) { stack.append((n, st)) } else { style = st }
        }
        func newParagraph(spacing: CGFloat = 4, indent: CGFloat = 0) {
            if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: attrs(Style(), para))) }
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacing * scale
            p.headIndent = indent; p.firstLineHeadIndent = indent
            p.tabStops = (1...6).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 90 * scale) }
            para = p
        }

        for tok in Markup.tokens(src) {
            switch tok {
            case .text(let t):
                emit(t)
            case .glyph(let g): emit(Markup.glyphs[g] ?? "")
            case .newline:
                // Line breaks inside running text are soft wraps; block tags start their own paragraphs.
                if let last = out.string.last, !last.isWhitespace { out.append(NSAttributedString(string: " ", attributes: attrs(Style(), para))) }
                style = Style(); stack.removeAll()
            case .close(let n):
                if let i = stack.lastIndex(where: { $0.0 == n }) { stack.remove(at: i) } else { style = Style() }
            case .open(let n, _):
                if Self.hiddenUntilTag.contains(n) { style = Style(hidden: true); continue }
                if n == "WD" || n == "IWD" {
                    // The title line: shown in the pane's title bar, so hide it in the body.
                    style = Style(hidden: true); continue
                }
                if Self.block.contains(n) { newParagraph(spacing: n == "ROW" || n == "LINEB" ? 1 : 4, indent: n == "LI" ? 12 * scale : 0) }
                switch n {
                case "HW", "TITLE1": push(n, Style(bold: true, size: 1.2))
                case "TITLE", "ST", "NAME", "TERM", "SUBTITLE", "SS1", "SS2", "B", "BLD", "KW": push(n, Style(bold: true))
                case "BI": push(n, Style(bold: true, italic: true))
                case "I", "IT", "EM1", "EM3", "E0", "DQ", "US", "SRC": push(n, Style(italic: true))
                case "SUP": push(n, Style(superscript: true))
                case "SC": push(n, Style(smallCaps: true))
                case "XR": push(n, Style(color: Self.blue, smallCaps: true))
                case "LI": emit("•  ", Style())
                case "ENTRY", "CELL": if !out.string.hasSuffix("\n") { emit("\t", Style()) }
                case "D1": emit(", ", Style())
                case "SY": style = Style()
                case "DS": style = Style(italic: true)
                case "PHONE", "FAX", "CSZ", "ADDRESS1", "ADDRESS2": style = Style()
                case "FN", "SN": style = Style(bold: true)
                case "TI": style = Style(italic: true)
                case "CT": style = Style()
                default: style = Style()
                }
            }
        }
        linkCrossReferences(out, src: src)
        return out
    }

    /// Columbia/Almanac cross-references are `<xr>text</xr><dxr>entry</dxr>`; link the visible text.
    func linkCrossReferences(_ out: NSMutableAttributedString, src: String) {
        let pattern = try! NSRegularExpression(pattern: "<xr>([^<]*)</xr><dxr>(\\d+)</dxr>", options: .caseInsensitive)
        let ns = src as NSString
        var searchFrom = 0
        for m in pattern.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            let text = Markup.plain(ns.substring(with: m.range(at: 1))).uppercased(), num = ns.substring(with: m.range(at: 2))
            let hay = out.string as NSString
            let r = hay.range(of: text, range: NSRange(location: searchFrom, length: hay.length - searchFrom))
            guard r.location != NSNotFound, let url = URL(string: "crl://\(book.id)/\(num)") else { continue }
            out.addAttributes([.link: url, .foregroundColor: Self.blue], range: r)
            searchFrom = r.location + r.length
        }
    }
}
