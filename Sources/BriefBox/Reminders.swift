import EventKit
import Foundation

/// เตือนเดดไลน์ผ่าน Apple Reminders → ไปถึง iPhone ผ่าน iCloud
/// ส่งขึ้น iCloud แค่ชื่องานกับวันที่ ไม่มีเนื้อหาเมล
@MainActor
final class ReminderSync {
    static let shared = ReminderSync()
    private let store = EKEventStore()
    private let listKey = "reminderListID"
    static let listName = "กล่องบรีฟ"

    var enabled: Bool { UserDefaults.standard.object(forKey: "remindersOn") as? Bool ?? true }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    private func list() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: listKey), let c = store.calendar(withIdentifier: id) { return c }
        if let c = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) {
            UserDefaults.standard.set(c.calendarIdentifier, forKey: listKey); return c
        }
        guard let source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first(where: { $0.sourceType == .calDAV }) else { return nil }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = Self.listName
        c.source = source
        do { try store.saveCalendar(c, commit: true) } catch { return nil }
        UserDefaults.standard.set(c.calendarIdentifier, forKey: listKey)
        return c
    }

    /// สร้าง/อัปเดต/ปิด reminder ของงานนี้ให้ตรงกับสถานะปัจจุบัน
    func sync(_ job: Job) async {
        guard enabled else { return }
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard await requestAccess() else { return }
        }
        guard let cal = list() else { return }
        let cancelled = job.status == .done || job.isPendingReview
        for m in job.myMilestones {
            let existing = m.reminderID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
            let draftDone = job.status.rank >= JobStatus.draftSent.rank && m.label == "ดราฟต์แรก"
            let finished = cancelled || draftDone || job.status.rank >= JobStatus.finalSent.rank
            if finished {
                if let r = existing, !r.isCompleted { r.isCompleted = true; try? store.save(r, commit: true) }
                continue
            }
            let r = existing ?? EKReminder(eventStore: store)
            r.calendar = cal
            r.title = "\(m.label): \(job.title)"
            r.isCompleted = false
            var due = Calendar.current.dateComponents([.year, .month, .day], from: m.date)
            due.hour = 9; due.minute = 0
            r.dueDateComponents = due
            r.alarms?.forEach { r.removeAlarm($0) }
            if let dayOf = Calendar.current.date(from: due) {
                // เตือนเช้าวันก่อน 09:00 และเช้าวันส่ง 09:00
                if let before = Calendar.current.date(byAdding: .day, value: -1, to: dayOf), before > Date() {
                    r.addAlarm(EKAlarm(absoluteDate: before))
                }
                if dayOf > Date() { r.addAlarm(EKAlarm(absoluteDate: dayOf)) }
            }
            do { try store.save(r, commit: true); m.reminderID = r.calendarItemIdentifier } catch {}
        }
    }

    func remove(_ job: Job) {
        for m in job.milestones {
            if let id = m.reminderID, let r = store.calendarItem(withIdentifier: id) as? EKReminder {
                try? store.remove(r, commit: true)
            }
        }
    }
}
