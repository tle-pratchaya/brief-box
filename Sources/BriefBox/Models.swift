import Foundation
import SwiftData
import BriefCore

enum JobStatus: String, CaseIterable, Codable {
    case todo, doing, draftSent, revising, finalSent, done
    var label: String {
        switch self {
        case .todo: "รอเริ่ม"; case .doing: "กำลังทำ"; case .draftSent: "ส่งดราฟต์"
        case .revising: "แก้งาน"; case .finalSent: "ส่งไฟนอล"; case .done: "เสร็จ"
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum JobSource: String, Codable {
    case email, line, manual, verbal
    var label: String {
        switch self { case .email: "📧 อีเมล"; case .line: "💬 LINE"; case .manual: "✍️ เพิ่มเอง"; case .verbal: "🗣 บอกปากเปล่า" }
    }
}

enum LogKind: String, Codable, CaseIterable {
    case revision, addition, note
    var label: String { switch self { case .revision: "แก้ไข"; case .addition: "งานเพิ่ม"; case .note: "โน้ต" } }
}

@Model final class Job {
    var title: String
    var kindRaw: String
    var statusRaw: String
    var sourceRaw: String
    var isPendingReview: Bool
    var requester: String
    var requesterEmail: String
    var cc: String
    var receivedAt: Date
    var createdAt: Date
    var threadKey: String
    var briefMessageID: String?
    var picture: String?
    var notes: String
    var mySection: String?
    var bodyText: String
    var otherTeams: String
    var parserNotes: String
    var completedAt: Date?
    var statusChangedAt: Date?
    var workFolder: String?

    @Relationship(deleteRule: .cascade, inverse: \Artwork.job) var artworks: [Artwork] = []
    @Relationship(deleteRule: .cascade, inverse: \Milestone.job) var milestones: [Milestone] = []
    @Relationship(deleteRule: .cascade, inverse: \LogEntry.job) var logEntries: [LogEntry] = []
    @Relationship(deleteRule: .cascade, inverse: \CopyText.job) var copyTexts: [CopyText] = []
    @Relationship(deleteRule: .cascade, inverse: \RefItem.job) var refs: [RefItem] = []
    @Relationship(deleteRule: .cascade, inverse: \WaitingItem.job) var waiting: [WaitingItem] = []

    init(title: String, kind: JobKind, source: JobSource, pending: Bool) {
        self.title = title
        kindRaw = kind.rawValue
        statusRaw = JobStatus.todo.rawValue
        sourceRaw = source.rawValue
        isPendingReview = pending
        requester = ""; requesterEmail = ""; cc = ""
        receivedAt = Date(); createdAt = Date()
        threadKey = ""; notes = ""; bodyText = ""; otherTeams = ""; parserNotes = ""
    }

    var kind: JobKind {
        get { JobKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
    var status: JobStatus {
        get { JobStatus(rawValue: statusRaw) ?? .todo }
        set {
            if newValue.rawValue != statusRaw { statusChangedAt = Date() }
            statusRaw = newValue.rawValue
            completedAt = newValue == .done ? Date() : nil
        }
    }
    var source: JobSource { JobSource(rawValue: sourceRaw) ?? .manual }

    var sortedArtworks: [Artwork] { artworks.sorted { $0.order < $1.order } }
    var myMilestones: [Milestone] { milestones.filter { $0.team == nil }.sorted { $0.date < $1.date } }
    var otherMilestones: [Milestone] { milestones.filter { $0.team != nil }.sorted { $0.date < $1.date } }
    var sortedLog: [LogEntry] { logEntries.sorted { $0.date < $1.date } }
    var sortedCopy: [CopyText] { copyTexts.sorted { $0.order < $1.order } }
    var openWaiting: [WaitingItem] { waiting.filter { !$0.done } }

    var allFiles: [ArtFile] { artworks.flatMap(\.files) }
    var filesDone: Int { allFiles.filter(\.done).count + logEntries.filter { $0.done && $0.kind != .note }.count }
    var filesTotal: Int { allFiles.count + logEntries.filter { $0.kind != .note }.count }
    var progress: Double { filesTotal == 0 ? 0 : Double(filesDone) / Double(filesTotal) }

    /// เดดไลน์ถัดไปที่ยังต้องสนใจ (ข้ามดราฟต์แรกถ้าส่งดราฟต์แล้ว)
    var nextDue: Milestone? {
        guard status != .done else { return nil }
        guard status.rank < JobStatus.finalSent.rank else { return nil }
        let draftSent = status.rank >= JobStatus.draftSent.rank
        let relevant = myMilestones.filter { !(draftSent && $0.label == "ดราฟต์แรก") }
        let today = Calendar.current.startOfDay(for: Date())
        return relevant.first { $0.date >= today } ?? relevant.last
    }

    /// ส่งดราฟต์/ไฟนอลไปแล้วกี่วัน (ไว้เตือนให้ทวง)
    var daysWaitingReply: Int? {
        guard status == .draftSent || status == .finalSent, let d = statusChangedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                               to: Calendar.current.startOfDay(for: Date())).day
    }

    var daysLeft: Int? {
        guard let d = nextDue?.date else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                               to: Calendar.current.startOfDay(for: d)).day
    }
}

@Model final class Artwork {
    var number: Int
    var spec: String
    var size: String?
    var warning: String?
    var order: Int
    var job: Job?
    @Relationship(deleteRule: .cascade, inverse: \ArtFile.artwork) var files: [ArtFile] = []

    init(number: Int, spec: String, size: String?, warning: String?, order: Int) {
        self.number = number; self.spec = spec; self.size = size; self.warning = warning; self.order = order
    }
    var sortedFiles: [ArtFile] { files.sorted { $0.order < $1.order } }
}

@Model final class ArtFile {
    var label: String
    var done: Bool
    var order: Int
    var artwork: Artwork?
    init(label: String, order: Int) { self.label = label; done = false; self.order = order }
}

@Model final class Milestone {
    var label: String
    var date: Date
    var team: String?          // nil = ของเรา
    var reminderID: String?
    var job: Job?
    init(label: String, date: Date, team: String?) { self.label = label; self.date = date; self.team = team }
}

@Model final class LogEntry {
    var date: Date
    var kindRaw: String
    var text: String
    var sourceRaw: String
    var done: Bool
    var emailPath: String?
    var job: Job?
    init(kind: LogKind, text: String, source: JobSource, date: Date = Date()) {
        kindRaw = kind.rawValue; self.text = text; sourceRaw = source.rawValue; done = false; self.date = date
    }
    var kind: LogKind {
        get { LogKind(rawValue: kindRaw) ?? .note }
        set { kindRaw = newValue.rawValue }
    }
    var source: JobSource { JobSource(rawValue: sourceRaw) ?? .manual }
}

@Model final class CopyText {
    var title: String
    var text: String
    var order: Int
    var job: Job?
    init(title: String, text: String, order: Int) { self.title = title; self.text = text; self.order = order }
}

@Model final class RefItem {
    var kindRaw: String        // link | attachment | email
    var title: String
    var location: String       // URL หรือ path ในเครื่อง
    var job: Job?
    init(kind: String, title: String, location: String) { kindRaw = kind; self.title = title; self.location = location }
    var icon: String {
        switch kindRaw { case "link": "link"; case "email": "envelope"; default: "paperclip" }
    }
}

@Model final class WaitingItem {
    var text: String
    var done: Bool
    var job: Job?
    init(text: String) { self.text = text; done = false }
}

/// เมลตอบกลับที่ลากเข้ามา รอตรวจว่าเป็นการแก้ หรืองานเพิ่ม ของงานไหน
@Model final class PendingReply {
    var subject: String
    var threadKey: String
    var from: String
    var sentAt: Date
    var text: String
    var emailPath: String
    var inReplyTo: String?
    var waitingText: String
    var aiRevisions: String?   // AI แยกไว้ให้ (optional เพื่อให้ SwiftData migrate เอง)
    var aiAdditions: String?
    var job: Job?
    init(subject: String, threadKey: String, from: String, sentAt: Date, text: String, emailPath: String) {
        self.subject = subject; self.threadKey = threadKey; self.from = from; self.sentAt = sentAt
        self.text = text; self.emailPath = emailPath; waitingText = ""
    }
}
