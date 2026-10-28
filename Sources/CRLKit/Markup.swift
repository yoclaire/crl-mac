import Foundation

/// Tokenizer for the SGML-ish entry markup (`<HW>`, `</HW>`, `<EQ type=CAP>`, `&mdash;`, `\schwa/`).
public enum Markup {
    public enum Token: Equatable {
        case text(String)
        case open(String, [String: String])   // tag name upper-cased
        case close(String)
        case glyph(String)                      // AHD pronunciation glyph, e.g. "schwa" from \schwa/
        case newline
    }

    /// Entry text is Windows-1252.
    public static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    public static func tokens(_ s: String) -> [Token] {
        var out: [Token] = [], text = ""
        let chars = Array(s)
        var i = 0
        func flush() { if !text.isEmpty { out.append(.text(text)); text = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "<", let j = chars[i...].firstIndex(of: ">"), j - i < 80 {
                flush()
                let inner = String(chars[(i + 1)..<j])
                if inner.hasPrefix("/") {
                    out.append(.close(inner.dropFirst().uppercased()))
                } else {
                    var parts = inner.split(separator: " ", maxSplits: 10).map(String.init)
                    let name = parts.isEmpty ? "" : parts.removeFirst().uppercased()
                    var attrs: [String: String] = [:]
                    for p in parts { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { attrs[kv[0].uppercased()] = String(kv[1]) } }
                    out.append(.open(name, attrs))
                }
                i = j + 1
            } else if c == "&", let j = chars[i...].prefix(12).firstIndex(of: ";") {
                let name = String(chars[(i + 1)..<j])
                if let u = entities[name] { text += u } else { text += "&\(name);" }
                i = j + 1
            } else if c == "\\", let j = chars[(i + 1)...].prefix(16).firstIndex(of: "/"),
                      chars[(i + 1)..<j].allSatisfy({ $0.isLetter || $0.isNumber }) {
                flush()
                out.append(.glyph(String(chars[(i + 1)..<j])))
                i = j + 1
            } else if c == "\n" {
                flush(); out.append(.newline); i += 1
            } else {
                text.append(c); i += 1
            }
        }
        flush()
        return out
    }

    /// Plain text for search indexing and list titles.
    public static func plain(_ s: String) -> String {
        var out = ""
        for t in tokens(s) {
            switch t {
            case .text(let x): out += x
            case .glyph(let g): out += glyphs[g] ?? ""
            case .newline: out += "\n"
            case .open(let n, _) where ["D1", "ENTRY", "CELL", "LI"].contains(n): out += " "
            default: break
            }
        }
        return out
    }

    /// Unicode approximations of the AHD/Columbia pronunciation glyphs (drawn from CRL_1.TTF in the
    /// original). Used for search text and as a fallback when the disc font is unavailable.
    public static let glyphs: [String: String] = [
        "schwa": "ə", "along": "ā", "elong": "ē", "ilong": "ī", "olong": "ō", "ulong": "ū",
        "abreve": "ă", "ebreve": "ĕ", "ibreve": "ĭ", "obreve": "ŏ", "ubreve": "ŭ",
        "bprime": "ʹ", "lprime": "ʹ", "prime": "′", "oomacr": "o͞o", "oobreve": "o͝o",
        "th": "th", "thbar": "th", "zh": "zh", "hw": "hw", "ng": "ng",
    ]

    public static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "mdash": "—", "ndash": "–", "middot": "·", "deg": "°",
        "acute": "ʹ", "bprime": "ʹ", "lprime": "ʹ", "prime": "′", "schwa": "ə",
        "amacr": "ā", "emacr": "ē", "imacr": "ī", "omacr": "ō", "umacr": "ū",
        "abreve": "ă", "ebreve": "ĕ", "ibreve": "ĭ", "obreve": "ŏ", "ubreve": "ŭ",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "atilde": "ã", "ntilde": "ñ", "otilde": "õ", "ccedil": "ç", "szlig": "ß",
        "oslash": "ø", "aring": "å", "aelig": "æ", "oelig": "œ", "eth": "ð", "thorn": "þ",
        "Aacute": "Á", "Eacute": "É", "Ouml": "Ö", "Uuml": "Ü", "Auml": "Ä", "Ccedil": "Ç",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "times": "×", "divide": "÷", "plusmn": "±",
        "sect": "§", "para": "¶", "copy": "©", "reg": "®", "trade": "™", "cent": "¢", "pound": "£",
        "yen": "¥", "hellip": "…", "bull": "•", "dagger": "†", "micro": "µ", "nbsp": "\u{00A0}",
        "lineb": "\n", "thinsp": "\u{2009}", "emsp": "\u{2003}", "ensp": "\u{2002}",
    ]

    /// Title shown in the Subject List: the `<WD>` line with markup removed.
    public static func title(_ s: String) -> (title: String, isContinuation: Bool) {
        let first = s.prefix { $0 != "\n" }
        let isCont = first.hasPrefix("<IWD>")
        // The title is the <WD> text up to the first tag that starts other material (pronunciation,
        // homograph number, variant forms…); inline name/emphasis tags stay part of it.
        let inline: Set<String> = ["WD", "IWD", "FN", "SN", "I", "B", "BI", "IT", "EM1", "EM3", "E0", "SC", "SUP", "SUB", "TITLE", "HW"]
        var t = ""
        scan: for tok in tokens(String(first)) {
            switch tok {
            case .text(let x): t += x
            case .glyph(let g): t += glyphs[g] ?? ""
            case .open(let n, _) where !inline.contains(n): break scan
            default: break
            }
        }
        t = t.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",")))
        if t.isEmpty, let sy = s.range(of: "<SY>") {         // Thesaurus entries start with <DS>
            t = plain(String(s[sy.upperBound...].prefix { $0 != "<" && $0 != "\n" }))
        }
        return (t.replacingOccurrences(of: "·", with: ""), isCont)
    }

    /// `<CS>first<CE>last<PAR>parent` — multi-entry article span, if present.
    public static func span(_ s: String) -> (first: Int, last: Int)? {
        guard let cs = s.range(of: "<CS>"), let ce = s.range(of: "<CE>") else { return nil }
        let a = Int(s[cs.upperBound...].prefix { $0.isNumber }), b = Int(s[ce.upperBound...].prefix { $0.isNumber })
        guard let a, let b else { return nil }
        return (a, b)
    }
}
