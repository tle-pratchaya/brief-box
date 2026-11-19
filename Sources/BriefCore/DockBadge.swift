import Foundation

/// กติกาตัวเลขบนไอคอน Dock (แยกจาก UI เพื่อทดสอบได้)
/// ตัวเลข = งานที่ถึง/เลยกำหนด (ไม่นับงานที่ส่งแล้วรอตอบ) + รายการรอตรวจ
public enum DockBadgeRule {
    /// งานนี้นับเป็น "ถึง/เลยกำหนด" ไหม — ตรงกับหน้า "วันนี้" และป้ายบนแถบข้าง
    public static func isDueNow(daysLeft: Int?, daysWaitingReply: Int?, done: Bool) -> Bool {
        !done && (daysLeft ?? 99) <= 0 && daysWaitingReply == nil
    }

    /// ข้อความบน Dock: ไม่มีอะไร = nil (ซ่อนป้าย), เกิน 99 = "99+"
    public static func label(dueNow: Int, review: Int) -> String? {
        let n = max(0, dueNow) + max(0, review)
        if n == 0 { return nil }
        return n > 99 ? "99+" : String(n)
    }
}
