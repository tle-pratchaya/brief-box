import Foundation

/// ตัวอ่านไฟล์ .eml แบบเบาๆ (RFC 5322 + MIME) พอสำหรับเมลจาก Outlook/Exchange
/// ทำงานกับ byte ผ่าน ISO-8859-1 (1 byte = 1 ตัวอักษร) แล้วค่อยถอด charset ทีหลัง
public struct MIMEPart {
    public var headers: [(name: String, value: String)]
    public var body: String            // byte ดิบในรูป latin1 (ยังไม่ถอด transfer-encoding)
    public var children: [MIMEPart]

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// ค่าหลักของ header เช่น "text/plain" จาก "text/plain; charset=..."
    public func mainValue(_ name: String) -> String? {
        header(name)?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    public func parameter(_ header: String, _ key: String) -> String? {
        guard let raw = self.header(header) else { return nil }
        return MIMEMessage.parameters(raw)[key.lowercased()]
    }

    public var contentType: String { mainValue("Content-Type") ?? "text/plain" }
    public var charset: String { parameter("Content-Type", "charset") ?? "us-ascii" }

    public var filename: String? {
        parameter("Content-Disposition", "filename") ?? parameter("Content-Type", "name")
    }

    public var isAttachment: Bool {
        if mainValue("Content-Disposition") == "attachment" { return true }
        return filename != nil && !contentType.hasPrefix("multipart/")
    }

    /// byte หลังถอด base64 / quoted-printable
    public var decodedData: Data {
        let raw = Data(body.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        switch (header("Content-Transfer-Encoding") ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let cleaned = body.filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? raw
        case "quoted-printable":
            return MIMEMessage.decodeQuotedPrintable(body)
        default:
            return raw
        }
    }

    public var decodedText: String {
        MIMEMessage.string(from: decodedData, charset: charset)
    }

    /// ไล่ทุก part ในต้นไม้ (รวมตัวเอง)
    public func walk() -> [MIMEPart] {
        [self] + children.flatMap { $0.walk() }
    }
}

public struct Attachment {
    public let filename: String
    public let contentType: String
    public let data: Data
}

public struct MIMEMessage {
    public let root: MIMEPart
    public let rawData: Data

    public init(data: Data) {
        rawData = data
        let text = (String(data: data, encoding: .isoLatin1) ?? "")
        root = MIMEMessage.parsePart(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    public init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url))
    }

    // MARK: - ค่าที่ใช้บ่อย

    public func header(_ name: String) -> String? {
        root.header(name).map { MIMEMessage.decodeEncodedWords($0) }
    }

    public var subject: String { header("Subject") ?? "" }
    public var messageID: String? { root.header("Message-ID")?.trimmingCharacters(in: .whitespaces) }
    public var inReplyTo: String? { root.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces) }
    public var references: [String] {
        (root.header("References") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }
    public var threadTopic: String? { header("Thread-Topic") }
    public var date: Date? {
        guard let raw = root.header("Date") else { return nil }
        return MIMEMessage.parseDate(raw)
    }
    public var from: Address? { MIMEMessage.addresses(header("From") ?? "").first }
    public var to: [Address] { MIMEMessage.addresses(header("To") ?? "") }
    public var cc: [Address] { MIMEMessage.addresses(header("CC") ?? "") }
    /// Outlook ใส่อีเมลของคนที่ถูก @mention ไว้ใน header นี้
    public var mentions: [String] {
        (root.header("X-Mentions") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    public var plainText: String? {
        root.walk().first { $0.contentType == "text/plain" && !$0.isAttachment }?.decodedText
    }

    public var htmlText: String? {
        root.walk().first { $0.contentType == "text/html" && !$0.isAttachment }?.decodedText
    }

    /// ข้อความตัวเมล: ใช้ text/plain ถ้ามี ไม่งั้นแปลง HTML เป็นข้อความ
    public var bodyText: String {
        if let p = plainText, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return p }
        return MIMEMessage.htmlToText(htmlText ?? "")
    }

    public var attachments: [Attachment] {
        root.walk().filter { $0.isAttachment }.map {
            Attachment(filename: MIMEMessage.decodeEncodedWords($0.filename ?? "attachment"),
                       contentType: $0.contentType, data: $0.decodedData)
        }
    }

    // MARK: - การแยกโครงสร้าง

    static func parsePart(_ text: String) -> MIMEPart {
        let headerEnd = text.range(of: "\n\n")
        let headerBlock = headerEnd.map { String(text[..<$0.lowerBound]) } ?? text
        let body = headerEnd.map { String(text[$0.upperBound...]) } ?? ""
        let headers = parseHeaders(headerBlock)
        var part = MIMEPart(headers: headers, body: body, children: [])
        if part.contentType.hasPrefix("multipart/"), let boundary = part.parameter("Content-Type", "boundary") {
            part.children = splitMultipart(body, boundary: boundary).map(parsePart)
        }
        return part
    }

    static func parseHeaders(_ block: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        for line in block.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t" {
                if !result.isEmpty { result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces) }
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result.append((name, value))
            }
        }
        return result
    }

    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [Substring]? = nil
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == delimiter || trimmed == delimiter + "--" {
                if let c = current { parts.append(c.joined(separator: "\n")) }
                current = trimmed.hasSuffix("--") && trimmed != delimiter ? nil : []
                if trimmed == delimiter + "--" { break }
            } else {
                current?.append(line)
            }
        }
        return parts
    }

    public static func parameters(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        // แยกด้วย ; ที่ไม่อยู่ในเครื่องหมายคำพูด
        var pieces: [String] = []
        var cur = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote { pieces.append(cur); cur = "" } else { cur.append(ch) }
        }
        pieces.append(cur)
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            // RFC 2231: filename*=utf-8''%E0%B8...
            if key.hasSuffix("*") {
                key.removeLast()
                let segs = value.components(separatedBy: "'")
                if segs.count >= 3 {
                    let charset = segs[0]
                    let encoded = segs[2...].joined(separator: "'")
                    var bytes = Data()
                    var i = encoded.startIndex
                    while i < encoded.endIndex {
                        if encoded[i] == "%", let j = encoded.index(i, offsetBy: 3, limitedBy: encoded.endIndex),
                           let b = UInt8(encoded[encoded.index(after: i)..<j], radix: 16) {
                            bytes.append(b); i = j
                        } else {
                            bytes.append(contentsOf: Array(String(encoded[i]).utf8)); i = encoded.index(after: i)
                        }
                    }
                    value = string(from: bytes, charset: charset.isEmpty ? "utf-8" : charset)
                }
            }
            out[key] = value
        }
        return out
    }

    // MARK: - การถอดรหัส

    public static func decodeQuotedPrintable(_ s: String) -> Data {
        var out = Data()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "=" {
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 2; continue }        // soft line break
                if i + 2 < scalars.count, let b = UInt8(String(scalars[i + 1]) + String(scalars[i + 2]), radix: 16) {
                    out.append(b); i += 3; continue
                }
            }
            out.append(UInt8(truncatingIfNeeded: c.value))
            i += 1
        }
        return out
    }

    public static func string(from data: Data, charset: String) -> String {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        var encoding: String.Encoding = .utf8
        if name == "utf-8" || name == "utf8" {
            encoding = .utf8
        } else if name == "us-ascii" || name == "ascii" {
            // ascii จริงๆ มักเป็น utf-8 หรือ latin1 ปน ลอง utf-8 ก่อน
            encoding = .utf8
        } else {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
        }
        if let s = String(data: data, encoding: encoding) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return (String(data: data, encoding: .isoLatin1) ?? "")
    }

    /// RFC 2047: =?charset?Q?...?= และ =?charset?B?...?=
    public static func decodeEncodedWords(_ s: String) -> String {
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var out = ""
        var last = 0
        for m in matches {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // ช่องว่างระหว่าง encoded word สองตัวติดกันให้ทิ้ง
            if !(last > 0 && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data
            if enc == "B" {
                data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                data = decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "))
            }
            out += string(from: data, charset: charset)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func parseDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    public struct Address: Hashable {
        public let name: String
        public let email: String
        /// "Writer, Nok" → "Nok Writer"
        public var displayName: String {
            let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { return "\(parts[1]) \(parts[0])" }
            return name.isEmpty ? email : name
        }
    }

    public static func addresses(_ raw: String) -> [Address] {
        // ตัดด้วย , ที่ไม่อยู่ใน "..."
        var items: [String] = []
        var cur = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle() }
            if ch == "," && !inQuote { items.append(cur); cur = "" } else { cur.append(ch) }
        }
        items.append(cur)
        return items.compactMap { item in
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let email = String(t[t.index(after: lt)..<gt])
                let name = t[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
                return Address(name: name, email: email)
            }
            return Address(name: "", email: t)
        }
    }

    /// แปลง HTML เป็นข้อความแบบง่าย (สำรองเมื่อไม่มี text/plain)
    public static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<(style|script|head)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|li|tr|h\d)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
