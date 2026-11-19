import Testing
@testable import BriefCore

@Suite struct DockBadgeTests {
    @Test func dueNowRules() {
        #expect(DockBadgeRule.isDueNow(daysLeft: 0, daysWaitingReply: nil, done: false))      // วันนี้
        #expect(DockBadgeRule.isDueNow(daysLeft: -3, daysWaitingReply: nil, done: false))     // เลยกำหนด
        #expect(!DockBadgeRule.isDueNow(daysLeft: 1, daysWaitingReply: nil, done: false))     // พรุ่งนี้
        #expect(!DockBadgeRule.isDueNow(daysLeft: nil, daysWaitingReply: nil, done: false))   // ไม่มีเดดไลน์
        #expect(!DockBadgeRule.isDueNow(daysLeft: -1, daysWaitingReply: 2, done: false))      // ส่งแล้วรอตอบ
        #expect(!DockBadgeRule.isDueNow(daysLeft: -1, daysWaitingReply: nil, done: true))     // เสร็จแล้ว
    }

    @Test func label() {
        #expect(DockBadgeRule.label(dueNow: 0, review: 0) == nil)
        #expect(DockBadgeRule.label(dueNow: 2, review: 1) == "3")
        #expect(DockBadgeRule.label(dueNow: 0, review: 5) == "5")
        #expect(DockBadgeRule.label(dueNow: 90, review: 20) == "99+")
    }
}
