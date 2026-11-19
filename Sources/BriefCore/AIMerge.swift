import Foundation

// ผลจาก AI ในรูปที่ไม่ผูกกับ FoundationModels (ทดสอบได้) + กติกาการเอามารวมกับผลของตัวแยกแบบกฎ
// หลักการ: กฎมาก่อนเสมอ AI เติมเฉพาะช่องที่ว่าง และทุกอย่างยังต้องผ่านหน้า "รอตรวจ"

public struct AIDeliverable: Sendable, Equatable {
    public var spec: String
    public var size: String?
    public var variants: [String]
    public init(spec: String, size: String? = nil, variants: [String] = []) {
        self.spec = spec; self.size = size; self.variants = variants
    }
}

public struct AIDeadline: Sendable, Equatable {
    public enum Kind: String, Sendable { case draft, final, deadline, other }
    public var kind: Kind
    public var date: String   // YYYY-MM-DD
    public var note: String?
    public var quote: String?   // ข้อความในเมลที่ AI อ้าง ใช้กรองวันที่ที่ไม่ใช่เดดไลน์
    public init(kind: Kind, date: String, note: String? = nil, quote: String? = nil) {
        self.kind = kind; self.date = date; self.note = note; self.quote = quote
    }
}

public struct AIBriefResult: Sendable, Equatable {
    public var kind: JobKind?
    public var deliverables: [AIDeliverable]
    public var deadlines: [AIDeadline]
    public var waitingFor: [String]
    public init(kind: JobKind?, deliverables: [AIDeliverable], deadlines: [AIDeadline], waitingFor: [String]) {
        self.kind = kind; self.deliverables = deliverables; self.deadlines = deadlines; self.waitingFor = waitingFor
    }
}

public struct AIReplyResult: Sendable, Equatable {
    public var revisions: [String]
    public var additions: [String]
    public var waitingFor: [String]
    public init(revisions: [String], additions: [String], waitingFor: [String]) {
        self.revisions = revisions; self.additions = additions; self.waitingFor = waitingFor
    }
}

public enum AIMerge {
    public static let noteManual = "ไม่ใช่ฟอร์ม MARCOM BRIEF ต้องกรอกชิ้นงานและเดดไลน์เอง"

