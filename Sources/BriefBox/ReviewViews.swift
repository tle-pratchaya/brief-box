import SwiftData
import SwiftUI
import BriefCore

struct ReviewListView: View {
    @Query(filter: #Predicate<Job> { $0.isPendingReview }, sort: \Job.createdAt) private var pending: [Job]
    @Query(sort: \PendingReply.sentAt) private var replies: [PendingReply]
    @Binding var selectedJob: PersistentIdentifier?
    @Binding var selectedReply: PersistentIdentifier?

    var body: some View {
        List {
            if !pending.isEmpty {
                Section("งานใหม่") {
                    ForEach(pending) { job in
                        Button { selectedJob = job.persistentModelID; selectedReply = nil } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.title).font(.headline).lineLimit(2)
                                HStack(spacing: 6) {
                                    Pill(text: job.kind.label, color: job.kind.color)
                                    Text(job.requester).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text("\(job.artworks.count) artwork · \(job.allFiles.count) ไฟล์")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedJob == job.persistentModelID ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
            }
            if !replies.isEmpty {
                Section("เมลตอบกลับ") {
                    ForEach(replies) { r in
                        Button { selectedReply = r.persistentModelID; selectedJob = nil } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.job?.title ?? r.subject).font(.headline).lineLimit(2)
                                Text("\(r.from) · \(Fmt.short(r.sentAt))").font(.caption).foregroundStyle(.secondary)
                                if r.job == nil { Pill(text: "ยังไม่รู้ว่าของงานไหน", color: .orange) }
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedReply == r.persistentModelID ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
            }
            if pending.isEmpty && replies.isEmpty {
                Text("ว่าง").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("รอตรวจ")
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
    }
}

/// ตรวจการ์ดร่างก่อนเข้ารายการงาน: ซ้ายเมลจริง ขวาสิ่งที่แอปแยกได้
struct ReviewJobView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var center: ImportCenter
    @Bindable var job: Job
    var onDone: () -> Void

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("อีเมลต้นฉบับ").font(.headline)
                Text("\(job.requester) · ส่งเมื่อ \(Fmt.date(job.receivedAt))").font(.caption).foregroundStyle(.secondary)
                EmailTextView(body: job.bodyText, highlight: job.mySection)
            }
            .padding(14)
            .frame(minWidth: 320)

            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("ชื่องาน", text: $job.title, axis: .vertical)
                        .font(.title2.bold()).textFieldStyle(.plain)
                    HStack {
                        Picker("ประเภท", selection: Binding(get: { job.kind }, set: { job.kind = $0 })) {
                            ForEach(JobKind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 260)
                        Spacer()
                        Text(job.requester).foregroundStyle(.secondary)
                    }
                    if !job.parserNotes.isEmpty {
                        Label(job.parserNotes, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    MilestonesEditor(job: job)
                    ArtworksSection(job: job, editing: true)
                    WaitingSection(job: job)
                    if !job.copyTexts.isEmpty {
                        SectionCard(title: "ข้อความที่ต้องใส่") {
                            Text(job.sortedCopy.map(\.title).joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                    }
                    RefsSection(job: job)
                }
                .padding(16)
            }
            .layoutPriority(1)
            Divider()
                HStack {
                    Button(role: .destructive) { reject() } label: { Text("ไม่ใช่งาน ลบทิ้ง") }
                    Spacer()
                    Button { accept() } label: { Label("เข้ารายการงาน", systemImage: "checkmark").padding(.horizontal, 6) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(12)
                .background(.bar)
            }
            .frame(minWidth: 420)
        }
    }

    func accept() {
        job.isPendingReview = false
        try? context.save()
        let title = job.title
        Task { await ReminderSync.shared.sync(job) }
        center.show("\"\(title)\" เข้ารายการงานแล้ว")
        onDone()
    }

    func reject() {
        for r in job.refs where r.kindRaw != "link" {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: r.location).deletingLastPathComponent())
        }
        context.delete(job)
        try? context.save()
        onDone()
    }
}

/// เมลตอบกลับ: เลือกงาน แล้วแยกเป็นรายการแก้ / งานเพิ่ม
struct ReplyReviewView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var center: ImportCenter
    @Query(filter: #Predicate<Job> { !$0.isPendingReview }, sort: \Job.receivedAt, order: .reverse) private var jobs: [Job]
    @Bindable var reply: PendingReply
    var onDone: () -> Void
    @State private var revisions = ""
    @State private var additions = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text(reply.subject).font(.headline)
                Text("\(reply.from) · \(Fmt.date(reply.sentAt))").font(.caption).foregroundStyle(.secondary)
                EmailTextView(body: reply.text, highlight: nil)
                Button("เปิดเมลเต็ม") { openLocation(reply.emailPath) }
            }
            .padding(14).frame(minWidth: 320)

            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("เมลตอบกลับ").font(.title2.bold())
                    Picker("ของงาน", selection: Binding(get: { reply.job?.persistentModelID },
                                                        set: { id in reply.job = jobs.first { $0.persistentModelID == id } })) {
                        Text("— เลือกงาน —").tag(PersistentIdentifier?.none)
                        ForEach(jobs) { Text($0.title).tag(Optional($0.persistentModelID)) }
                    }
                    SectionCard(title: "รายการแก้ไข (1 บรรทัด = 1 ข้อ)") {
                        TextEditor(text: $revisions).font(.body).frame(minHeight: 120)
                    }
                    SectionCard(title: "งานเพิ่ม ที่ไม่อยู่ในบรีฟแรก (1 บรรทัด = 1 ข้อ)") {
                        TextEditor(text: $additions).font(.body).frame(minHeight: 70)
                    }
                    if !reply.waitingText.isEmpty {
                        SectionCard(title: "ข้อมูลที่ผู้สั่งบอกว่าจะส่งตามมา") {
                            Text(reply.waitingText).foregroundStyle(.orange)
                        }
                    }
                    if reply.aiRevisions != nil || reply.aiAdditions != nil {
                        Label("AI แยกให้แล้ว ตรวจกับเมลซ้ายก่อนบันทึก แก้ได้ทุกบรรทัด", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                    }
                    Text("ย้ายข้อความจากเมลซ้ายมาใส่ หรือพิมพ์สรุปเอง แอปจะติดวันที่และที่มาให้").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .layoutPriority(1)
            Divider()
                HStack {
                    Button(role: .destructive) { context.delete(reply); try? context.save(); onDone() } label: { Text("ไม่เกี่ยวกับงาน ลบทิ้ง") }
                    Spacer()
                    Button { accept() } label: { Label("บันทึกเข้างาน", systemImage: "checkmark") }
                        .keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(reply.job == nil)
                }
                .padding(12).background(.bar)
            }
            .frame(minWidth: 420)
        }
        .onAppear(perform: prefill)
        .onChange(of: reply.persistentModelID) { _, _ in prefill() }
    }

    func prefill() {
        if reply.aiRevisions != nil || reply.aiAdditions != nil {
            revisions = reply.aiRevisions ?? ""
            additions = reply.aiAdditions ?? ""
            return
        }
        additions = ""
        revisions = reply.text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("hi") && !$0.lowercased().hasPrefix("dear")
                && !$0.lowercased().hasPrefix("thank") && !$0.lowercased().hasPrefix("best") && !$0.lowercased().hasPrefix("regards") }
            .prefix(10).joined(separator: "\n")
    }

    func accept() {
        guard let job = reply.job else { return }
        func add(_ text: String, _ kind: LogKind) {
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let e = LogEntry(kind: kind, text: t, source: .email, date: reply.sentAt)
                e.emailPath = reply.emailPath
                context.insert(e); e.job = job
            }
        }
        add(revisions, .revision)
        add(additions, .addition)
        for w in reply.waitingText.components(separatedBy: "\n") where !w.isEmpty {
            let item = WaitingItem(text: w); context.insert(item); item.job = job
        }
        let ref = RefItem(kind: "email", title: "ตอบกลับ \(Fmt.short(reply.sentAt)) จาก \(reply.from)", location: reply.emailPath)
        context.insert(ref); ref.job = job
        if job.status.rank >= JobStatus.draftSent.rank && job.status != .done { job.status = .revising }
        context.delete(reply)
        try? context.save()
        center.show("บันทึกเข้า \"\(job.title)\" แล้ว")
        onDone()
    }
}
