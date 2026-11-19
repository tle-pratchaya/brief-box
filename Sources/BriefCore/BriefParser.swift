import Foundation

// MARK: - ผลลัพธ์ที่แยกได้จากอีเมล (ยังไม่ลงฐานข้อมูล)

public enum JobKind: String, Codable, CaseIterable, Sendable {
    case graphic, video, other
    public var label: String {
        switch self { case .graphic: "กราฟิก"; case .video: "วิดีโอ"; case .other: "อื่นๆ" }
    }
}

public struct ArtworkDraft: Equatable, Sendable {
    public var number: Int
    public var spec: String
    public var size: String?          // "1080×1350", "A4", "4:5"
    public var files: [String]        // ไฟล์ย่อยที่ต้องส่ง เช่น ["แนวนอน","แนวตั้ง"] หรือ ["ไฟล์"]
    public var warning: String?       // สเปกที่บรีฟไม่ได้บอก
}

public struct DateItem: Equatable, Sendable {
    public var label: String          // "ส่งงาน", "ดราฟต์แรก", "ไฟนอล", หรือข้อความของทีมอื่น
    public var date: Date
    public var team: String?          // nil = ของเราเอง
}

public struct CopyBlock: Equatable, Sendable {
    public var title: String
    public var text: String
}

public struct LinkItem: Equatable, Sendable {
    public var title: String
    public var url: String
}

/// ร่างการ์ดงาน ผลจากการแยกอีเมล 1 ฉบับ
public struct BriefDraft: Sendable {
    public enum Source: String, Sendable { case marcomBrief, reply, plainEmail }

    public var source: Source
    public var title: String
    public var kind: JobKind
    public var requester: String
    public var requesterEmail: String
    public var cc: [String]
    public var sentAt: Date
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var threadKey: String         // หัวเรื่องที่ตัด RE:/FW: แล้ว ใช้จับคู่เมลตอบกลับ
    public var mentionsMe: Bool
    public var myRole: String?
    public var mySection: String?        // ข้อความเฉพาะส่วนของเรา (ไว้ไฮไลต์)
    public var otherTeams: [String]
    public var artworks: [ArtworkDraft]
    public var deadlines: [DateItem]
    public var usedOn: [DateItem]
    public var picture: String?
    public var waitingFor: [String]
    public var copyBlocks: [CopyBlock]
    public var links: [LinkItem]
    public var attachments: [Attachment]
    public var bodyText: String          // ตัวเมลทั้งหมด (สำหรับแสดงเทียบ)
    public var replyText: String?        // ส่วนบนของเมลตอบกลับ (ตัดข้อความเก่าที่ถูกอ้างออก)
    public var notes: [String]           // ข้อสังเกตจากตัวแยก
    public var aiRevisions: [String]? = nil   // เมลตอบกลับ: AI แยกเป็นรายการแก้ (ต้องผ่านรอตรวจ)
    public var aiAdditions: [String]? = nil   // เมลตอบกลับ: AI แยกเป็นงานเพิ่ม
}

extension Attachment: @unchecked Sendable {}

// MARK: - ตัวแยกแบบกฎ

public struct BriefParser {
    /// อีเมลของเจ้าของแอป ใช้หาส่วน "Graphic: @ชื่อเรา"
    public var ownerEmails: [String]
    public var calendar: Calendar

    public init(ownerEmails: [String], calendar: Calendar = .init(identifier: .gregorian)) {
        self.ownerEmails = ownerEmails.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        self.calendar = cal
    }