    /// วันที่จาก AI: รับแค่ YYYY-MM-DD ที่อยู่ระหว่าง 14 วันก่อนเมล ถึง 400 วันหลังเมล (กัน AI เดาปีผิด)
    public static func date(_ s: String, sent: Date, calendar: Calendar) -> Date? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        guard let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let lo = sent.addingTimeInterval(-14 * 86400), hi = sent.addingTimeInterval(400 * 86400)
        return (lo...hi).contains(d) ? d : nil
    }

    static func label(_ k: AIDeadline.Kind, _ note: String?) -> String {
        switch k {
        case .draft: "ดราฟต์แรก"
        case .final: "ไฟนอล"
        case .deadline: "ส่งงาน"
        case .other: note.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "นัดหมาย"
        }
    }

    /// ประโยคที่ AI อ้างต้องมีคำบอกการส่งงาน (กันเอาวันจัดงาน/ช่วงโปรโมชันมาเป็นเดดไลน์)
    static let deadlineWords = try! NSRegularExpression(
        pattern: #"\b(by|before|deadline|due|send|submit|need(ed)?|draft|first cut|final|latest|no later|shoot(ing)?|join)\b"#,
        options: [.caseInsensitive])
    static func looksLikeDeadline(_ q: String?) -> Bool {
        guard let q, !q.isEmpty else { return true }   // ไม่มีอ้าง = ไม่ตัดสิน
        return deadlineWords.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) != nil
    }

    /// ข้อความตอบกลับที่เป็นแค่การอนุมัติ/ขอบคุณ ไม่ใช่รายการแก้
    static let approvalOnly = try! NSRegularExpression(
        pattern: #"^\W*(looks? (great|good|nice|perfect)|approved?|all good|perfect|thank(s| you)( so much)?|well done|ok(ay)?|noted)\b[\w\s,!.]*$"#,
        options: [.caseInsensitive])
    static func isApprovalOnly(_ s: String) -> Bool {
        approvalOnly.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            && s.range(of: #"\d|change|chang|move|bigger|smaller|replace|instead|add|remove|fix|but"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// รวมรายการรอข้อมูล: ตัดตัวที่ซ้ำหรือเป็นส่วนหนึ่งของข้อที่มีอยู่แล้ว
    static func mergeWaiting(_ base: [String], _ extra: [String]) -> [String] {
        var out = clean(base)
        for x in clean(extra) {
            let lx = x.lowercased()
            if out.contains(where: { $0.lowercased().contains(lx) || lx.contains($0.lowercased()) || sameWords($0, x) }) { continue }
            out.append(x)
        }
        return out
    }

    /// คำหลักของข้อสั้นอยู่ครบในข้อยาว = ข้อเดียวกัน ("photos from the pastry team" ⊂ "Photos will follow from the pastry team")
    static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        }
        let wa = words(a), wb = words(b)
        let (small, big) = wa.count <= wb.count ? (wa, wb) : (wb, wa)
        return small.count >= 2 && small.isSubset(of: big)
    }

    static func clean(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs {
            let t = x.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// เมลธรรมดา (เช่น สั่งงานวิดีโอ): AI เติมชิ้นงาน/เดดไลน์/ประเภท เฉพาะที่กฎยังว่าง
    public static func apply(_ ai: AIBriefResult, to d: inout BriefDraft, calendar: Calendar) {
        var filled: [String] = []
        if d.kind == .other, let k = ai.kind, k != .other { d.kind = k; filled.append("ประเภท") }
        let waiting = mergeWaiting(d.waitingFor, ai.waitingFor)
        let waitingLower = waiting.map { $0.lowercased() }
        if d.artworks.isEmpty {
            // ของที่ผู้สั่งจะส่งมา (โลโก้ เพลง รูป) ไม่ใช่ชิ้นงาน
            let items = ai.deliverables.prefix(20).filter { x in
                let l = x.spec.trimmingCharacters(in: .whitespaces).lowercased()
                return !l.isEmpty && !waitingLower.contains { $0.contains(l) }
                    && l.range(of: #"^(music|song|photos?|pictures?|logo|menu|text|copy)\b"#, options: .regularExpression) == nil
            }
            for (i, x) in items.enumerated() {
                let v = clean(x.variants)
                d.artworks.append(ArtworkDraft(number: i + 1, spec: x.spec.trimmingCharacters(in: .whitespaces),
                                               size: x.size.flatMap { $0.isEmpty ? nil : $0 },
                                               files: v.count > 1 ? v : ["ไฟล์"],
                                               warning: (x.size ?? "").isEmpty ? "บรีฟไม่ได้บอกขนาด" : nil))
            }
            if !d.artworks.isEmpty { filled.append("ชิ้นงาน \(d.artworks.count) ชิ้น") }
        }
        if d.deadlines.isEmpty {
            for x in ai.deadlines.prefix(6) where looksLikeDeadline(x.quote) {
                guard let date = date(x.date, sent: d.sentAt, calendar: calendar) else { continue }
                let item = DateItem(label: label(x.kind, x.note), date: date, team: nil)
                if !d.deadlines.contains(item) { d.deadlines.append(item) }
            }
            if d.deadlines.isEmpty {
                // AI ไม่ให้วันที่ → หาประโยคที่มีคำบอกการส่งงาน + วันที่ ด้วยกฎ
                let parser = BriefParser(ownerEmails: [], calendar: calendar)
                for line in BriefParser.stripQuoted(d.bodyText).components(separatedBy: CharacterSet(charactersIn: ".\n"))
                where looksLikeDeadline(line) && line.range(of: #"\b(by|before|deadline|due|send|submit|need)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    for date in parser.dates(in: line, sent: d.sentAt) {
                        let item = DateItem(label: "ส่งงาน", date: date, team: nil)
                        if !d.deadlines.contains(item) { d.deadlines.append(item) }
                    }
                }
            }
            if !d.deadlines.isEmpty { filled.append("เดดไลน์ \(d.deadlines.count) รายการ") }
        }
        let before = d.waitingFor.count
        d.waitingFor = waiting
        if d.waitingFor.count > before { filled.append("ของที่รอ \(d.waitingFor.count - before) ข้อ") }

        if !filled.isEmpty {
            d.notes.removeAll { $0 == noteManual }
            d.notes.append("🤖 AI ช่วยกรอก: " + filled.joined(separator: ", ") + " — ตรวจกับเมลก่อนกดเข้ารายการ")
        }
    }

    /// เมลตอบกลับ: AI แยกรายการแก้ / งานเพิ่ม
    public static func apply(_ ai: AIReplyResult, to d: inout BriefDraft) {
        d.aiRevisions = clean(ai.revisions).filter { !isApprovalOnly($0) }
        d.aiAdditions = clean(ai.additions)
        d.waitingFor = mergeWaiting(d.waitingFor, ai.waitingFor)
    }
}
