import SwiftData
import SwiftUI
import BriefCore

/// หน้า "วันนี้": เปิดแอปมาเห็นทันทีว่าต้องทำอะไร
struct TodayView: View {
    @Binding var selection: PersistentIdentifier?
    @Query(filter: #Predicate<Job> { !$0.isPendingReview }) private var all: [Job]
    @Query(filter: #Predicate<Job> { $0.isPendingReview }) private var pending: [Job]
    @Query private var replies: [PendingReply]

    var open: [Job] { all.filter { $0.status != .done } }
    var byDue: (Job, Job) -> Bool { { ($0.nextDue?.date ?? .distantFuture) < ($1.nextDue?.date ?? .distantFuture) } }

    var dueNow: [Job] { open.filter(\.isDueNow).sorted(by: byDue) }
    var thisWeek: [Job] { open.filter { (1...7).contains($0.daysLeft ?? 99) && $0.daysWaitingReply == nil }.sorted(by: byDue) }
    var chase: [Job] { open.filter { ($0.daysWaitingReply ?? 0) >= 3 }.sorted { ($0.daysWaitingReply ?? 0) > ($1.daysWaitingReply ?? 0) } }
    var waiting: [Job] { open.filter { !$0.openWaiting.isEmpty } }

    var body: some View {
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.full(Date())).font(.title2.bold())
                    HStack(spacing: 14) {
                        stat("\(dueNow.count)", "ถึง/เลยกำหนด", dueNow.isEmpty ? .secondary : .red)
                        stat("\(thisWeek.count)", "ภายใน 7 วัน", .accentColor)
                        stat("\(chase.count)", "ควรทวง", chase.isEmpty ? .secondary : .orange)
                        stat("\(pending.count + replies.count)", "รอตรวจ", pending.isEmpty && replies.isEmpty ? .secondary : .purple)
                    }
                }
                .padding(.vertical, 6)
            }
            group("🔥 ต้องส่งวันนี้ / เลยกำหนด", dueNow, empty: "ไม่มีงานค้างวันนี้")
            group("📅 ภายใน 7 วัน", thisWeek, empty: "ว่าง")
            if !chase.isEmpty {
                Section("📨 ส่งไปแล้ว ยังไม่ตอบเกิน 3 วัน ควรทวง") {
                    ForEach(chase) { j in
                        HStack {
                            JobRow(job: j)
                            Text("\(j.daysWaitingReply ?? 0) วัน").font(.caption.bold()).foregroundStyle(.orange)
                        }.tag(j.persistentModelID)
                    }
                }
            }
            if !waiting.isEmpty {
                Section("⏳ รอข้อมูลจากผู้สั่ง") {
                    ForEach(waiting) { j in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(j.title).font(.headline).lineLimit(1)
                            ForEach(j.openWaiting) { w in
                                Text("• \(w.text)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(j.persistentModelID)
                    }
                }
            }
        }
        .navigationTitle("วันนี้")
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    }

    @ViewBuilder func group(_ title: String, _ jobs: [Job], empty: String) -> some View {
        Section(title) {
            if jobs.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(jobs) { JobRow(job: $0).tag($0.persistentModelID) }
        }
    }

    func stat(_ n: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n).font(.title.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// ปฏิทินรายเดือน: เดดไลน์ของเรา + วันที่ทีมอื่นนำงานไปใช้
struct CalendarView: View {
    @Binding var selection: PersistentIdentifier?
    @Query(filter: #Predicate<Job> { !$0.isPendingReview }) private var all: [Job]
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var showOthers = false

    let cal = Calendar.current

    struct Item: Identifiable {
        let id = UUID()
        let job: Job
        let label: String
        let mine: Bool
    }

    var items: [Date: [Item]] {
        var out: [Date: [Item]] = [:]
        for j in all {
            for m in j.milestones where m.team == nil || showOthers {
                let d = cal.startOfDay(for: m.date)
                out[d, default: []].append(Item(job: j, label: m.team == nil ? m.label : "ใช้จริง", mine: m.team == nil))
            }
        }
        return out
    }

    var days: [Date?] {
        let first = month
        let count = cal.range(of: .day, in: .month, for: first)!.count
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var arr: [Date?] = Array(repeating: nil, count: lead)
        for i in 0..<count { arr.append(cal.date(byAdding: .day, value: i, to: first)) }
        while arr.count % 7 != 0 { arr.append(nil) }
        return arr
    }

    var weekdayNames: [String] {
        let s = cal.veryShortWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Text(Fmt.month(month)).font(.title3.bold()).frame(minWidth: 140)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                Button("เดือนนี้") { month = cal.date(from: cal.dateComponents([.year, .month], from: Date()))! }
                Spacer()
                Toggle("วันที่ทีมอื่นใช้งาน", isOn: $showOthers).toggleStyle(.checkbox)
            }
            .buttonStyle(.borderless)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(weekdayNames, id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary) }
            }
            ScrollView {
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        if let day { cell(day) } else { Color.clear.frame(height: 92) }
                    }
                }
            }
        }
        .padding(12)
        .navigationTitle("ปฏิทิน")
        .navigationSplitViewColumnWidth(min: 520, ideal: 640)
    }

    func cell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let list = items[cal.startOfDay(for: day)] ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: day))")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(isToday ? Color.white : .primary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(isToday ? Color.accentColor : .clear))
            ForEach(list.prefix(3)) { it in
                Button { selection = it.job.persistentModelID } label: {
                    Text(it.job.title)
                        .font(.caption2).lineLimit(1)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill((it.mine ? it.job.kind.color : Color.gray).opacity(it.job.status == .done ? 0.12 : 0.25)))
                        .strikethrough(it.job.status == .done)
                }
                .buttonStyle(.plain)
                .help("\(it.label): \(it.job.title)")
            }
            if list.count > 3 { Text("+\(list.count - 3)").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(isToday ? 0.12 : 0.05)))
    }

    func shift(_ n: Int) { month = cal.date(byAdding: .month, value: n, to: month)! }
}