    static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    // "Graphic: @Designer, Ploy<mailto:x@y>"
    static let sectionRegex = try! NSRegularExpression(
        pattern: #"^(?<role>[A-Z][\w &/]+?):\s*@(?<name>[^<\n]+)<mailto:(?<mail>[^>]+)>"#,
        options: [.anchorsMatchLines])
    static let artworkRegex = try! NSRegularExpression(
        pattern: #"^\s*Artwork\s+(?<n>\d+)\s*:\s*(?<spec>.+)$"#, options: [.anchorsMatchLines, .caseInsensitive])
    static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(?<d>\d{1,2})(?:st|nd|rd|th)?\s+(?<m>Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\b\.?,?(?:\s+(?<y>\d{4}))?"#,
        options: [.caseInsensitive])
    static let pendingRegex = try! NSRegularExpression(
        pattern: #"[^.\n]*(share with you later|let me check|to be confirmed|\bTBC\b|will send|will share|will follow|to follow|send later)[^.\n]*"#,
        options: [.caseInsensitive])
    static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"]+"#)
    static let pxRegex = try! NSRegularExpression(pattern: #"(\d{3,5})\s*[x×]\s*(\d{3,5})\s*(px)?"#, options: [.caseInsensitive])
    static let ratioRegex = try! NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{1,2})\b"#)
    static let paperRegex = try! NSRegularExpression(pattern: #"\bA[0-6]\b"#)

    public func parse(_ msg: MIMEMessage) -> BriefDraft {
        let subject = msg.subject
        let body = msg.bodyText.replacingOccurrences(of: "\r", with: "")
        let sent = msg.date ?? Date()
        let threadKey = Self.threadKey(subject)
        let isReply = msg.inReplyTo != nil || Self.hasReplyPrefix(subject)
        let isBrief = threadKey.uppercased().hasPrefix("MARCOM BRIEF")
        let from = msg.from

        var d = BriefDraft(
            source: isReply ? .reply : (isBrief ? .marcomBrief : .plainEmail),
            title: Self.cleanTitle(threadKey),
            kind: isBrief ? .graphic : .other,
            requester: from?.displayName ?? "",
            requesterEmail: from?.email ?? "",
            cc: msg.cc.map(\.displayName),
            sentAt: sent,
            messageID: msg.messageID,
            inReplyTo: msg.inReplyTo,
            references: msg.references,
            threadKey: threadKey,
            mentionsMe: msg.mentions.contains { ownerEmails.contains($0) },
            myRole: nil, mySection: nil, otherTeams: [],
            artworks: [], deadlines: [], usedOn: [], picture: nil, waitingFor: [],
            copyBlocks: [], links: [], attachments: msg.attachments.filter { !Self.isInlineJunk($0) },
            bodyText: body, replyText: nil, notes: [])

        d.links = Self.links(in: body)

        if isReply {
            d.replyText = Self.stripQuoted(body)
            d.waitingFor = matches(Self.pendingRegex, in: d.replyText ?? "")
            return d
        }

        // แยกส่วนของแต่ละทีม
        let ns = body as NSString
        let sections = Self.sectionRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var mine: (role: String, text: String)?
        for (i, s) in sections.enumerated() {
            let role = ns.substring(with: s.range(withName: "role")).trimmingCharacters(in: .whitespaces)
            let name = ns.substring(with: s.range(withName: "name")).trimmingCharacters(in: .whitespaces)
            let mail = ns.substring(with: s.range(withName: "mail")).lowercased()
            let start = s.range.location + s.range.length
            let end = i + 1 < sections.count ? sections[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: start, length: end - start))
            if ownerEmails.contains(mail) {
                mine = (role, text)
            } else {
                d.otherTeams.append("\(role) → \(MIMEMessage.Address(name: name, email: mail).displayName)")
                for line in text.components(separatedBy: "\n") {
                    let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: " *•\t"))
                    guard !clean.isEmpty, !Self.isCopyHeader(clean) else { continue }
                    if let date = dates(in: clean, sent: sent).first,
                       !d.usedOn.contains(where: { $0.label == clean }) {
                        d.usedOn.append(DateItem(label: String(clean.prefix(100)), date: date, team: role))
                    }
                }
            }
        }

        if let mine {
            d.myRole = mine.role
            d.mySection = mine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            d.kind = mine.role.range(of: "video|vdo|motion|clip", options: [.regularExpression, .caseInsensitive]) != nil ? .video : .graphic
            parseMySection(mine.text, sent: sent, into: &d)
        } else if isBrief {
            d.notes.append(ownerEmails.isEmpty
                ? "ยังไม่ได้ตั้งอีเมลของเราในหน้าตั้งค่า จึงหาส่วนของเราไม่เจอ"
                : "บรีฟนี้ไม่มีส่วนที่ @ ถึงเรา")
            // ถ้าไม่มีส่วนแยก ลองหา Artwork ทั้งเมล
            parseMySection(body, sent: sent, into: &d)
        }

