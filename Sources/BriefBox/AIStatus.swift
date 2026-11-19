import Foundation
import FoundationModels
import os

/// สถานะโมเดล Apple Intelligence บนเครื่อง (ของบัญชีที่เปิดแอป) — แสดงในตั้งค่า + เขียน log ตอนเปิดแอป
enum AIStatus {
    static let log = Logger(subsystem: "local.briefbox.app", category: "ai")

    static var text: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "พร้อมใช้ ✅"
        case .unavailable(.appleIntelligenceNotEnabled): return "ยังไม่เปิด — เปิดที่ System Settings › Apple Intelligence & Siri"
        case .unavailable(.modelNotReady): return "เปิดแล้ว กำลังโหลดโมเดล (รอเสียบปลั๊ก+ต่อ Wi-Fi)"
        case .unavailable(.deviceNotEligible): return "เครื่องนี้ไม่รองรับ"
        case .unavailable(let r): return "ใช้ไม่ได้ (\(r))"
        @unknown default: return "ไม่ทราบสถานะ"
        }
    }

    /// เขียนสถานะลง /Users/Shared/BriefBox/ai-status.txt (บัญชีอื่นบนเครื่องอ่านได้ ใช้เช็กผ่าน ssh)
    static func logNow() {
        let line = "\(ISO8601DateFormatter().string(from: Date())) user=\(NSUserName()) \(String(describing: SystemLanguageModel.default.availability))\n"
        log.notice("FM availability: \(line, privacy: .public)")
        let dir = URL(fileURLWithPath: "/Users/Shared/BriefBox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? line.write(to: dir.appendingPathComponent("ai-status.txt"), atomically: true, encoding: .utf8)
    }
}
