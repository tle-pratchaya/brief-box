import Foundation
import SwiftData
import BriefCore

/// จุดเสียบ AI: วันที่ใช้ AI ได้ เพิ่ม struct ใหม่ที่ทำตาม protocol นี้ แล้วสลับใน AppSettings.enhancer
/// ส่วนอื่นของแอปไม่ต้องแก้
protocol BriefEnhancer {
    var name: String { get }
    func enhance(_ draft: BriefDraft) async -> BriefDraft
}

struct NoAIEnhancer: BriefEnhancer {
    let name = "ไม่ใช้ AI (กฎอย่างเดียว)"
    func enhance(_ draft: BriefDraft) async -> BriefDraft { draft }
}

enum AppSettings {
    static var ownerEmails: [String] {
        (UserDefaults.standard.string(forKey: "ownerEmails") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }
    /// สวิตช์ในตั้งค่า (ค่าเริ่มต้น = เปิด) + เครื่อง/บัญชีนี้ต้องมี Apple Intelligence พร้อม
    static var aiOn: Bool { UserDefaults.standard.object(forKey: "aiOn") as? Bool ?? true }
    static var enhancer: BriefEnhancer { aiOn && AppleFMEnhancer.isAvailable ? AppleFMEnhancer() : NoAIEnhancer() }
}

enum Storage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BriefBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// โฟลเดอร์ใหม่สำหรับเมล 1 ฉบับ เก็บ .eml ต้นฉบับ + ไฟล์แนบ
    static func newFolder() -> URL {
        let f = root.appendingPathComponent("files/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }
}

enum ImportResult {
    case newJob(Job)
    case reply(PendingReply)
    case duplicate(String)
    case failed(String)

    var message: String {
        switch self {
        case .newJob(let j): "เพิ่ม \"\(j.title)\" เข้ารอตรวจแล้ว"
        case .reply(let r): r.job != nil ? "เมลตอบกลับของ \"\(r.job!.title)\" รอตรวจ" : "เมลตอบกลับรอตรวจ (ยังไม่รู้ว่าของงานไหน)"
        case .duplicate(let t): "\"\(t)\" มีอยู่แล้ว ไม่ได้เพิ่มซ้ำ"
        case .failed(let e): e
        }
    }
}

@MainActor
struct Importer {
    let context: ModelContext

    func importEmail(at url: URL) async -> ImportResult {
        guard let data = try? Data(contentsOf: url) else { return .failed("เปิดไฟล์ \(url.lastPathComponent) ไม่ได้") }
        return await importEmail(data: data, filename: url.lastPathComponent)
    }

    func importEmail(data: Data, filename: String) async -> ImportResult {
        let msg = MIMEMessage(data: data)
        guard msg.root.header("From") != nil || msg.root.header("Subject") != nil else {
            return .failed("\(filename) ไม่ใช่ไฟล์อีเมล (.eml)")
        }
        var draft = BriefParser(ownerEmails: AppSettings.ownerEmails).parse(msg)
        draft = await AppSettings.enhancer.enhance(draft)

        // กันลากฉบับเดิมซ้ำ
        if let id = draft.messageID, !id.isEmpty {
            let all = (try? context.fetch(FetchDescriptor<Job>())) ?? []
            if let dup = all.first(where: { $0.briefMessageID == id }) { return .duplicate(dup.title) }
            let replies = (try? context.fetch(FetchDescriptor<PendingReply>())) ?? []
            if replies.contains(where: { $0.emailPath.contains(id.filter { $0.isLetter || $0.isNumber }) }) { return .duplicate(draft.title) }
            let logs = (try? context.fetch(FetchDescriptor<LogEntry>())) ?? []
            if logs.contains(where: { ($0.emailPath ?? "").contains(id.filter { $0.isLetter || $0.isNumber }) }) { return .duplicate(draft.title) }
        }

        let folder = Storage.newFolder()
        let idTag = (draft.messageID ?? UUID().uuidString).filter { $0.isLetter || $0.isNumber }.prefix(40)
        let emlURL = folder.appendingPathComponent("email-\(idTag).eml")
        try? data.write(to: emlURL)

        if draft.source == .reply {
            let r = PendingReply(subject: msg.subject, threadKey: draft.threadKey, from: draft.requester,
                                 sentAt: draft.sentAt, text: draft.replyText ?? draft.bodyText, emailPath: emlURL.path)
            r.inReplyTo = draft.inReplyTo
            r.waitingText = draft.waitingFor.joined(separator: "\n")
            r.aiRevisions = draft.aiRevisions?.joined(separator: "\n")
            r.aiAdditions = draft.aiAdditions?.joined(separator: "\n")
            r.job = matchJob(for: draft)
            context.insert(r)
            saveAttachments(draft, to: folder, job: r.job)
            try? context.save()
            return .reply(r)
        }

        let job = Job(title: draft.title.isEmpty ? "(ไม่มีหัวเรื่อง)" : draft.title, kind: draft.kind, source: .email, pending: true)
        job.requester = draft.requester
        job.requesterEmail = draft.requesterEmail
        job.cc = draft.cc.joined(separator: ", ")
        job.receivedAt = draft.sentAt
        job.threadKey = draft.threadKey
        job.briefMessageID = draft.messageID
        job.picture = draft.picture
        job.mySection = draft.mySection
        job.bodyText = draft.bodyText
        job.otherTeams = draft.otherTeams.joined(separator: "\n")
        job.parserNotes = draft.notes.joined(separator: "\n")
        context.insert(job)

        for (i, a) in draft.artworks.enumerated() {
            let art = Artwork(number: a.number, spec: a.spec, size: a.size, warning: a.warning, order: i)
            context.insert(art)
            art.job = job
            for (k, f) in a.files.enumerated() {
                let file = ArtFile(label: f, order: k)
                context.insert(file)
                file.artwork = art
            }
        }
        for d in draft.deadlines { let m = Milestone(label: d.label, date: d.date, team: nil); context.insert(m); m.job = job }
        for d in draft.usedOn { let m = Milestone(label: d.label, date: d.date, team: d.team); context.insert(m); m.job = job }
        for (i, c) in draft.copyBlocks.enumerated() { let t = CopyText(title: c.title, text: c.text, order: i); context.insert(t); t.job = job }
        for w in draft.waitingFor { let w = WaitingItem(text: w); context.insert(w); w.job = job }
        for l in draft.links { let r = RefItem(kind: "link", title: l.title, location: l.url); context.insert(r); r.job = job }
        let mail = RefItem(kind: "email", title: "เมลต้นฉบับ (\(Self.shortDate(draft.sentAt)))", location: emlURL.path)
        context.insert(mail); mail.job = job
        saveAttachments(draft, to: folder, job: job)
        try? context.save()
        return .newJob(job)
    }

    func saveAttachments(_ draft: BriefDraft, to folder: URL, job: Job?) {
        for a in draft.attachments {
            let url = folder.appendingPathComponent(Storage.safeName(a.filename))
            try? a.data.write(to: url)
            if let job {
                let r = RefItem(kind: "attachment", title: a.filename, location: url.path)
                context.insert(r); r.job = job
            }
        }
    }

    /// หางานเดิมของเมลตอบกลับ: Message-ID ก่อน แล้วค่อยหัวเรื่อง
    func matchJob(for draft: BriefDraft) -> Job? {
        let jobs = (try? context.fetch(FetchDescriptor<Job>())) ?? []
        let ids = Set(([draft.inReplyTo].compactMap { $0 }) + draft.references)
        if let j = jobs.first(where: { $0.briefMessageID.map(ids.contains) ?? false }) { return j }
        let key = draft.threadKey.lowercased()
        return jobs.first { !$0.threadKey.isEmpty && $0.threadKey.lowercased() == key }
    }

    /// เพิ่มงานจากข้อความที่วางมา (เช่น LINE) หรือพิมพ์เอง
    func addManual(title: String, kind: JobKind, source: JobSource, text: String, due: Date?) -> Job {
        let job = Job(title: title.isEmpty ? "งานใหม่" : title, kind: kind, source: source, pending: false)
        job.bodyText = text
        job.notes = text
        context.insert(job)
        if let due { let m = Milestone(label: "ส่งงาน", date: due, team: nil); context.insert(m); m.job = job }
        try? context.save()
        return job
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar.current
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}