        d.copyBlocks = Self.copyBlocks(in: body)
        d.waitingFor = matches(Self.pendingRegex, in: body)
        if d.source == .plainEmail {
            d.notes.append("ไม่ใช่ฟอร์ม MARCOM BRIEF ต้องกรอกชิ้นงานและเดดไลน์เอง")
        }
        return d
    }

    func parseMySection(_ text: String, sent: Date, into d: inout BriefDraft) {
        let ns = text as NSString
        for m in Self.artworkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = Int(ns.substring(with: m.range(withName: "n"))) ?? 0
            let spec = ns.substring(with: m.range(withName: "spec")).trimmingCharacters(in: .whitespaces)
            d.artworks.append(Self.artwork(n, spec))
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("picture") || t.lowercased().hasPrefix("photo") || t.lowercased().hasPrefix("image") {
                if let colon = t.firstIndex(of: ":") { d.picture = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            guard t.range(of: "deadline|draft|due|submit|send by", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            for piece in t.components(separatedBy: "/") {
                guard let date = dates(in: piece, sent: sent).first else { continue }
                let label: String
                if piece.range(of: "final", options: .caseInsensitive) != nil { label = "ไฟนอล" }
                else if piece.range(of: "first|1st|draft", options: [.regularExpression, .caseInsensitive]) != nil { label = "ดราฟต์แรก" }
                else { label = "ส่งงาน" }
                d.deadlines.append(DateItem(label: label, date: date, team: nil))
            }
        }
    }

    static func artwork(_ n: Int, _ spec: String) -> ArtworkDraft {
        var size: String?
        let ns = spec as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = pxRegex.firstMatch(in: spec, range: full) {
            size = "\(ns.substring(with: m.range(at: 1)))×\(ns.substring(with: m.range(at: 2)))"
        } else if let m = paperRegex.firstMatch(in: spec, range: full) {
            size = ns.substring(with: m.range)
        } else if let m = ratioRegex.firstMatch(in: spec, range: full) {
            size = ns.substring(with: m.range)
        }

        var files: [String] = []
        let lower = spec.lowercased()
        if lower.contains("horizontal and vertical") || lower.contains("vertical and horizontal") { files += ["แนวนอน", "แนวตั้ง"] }
        if lower.contains("printed and digital") || lower.contains("print and digital") { files += ["ไฟล์พิมพ์", "ไฟล์ดิจิทัล"] }
        if lower.contains(" en ") || lower.contains("(en") || lower.contains("th and en") || lower.contains("en and th") {
            if lower.contains("th") { files += ["EN", "TH"] }
        }
        let multiple = lower.contains("variety") || lower.contains("multiple") || lower.contains("options")
        if files.isEmpty { files = multiple ? ["แบบ 1", "แบบ 2"] : ["ไฟล์"] }

        var warnings: [String] = []
        if multiple { warnings.append("ต้องการกี่แบบ?") }
        if size == nil {
            if lower.contains("lcd") || lower.contains("screen") { warnings.append("ขนาดจอ LCD กี่ px?") }
            else if lower.contains("story") { size = "1080×1920" }
            else { warnings.append("ยังไม่ระบุขนาด") }
        } else if let s = size, s.contains(":") {
            let guess = ["4:5": "1080×1350", "1:1": "1080×1080", "9:16": "1080×1920", "16:9": "1920×1080"][s]
            warnings.append(guess.map { "\(s) ใช้ \($0) ไหม?" } ?? "\(s) กี่ px?")
        }
        return ArtworkDraft(number: n, spec: spec, size: size, files: files,
                            warning: warnings.isEmpty ? nil : warnings.joined(separator: " · "))
    }

    /// หาวันที่ทั้งหมดในบรรทัด ถ้าไม่มีปีและวันนั้นอยู่ก่อนวันส่งเมลเกิน 30 วัน ให้เป็นปีถัดไป
    public func dates(in line: String, sent: Date) -> [Date] {
        let ns = line as NSString
        let sentYear = calendar.component(.year, from: sent)
        return Self.dateRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let day = Int(ns.substring(with: m.range(withName: "d"))) ?? 1
            let monKey = String(ns.substring(with: m.range(withName: "m")).lowercased().prefix(3))
            guard let month = Self.months[monKey], (1...31).contains(day) else { return nil }
            let yr = m.range(withName: "y").location != NSNotFound ? Int(ns.substring(with: m.range(withName: "y"))) : nil
            var comps = DateComponents(year: yr ?? sentYear, month: month, day: day, hour: 17)
            guard var date = calendar.date(from: comps) else { return nil }
            if yr == nil, date < sent.addingTimeInterval(-30 * 86400) {
                comps.year = sentYear + 1
                date = calendar.date(from: comps) ?? date
            }
            return date
        }
    }

    func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let s = ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: " *•\t"))
            return seen.insert(s).inserted ? s : nil
        }
    }

    // MARK: - ตัวช่วย

    static let copyHeaders = ["short text", "long text", "agenda", "caption", "copy", "headline", "package prices", "key message"]

    static func isCopyHeader(_ line: String) -> Bool {
        let l = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return copyHeaders.contains { l == $0 || l.hasPrefix($0 + " -") || (l.hasPrefix($0) && l.count < $0.count + 40 && $0 == "agenda") }
    }

    /// ก้อนข้อความที่ต้องใส่ในงาน เช่น Short Text / Long Text / Agenda
    static func copyBlocks(in body: String) -> [CopyBlock] {
        let lines = body.components(separatedBy: "\n")
        let mainHeaders = ["short text", "long text", "agenda", "caption", "headline", "key message"]
        var blocks: [CopyBlock] = []
        var current: (String, [String])?
        func flush() {
            if let c = current {
                let text = c.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                if !text.isEmpty { blocks.append(CopyBlock(title: c.0, text: text)) }
            }
            current = nil
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            let l = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if let h = mainHeaders.first(where: { l == $0 || (l.hasPrefix($0) && $0 == "agenda") }) {
                flush()
                current = (h == "agenda" ? t.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) : h.capitalized, [])
                continue
            }
            // ส่วนของทีมถัดไปตัดก้อนข้อความ
            if sectionRegex.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil { flush(); continue }
            current?.1.append(line)
        }
        flush()
        return blocks
    }

    static func links(in body: String) -> [LinkItem] {
        let ns = body as NSString
        var seen = Set<String>()
        var out: [LinkItem] = []
        for m in urlRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ">).,"))
            guard seen.insert(url).inserted else { continue }
            // ชื่อลิงก์: ข้อความก่อน <url> ในบรรทัดเดียวกัน (รูปแบบของ Outlook text/plain)
            let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: m.range.location)).location
            let from = lineStart == NSNotFound ? 0 : lineStart + 1
            var label = ns.substring(with: NSRange(location: from, length: m.range.location - from))
                .trimmingCharacters(in: CharacterSet(charactersIn: " <\t"))
            if label.isEmpty || label.count > 80 { label = Self.host(url) }
            out.append(LinkItem(title: label, url: url))
        }
        return out
    }

    static func host(_ url: String) -> String {
        guard let h = URL(string: url)?.host else { return url }
        if h.contains("sharepoint") { return "ไฟล์ SharePoint" }
        if h.contains("linkedin") { return "ตัวอย่างโพสต์ LinkedIn" }
        return h
    }

    public static func hasReplyPrefix(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).range(of: #"^(re|fw|fwd|ตอบกลับ|ส่งต่อ)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// ตัด RE:/FW: ซ้อนๆ ออก ใช้เป็นกุญแจจับคู่เธรด
    public static func threadKey(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        while let r = s.range(of: #"^(re|fw|fwd|ตอบกลับ|ส่งต่อ)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func cleanTitle(_ s: String) -> String {
        s.replacingOccurrences(of: #"^MARCOM BRIEF\s*[:\-–]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// ตัดข้อความเก่าที่ถูกอ้างอยู่ใต้เมลตอบกลับ
    public static func stripQuoted(_ body: String) -> String {
        let markers = [#"(?m)^_{5,}"#, #"(?m)^-{3,}\s*Original Message"#, #"(?m)^From:\s.+\n(Sent|Date):"#, #"(?m)^On .+ wrote:$"#, #"(?m)^>"#]
        var cut = body.endIndex
        for p in markers {
            if let r = body.range(of: p, options: .regularExpression), r.lowerBound < cut { cut = r.lowerBound }
        }
        return String(body[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isInlineJunk(_ a: Attachment) -> Bool {
        // รูปลายเซ็นเล็กๆ ในเมล
        a.contentType.hasPrefix("image/") && a.data.count < 15_000 && a.filename.lowercased().hasPrefix("image0")
    }
}
