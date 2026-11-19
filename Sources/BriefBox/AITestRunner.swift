import Foundation
import BriefCore

/// โหมดทดสอบ AI แบบไม่แตะฐานข้อมูล: ถ้ามี /Users/Shared/BriefBox-ai-test/*.eml ตอนเปิดแอป
/// จะให้ AI อ่านแต่ละฉบับแล้วเขียนผลเป็น <ชื่อ>.result.txt ข้างกัน (ใช้ตรวจผลผ่าน ssh จากบัญชีอื่นได้)
enum AITestRunner {
    static let dir = URL(fileURLWithPath: "/Users/Shared/BriefBox-ai-test")

    nonisolated(unsafe) static var running = false

    static func runIfRequested() {
        guard !running else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "eml" }), !files.isEmpty else { return }
        let pending = files.filter { !fm.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("result.txt").path) }
        guard !pending.isEmpty else { return }
        running = true
        Task.detached {
            defer { running = false }
            let enhancer = AppleFMEnhancer()
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let out = f.deletingPathExtension().appendingPathExtension("result.txt")
                if fm.fileExists(atPath: out.path) { continue }
                guard let data = try? Data(contentsOf: f) else { continue }
                let rule = BriefParser(ownerEmails: AppSettings.ownerEmails).parse(MIMEMessage(data: data))
                let t0 = Date()
                let ai = AppleFMEnhancer.isAvailable ? await enhancer.enhance(rule) : rule
                let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
                var s = "file: \(f.lastPathComponent)\nuser: \(NSUserName())  available: \(AppleFMEnhancer.isAvailable)  time: \(secs)s\n"
                s += "source: \(ai.source.rawValue)  kind: \(rule.kind.rawValue) -> \(ai.kind.rawValue)\n"
                s += "artworks:\n" + ai.artworks.map { "  \($0.number). \($0.spec) | size=\($0.size ?? "-") | files=\($0.files) | warn=\($0.warning ?? "-")" }.joined(separator: "\n") + "\n"
                s += "deadlines:\n" + ai.deadlines.map { "  \($0.label): \(AppleFMEnhancer.iso($0.date))" }.joined(separator: "\n") + "\n"
                s += "waitingFor: \(ai.waitingFor)\n"
                s += "aiRevisions: \(ai.aiRevisions ?? [])\naiAdditions: \(ai.aiAdditions ?? [])\n"
                s += "notes: \(ai.notes)\n"
                try? s.write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }
}
