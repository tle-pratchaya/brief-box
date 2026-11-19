import AppKit
import Foundation
import SwiftData
import BriefCore

/// โฟลเดอร์ทำงานของแต่ละงานใน Finder
/// โครง:  <ที่เก็บงาน>/2026-11 Summer Glow Package at Lotus Studio/
///          _Brief/   (เมลต้นฉบับ, ไฟล์แนบ, brief.txt)
///          A1 4x5/  A2 1080x1080/ ...   (งานกราฟิก)
///          Footage/  Project/  Export/  (งานวิดีโอ หรืองานที่ไม่มี Artwork)
enum WorkFolder {
    static let rootKey = "workRoot"

    /// ค่าเริ่มต้นอยู่นอก Documents/Desktop เพื่อไม่ให้ไฟล์งานบริษัทถูก sync ขึ้น iCloud โดยไม่ตั้งใจ
    static var root: URL {
        if let p = UserDefaults.standard.string(forKey: rootKey), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("กล่องบรีฟ งาน", isDirectory: true)
    }

    static func folderName(for job: Job) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM"
        let when = job.myMilestones.first?.date ?? job.receivedAt
        return "\(f.string(from: when)) \(Storage.safeName(job.title))"
    }

    static func exists(_ job: Job) -> Bool {
        guard let p = job.workFolder else { return false }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
    }

    /// สร้าง (ถ้ายังไม่มี) แล้วเปิดใน Finder
    @MainActor static func open(_ job: Job, context: ModelContext) {
        let url = exists(job) ? URL(fileURLWithPath: job.workFolder!) : create(job)
        job.workFolder = url.path
        try? context.save()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func create(_ job: Job) -> URL {
        let fm = FileManager.default
        var url = root.appendingPathComponent(folderName(for: job), isDirectory: true)
        // ชื่อซ้ำกับงานอื่น → ต่อท้ายเลข
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(folderName(for: job)) (\(i))", isDirectory: true); i += 1
        }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)

        let brief = url.appendingPathComponent("_Brief", isDirectory: true)
        try? fm.createDirectory(at: brief, withIntermediateDirectories: true)
        for r in job.refs where r.kindRaw != "link" {
            let src = URL(fileURLWithPath: r.location)
            let name = r.kindRaw == "email" ? "อีเมล - \(Storage.safeName(r.title)).eml" : src.lastPathComponent
            try? fm.copyItem(at: src, to: brief.appendingPathComponent(name))
        }
        try? summary(job).write(to: brief.appendingPathComponent("brief.txt"), atomically: true, encoding: .utf8)

        let subfolders: [String]
        if job.artworks.isEmpty || job.kind == .video {
            subfolders = ["Footage", "Project", "Export"]
        } else {
            subfolders = job.sortedArtworks.map { a in
                let size = ExportName.sizeToken(a.size)
                return size.isEmpty ? "A\(a.number)" : "A\(a.number) \(size)"
            } + ["Export"]
        }
        for s in subfolders { try? fm.createDirectory(at: url.appendingPathComponent(s, isDirectory: true), withIntermediateDirectories: true) }
        return url
    }

    /// สรุปบรีฟเป็นข้อความ เปิดอ่านได้จาก Finder
    static func summary(_ job: Job) -> String {
        var lines = ["# \(job.title)", "ผู้สั่ง: \(job.requester)", "ได้รับ: \(Fmt.date(job.receivedAt))", ""]
        if !job.myMilestones.isEmpty {
            lines.append("## เดดไลน์")
            lines += job.myMilestones.map { "- \($0.label): \(Fmt.date($0.date))" }
            lines.append("")
        }
        if !job.artworks.isEmpty {
            lines.append("## ชิ้นงาน")
            for a in job.sortedArtworks {
                lines.append("- A\(a.number): \(a.spec)")
                for f in a.sortedFiles {
                    lines.append("    - \(f.label) → \(ExportName.make(job: job.title, number: a.number, size: a.size, variant: f.label, pattern: exportPattern))")
                }
            }
            lines.append("")
        }
        if let p = job.picture { lines += ["ภาพ: \(p)", ""] }
        for c in job.sortedCopy { lines += ["## \(c.title)", c.text, ""] }
        return lines.joined(separator: "\n")
    }

    static var exportPattern: String {
        let p = UserDefaults.standard.string(forKey: "exportPattern") ?? ""
        return p.isEmpty ? ExportName.defaultPattern : p
    }
}
