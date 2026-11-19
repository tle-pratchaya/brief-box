import AppKit
import SwiftData
import BriefCore

/// ตัวเลขแดงบนไอคอน Dock = งานถึง/เลยกำหนด + รอตรวจ
/// อัปเดตเมื่อข้อมูลถูกบันทึก, ขึ้นวันใหม่, และทุก 60 วินาที (กันพลาด) — ทำงานแม้ปิดหน้าต่างไปแล้ว
@MainActor
enum DockBadge {
    static var timer: Timer?

    static func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { update() }
        }
        update()
    }

    static func update() {
        let ctx = ImportCenter.shared.container.mainContext
        let jobs = (try? ctx.fetch(FetchDescriptor<Job>(predicate: #Predicate { !$0.isPendingReview }))) ?? []
        let pending = (try? ctx.fetchCount(FetchDescriptor<Job>(predicate: #Predicate { $0.isPendingReview }))) ?? 0
        let replies = (try? ctx.fetchCount(FetchDescriptor<PendingReply>())) ?? 0
        let due = jobs.filter { $0.isDueNow }.count
        let label = DockBadgeRule.label(dueNow: due, review: pending + replies)
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
}

extension Job {
    var isDueNow: Bool {
        DockBadgeRule.isDueNow(daysLeft: daysLeft, daysWaitingReply: daysWaitingReply, done: status == .done)
    }
}
