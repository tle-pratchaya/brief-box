import SwiftData
import SwiftUI
import BriefCore

// MARK: - รายการงาน

struct JobListView: View {
    let done: Bool
    @Binding var selection: PersistentIdentifier?
    @Query(filter: #Predicate<Job> { !$0.isPendingReview }) private var all: [Job]
    @State private var kindFilter: JobKind?
    @State private var waitingOnly = false
    @State private var search = ""

    var jobs: [Job] {
        all.filter { done ? $0.status == .done : $0.status != .done }
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .filter { !waitingOnly || !$0.openWaiting.isEmpty }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.requester.localizedCaseInsensitiveContains(search) }
    }

    var groups: [(String, [Job])] {
        if done { return [("เสร็จแล้ว", jobs.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })] }
        let byDue: (Job, Job) -> Bool = { ($0.nextDue?.date ?? .distantFuture) < ($1.nextDue?.date ?? .distantFuture) }
        let waitingReply = jobs.filter { $0.status == .draftSent || $0.status == .finalSent }
        let active = jobs.filter { !waitingReply.contains($0) }
        return [
            ("เลยกำหนด", active.filter { ($0.daysLeft ?? 99) < 0 }.sorted(by: byDue)),
            ("ใกล้ถึง (ภายใน 3 วัน)", active.filter { (0...3).contains($0.daysLeft ?? 99) }.sorted(by: byDue)),
            ("ถัดไป", active.filter { ($0.daysLeft ?? -99) > 3 }.sorted(by: byDue)),
            ("ไม่มีเดดไลน์", active.filter { $0.daysLeft == nil }.sorted { $0.createdAt > $1.createdAt }),
            ("ส่งแล้ว รอผู้สั่งตอบ", waitingReply.sorted(by: byDue)),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { JobRow(job: $0).tag($0.persistentModelID) }
                }
            }
        }
        .overlay {
            if jobs.isEmpty {
                ContentUnavailableView(done ? "ยังไม่มีงานที่เสร็จ" : "ยังไม่มีงาน", systemImage: "tray",
                                       description: Text(done ? "" : "ลากอีเมลบรีฟจาก Outlook มาวาง แล้วกดยืนยันในหน้ารอตรวจ"))
            }
        }
        .searchable(text: $search, prompt: "ค้นชื่องาน / ผู้สั่ง")
        .toolbar {
            ToolbarItemGroup {
                Picker("ประเภท", selection: $kindFilter) {
                    Text("ทั้งหมด").tag(JobKind?.none)
                    Text("กราฟิก").tag(JobKind?.some(.graphic))
                    Text("วิดีโอ").tag(JobKind?.some(.video))
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $waitingOnly) { Label("รอข้อมูล", systemImage: "hourglass") }
                    .help("แสดงเฉพาะงานที่ยังรอข้อมูลจากผู้สั่ง")
            }
        }
        .navigationTitle(done ? "เสร็จแล้ว" : "งานทั้งหมด")
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    }
}

struct JobRow: View {
    let job: Job
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(urgencyColor(job)).frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Pill(text: job.kind.label, color: job.kind.color)
                    Pill(text: job.status.label, color: job.status.color)
                    if !job.openWaiting.isEmpty { Pill(text: "รอข้อมูล \(job.openWaiting.count)", color: .orange) }
                }
                Text(job.requester.isEmpty ? job.source.label : job.requester)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if let due = job.nextDue {
                    Text(Fmt.short(due.date)).font(.callout.monospacedDigit())
                    Text(Fmt.daysText(job.daysLeft)).font(.caption).foregroundStyle(urgencyColor(job))
                }
                if job.filesTotal > 0 {
                    ProgressView(value: job.progress).frame(width: 70)
                    Text("\(job.filesDone)/\(job.filesTotal) ไฟล์").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - รายละเอียดงาน

struct JobDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var job: Job
    @State private var editingArtworks = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(job.source.label) · \(job.requester.isEmpty ? "" : job.requester + " · ")ได้รับ \(Fmt.date(job.receivedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("ชื่องาน", text: $job.title, axis: .vertical).font(.title.bold()).textFieldStyle(.plain)
                    Picker("สถานะ", selection: Binding(get: { job.status }, set: { setStatus($0) })) {
                        ForEach(JobStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    HStack(spacing: 10) {
                        Button { WorkFolder.open(job, context: context) } label: {
                            Label(WorkFolder.exists(job) ? "เปิดโฟลเดอร์งาน" : "สร้างโฟลเดอร์งาน", systemImage: "folder")
                        }
                        .help("โฟลเดอร์ใน Finder แยกตาม Artwork พร้อมไฟล์แนบจากเมล")
                        if WorkFolder.exists(job), let p = job.workFolder {
                            Text(p.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if let w = job.daysWaitingReply, w >= 3 {
                            Pill(text: "ส่งไปแล้ว \(w) วัน ยังไม่ตอบ ควรทวง", color: .orange)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        ArtworksSection(job: job, editing: editingArtworks, toggleEdit: { editingArtworks.toggle() })
                        LogSection(job: job)
                        WaitingSection(job: job)
                    }
                    .frame(minWidth: 340, maxWidth: .infinity)
                    VStack(spacing: 16) {
                        MilestonesEditor(job: job)
                        CopySection(job: job)
                        RefsSection(job: job)
                        SectionCard(title: "โน้ต") {
                            if let p = job.picture, !p.isEmpty {
                                Label("ภาพ: \(p)", systemImage: "photo").font(.callout)
                            }
                            TextEditor(text: $job.notes).frame(minHeight: 80).font(.body)
                                .scrollContentBackground(.hidden)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let s = job.mySection, !s.isEmpty {
                            DisclosureGroup("ส่วนของเราในบรีฟ") {
                                Text(s).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minWidth: 300, maxWidth: 420)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("ลบงานนี้", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("ลบ \"\(job.title)\"?", isPresented: $confirmDelete) {
            Button("ลบงานและไฟล์ที่เก็บไว้", role: .destructive) {
                ReminderSync.shared.remove(job)
                for r in job.refs where r.kindRaw != "link" {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: r.location).deletingLastPathComponent())
                }
                context.delete(job); try? context.save()
            }
        } message: { Text("ลบแล้วกู้คืนไม่ได้ อีเมลต้นฉบับใน Outlook ยังอยู่") }
    }

    func setStatus(_ s: JobStatus) {
        job.status = s
        try? context.save()
        Task { await ReminderSync.shared.sync(job) }
    }
}

// MARK: - ส่วนประกอบที่ใช้ทั้งหน้ารอตรวจและรายละเอียด

struct ArtworksSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var job: Job
    var editing: Bool
    var toggleEdit: (() -> Void)? = nil

    var body: some View {
        SectionCard(title: "ชิ้นงาน · \(job.filesDone)/\(job.filesTotal) ไฟล์",
                    trailing: toggleEdit.map { t in AnyView(Button(editing ? "เสร็จ" : "แก้ไข", action: t).buttonStyle(.link)) }) {
            if job.artworks.isEmpty && !editing {
                Text("ยังไม่มีชิ้นงาน กด \"แก้ไข\" เพื่อเพิ่ม").foregroundStyle(.secondary)
            }
            ForEach(job.sortedArtworks) { art in
                ArtworkRow(art: art, editing: editing) {
                    context.delete(art); try? context.save()
                }
                Divider()
            }
            if editing {
                Button { addArtwork() } label: { Label("เพิ่มชิ้นงาน", systemImage: "plus") }
            }
        }
    }

    func addArtwork() {
        let n = (job.artworks.map(\.number).max() ?? 0) + 1
        let a = Artwork(number: n, spec: "", size: nil, warning: nil, order: n)
        context.insert(a); a.job = job
        let f = ArtFile(label: "ไฟล์", order: 0); context.insert(f); f.artwork = a
        try? context.save()
    }
}

struct ArtworkRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var art: Artwork
    var editing: Bool
    var onDelete: () -> Void
    @State private var newFile = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(art.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) {
                if editing {
                    TextField("รายละเอียดชิ้นงาน", text: $art.spec, axis: .vertical).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("ขนาด เช่น 1080×1350", text: Binding(get: { art.size ?? "" }, set: { art.size = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        TextField("ข้อที่ต้องถาม", text: Binding(get: { art.warning ?? "" }, set: { art.warning = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(art.spec).fixedSize(horizontal: false, vertical: true)
                        if let s = art.size { Text(s).font(.callout.monospaced()).foregroundStyle(.secondary) }
                    }
                    if let w = art.warning { Label(w, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange) }
                }
                FlowChips(files: art.sortedFiles, editing: editing) { f in context.delete(f); try? context.save() }
                if editing {
                    HStack {
                        TextField("เพิ่มไฟล์ย่อย เช่น แบบ 3", text: $newFile).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                            .onSubmit(addFile)
                        Button("เพิ่ม", action: addFile).disabled(newFile.isEmpty)
                        Spacer()
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    func addFile() {
        let f = ArtFile(label: newFile, order: (art.files.map(\.order).max() ?? 0) + 1)
        context.insert(f); f.artwork = art; newFile = ""
        try? context.save()
    }
}

struct FlowChips: View {
    let files: [ArtFile]
    var editing: Bool
    var onDelete: (ArtFile) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(files) { f in FileChip(file: f, editing: editing, onDelete: { onDelete(f) }) }
        }
    }
}

struct FileChip: View {
    @Environment(\.modelContext) private var context
    @Bindable var file: ArtFile
    var editing: Bool
    var onDelete: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $file.done) { Text(file.label).strikethrough(file.done) }
                .toggleStyle(.checkbox)
                .onChange(of: file.done) { _, _ in try? context.save() }
            if editing { Button(action: onDelete) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
            else if let art = file.artwork {
                let name = ExportName.make(job: art.job?.title ?? "", number: art.number, size: art.size,
                                           variant: file.label, pattern: WorkFolder.exportPattern)
                Button {
                    copyToPasteboard(name)
                    ImportCenter.shared.show("คัดลอกชื่อไฟล์แล้ว: \(name)")
                } label: { Image(systemName: "doc.on.doc").font(.caption) }
                .buttonStyle(.borderless)
                .help("คัดลอกชื่อไฟล์ส่งออก: \(name)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(file.done ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)))
    }
}

struct MilestonesEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var job: Job

    var body: some View {
        SectionCard(title: "วันที่สำคัญ", trailing: AnyView(Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.borderless))) {
            if job.myMilestones.isEmpty {
                Label("บรีฟไม่ได้ระบุเดดไลน์ กด + เพื่อใส่เอง", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(job.myMilestones) { m in MilestoneRow(m: m, job: job) }
            if !job.otherMilestones.isEmpty {
                Divider()
                Text("วันที่ทีมอื่นนำงานไปใช้").font(.caption).foregroundStyle(.secondary)
                ForEach(job.otherMilestones) { m in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.short(m.date)).font(.callout.monospacedDigit()).frame(width: 90, alignment: .leading)
                        Text(m.label).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    func add() {
        let m = Milestone(label: "ส่งงาน", date: Calendar.current.date(byAdding: .day, value: 3, to: Date())!, team: nil)
        context.insert(m); m.job = job; try? context.save()
        if !job.isPendingReview { Task { await ReminderSync.shared.sync(job) } }
    }
}

struct MilestoneRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var m: Milestone
    let job: Job
    var body: some View {
        HStack {
            Picker("", selection: $m.label) {
                ForEach(Set(["ส่งงาน", "ดราฟต์แรก", "ไฟนอล", m.label]).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            DatePicker("", selection: $m.date, displayedComponents: .date).labelsHidden()
            Spacer()
            Button(role: .destructive) { context.delete(m); try? context.save() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
        .onChange(of: m.date) { _, _ in
            try? context.save()
            if !job.isPendingReview { Task { await ReminderSync.shared.sync(job) } }
        }
    }
}

struct WaitingSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var job: Job
    @State private var newText = ""
    var body: some View {
        SectionCard(title: "รอข้อมูลจากผู้สั่ง") {
            if job.waiting.isEmpty { Text("ไม่มี").foregroundStyle(.secondary) }
            ForEach(job.waiting) { w in WaitingRow(item: w) }
            HStack {
                TextField("เพิ่มสิ่งที่ต้องทวง", text: $newText).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("เพิ่ม", action: add).disabled(newText.isEmpty)
            }
        }
    }
    func add() { let w = WaitingItem(text: newText); context.insert(w); w.job = job; newText = ""; try? context.save() }
}

struct WaitingRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: WaitingItem
    var body: some View {
        HStack(alignment: .top) {
            Toggle(isOn: $item.done) { Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary) }
                .toggleStyle(.checkbox)
            Spacer()
            Button { context.delete(item); try? context.save() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .onChange(of: item.done) { _, _ in try? context.save() }
    }
}

struct LogSection: View {
    @Environment(\.modelContext) private var context
    @Bindable var job: Job
    @State private var adding: LogKind?
    @State private var text = ""
    @State private var source: JobSource = .line

    var body: some View {
        SectionCard(title: "บันทึกการแก้ไข & งานเพิ่ม") {
            if job.logEntries.isEmpty { Text("ยังไม่มี · ลากเมล RE: เข้ามา หรือกดปุ่มด้านล่าง").foregroundStyle(.secondary) }
            ForEach(job.sortedLog) { e in LogRow(entry: e) }
            if let kind = adding {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(kind == .addition ? "งานเพิ่ม เช่น Story แบบที่ 3" : "รายการแก้ เช่น ราคาตัวใหญ่ขึ้น",
                              text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("มาจาก", selection: $source) {
                            Text("💬 LINE").tag(JobSource.line); Text("📧 อีเมล").tag(JobSource.email); Text("🗣 ปากเปล่า").tag(JobSource.verbal); Text("✍️ เอง").tag(JobSource.manual)
                        }.frame(maxWidth: 220)
                        Spacer()
                        Button("ยกเลิก") { adding = nil; text = "" }
                        Button("บันทึก") { save(kind) }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
            } else {
                HStack {
                    Button { adding = .revision } label: { Label("บันทึกการแก้", systemImage: "pencil") }
                    Button { adding = .addition } label: { Label("งานเพิ่ม", systemImage: "plus.square") }
                    Button { adding = .note } label: { Label("โน้ต", systemImage: "note.text") }
                }
            }
        }
    }

    func save(_ kind: LogKind) {
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let e = LogEntry(kind: kind, text: line.trimmingCharacters(in: .whitespaces), source: source)
            context.insert(e); e.job = job
        }
        if kind == .revision && job.status.rank >= JobStatus.draftSent.rank && job.status != .done { job.status = .revising }
        try? context.save()
        adding = nil; text = ""
    }
}

struct LogRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var entry: LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if entry.kind != .note {
                Toggle("", isOn: $entry.done).toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: "note.text").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if entry.kind == .addition { Pill(text: "งานเพิ่ม", color: .orange) }
                    Text(entry.text).strikethrough(entry.done).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text("\(Fmt.short(entry.date)) · \(entry.source.label)")
                    if let p = entry.emailPath { Button("เปิดเมล") { openLocation(p) }.buttonStyle(.link) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { context.delete(entry); try? context.save() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .onChange(of: entry.done) { _, _ in try? context.save() }
    }
}

struct CopySection: View {
    let job: Job
    @State private var copied: String?
    @State private var expanded: Set<String> = []
    var body: some View {
        if !job.copyTexts.isEmpty {
            SectionCard(title: "ข้อความที่ต้องใส่") {
                ForEach(job.sortedCopy) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.title).font(.subheadline.bold())
                            Spacer()
                            Button(copied == c.title ? "คัดลอกแล้ว" : "คัดลอก") {
                                copyToPasteboard(c.text); copied = c.title
                                Task { try? await Task.sleep(for: .seconds(1.5)); if copied == c.title { copied = nil } }
                            }
                        }
                        Text(c.text).font(.callout).textSelection(.enabled)
                            .lineLimit(expanded.contains(c.title) ? nil : 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if c.text.count > 220 {
                            Button(expanded.contains(c.title) ? "ย่อ" : "ดูทั้งหมด") {
                                if expanded.contains(c.title) { expanded.remove(c.title) } else { expanded.insert(c.title) }
                            }.buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                }
            }
        }
    }
}

struct RefsSection: View {
    let job: Job
    var body: some View {
        if !job.refs.isEmpty {
            SectionCard(title: "อ้างอิง & ไฟล์แนบ") {
                ForEach(job.refs.sorted { ($0.kindRaw, $0.title) < ($1.kindRaw, $1.title) }) { r in
                    Button { openLocation(r.location) } label: {
                        Label(r.title, systemImage: r.icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.link)
                    .help(r.location)
                }
            }
        }
    }
}

// MARK: - เพิ่มงานเอง (รวมข้อความจาก LINE)

struct AddJobSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var center: ImportCenter
    @Query(sort: \Job.receivedAt, order: .reverse) private var allJobs: [Job]
    let initialText: String

    @State private var title = ""
    @State private var kind: JobKind = .video
    @State private var source: JobSource = .verbal
    @State private var requester = ""
    @State private var length = ""
    @State private var versions: [String] = []
    @State private var hasDraft = false
    @State private var draft = QuickDate.days(2)
    @State private var hasDue = true
    @State private var due = QuickDate.days(3)
    @State private var waiting: Set<String> = []
    @State private var waitingOther = ""
    @State private var text = ""

    static let videoVersions = ["16:9", "9:16", "1:1", "4:5"]
    static let graphicVersions = ["1080×1350", "1080×1920", "1080×1080", "A4", "A3"]
    static let lengths = ["15 วิ", "30 วิ", "60 วิ", "2 นาที"]
    static let waitingChoices = ["ฟุตเทจ", "เพลง", "โลโก้", "ข้อความ/แคปชัน", "รูป"]

    /// คนที่เคยสั่งงาน เรียงตามล่าสุด ไม่ซ้ำ
    var recentRequesters: [String] {
        var seen = Set<String>(), out: [String] = []
        for j in allJobs {
            let r = j.requester.trimmingCharacters(in: .whitespaces)
            if !r.isEmpty, seen.insert(r.lowercased()).inserted { out.append(r) }
            if out.count == 8 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("เพิ่มงานเอง").font(.title2.bold())
                    TextField("ชื่องาน เช่น คลิปรีวิวสินค้าใหม่", text: $title).textFieldStyle(.roundedBorder).font(.title3)
                    HStack {
                        Picker("", selection: $kind) { ForEach(JobKind.allCases, id: \.self) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        Spacer()
                        Picker("มาจาก", selection: $source) {
                            Text("🗣 ปากเปล่า").tag(JobSource.verbal); Text("💬 LINE").tag(JobSource.line)
                            Text("📧 อีเมล").tag(JobSource.email); Text("✍️ เอง").tag(JobSource.manual)
                        }.frame(width: 200)
                    }

                    row("ใครสั่ง") {
                        TextField("ชื่อคนสั่ง", text: $requester).textFieldStyle(.roundedBorder).frame(width: 180)
                        ForEach(recentRequesters, id: \.self) { r in chip(r, on: requester == r) { requester = r } }
                    }

                    if kind == .video {
                        row("ความยาว") {
                            ForEach(Self.lengths, id: \.self) { l in chip(l, on: length == l) { length = length == l ? "" : l } }
                            TextField("อื่นๆ", text: $length).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                    }
                    row(kind == .video ? "เวอร์ชัน" : "ขนาด") {
                        ForEach(kind == .video ? Self.videoVersions : Self.graphicVersions, id: \.self) { v in
                            chip(v, on: versions.contains(v)) {
                                if let i = versions.firstIndex(of: v) { versions.remove(at: i) } else { versions.append(v) }
                            }
                        }
                    }

                    row("ดราฟต์") {
                        Toggle("", isOn: $hasDraft).labelsHidden()
                        dateRow($draft).disabled(!hasDraft).opacity(hasDraft ? 1 : 0.4)
                    }
                    row(hasDraft ? "ไฟนอล" : "ส่งงาน") {
                        Toggle("", isOn: $hasDue).labelsHidden()
                        dateRow($due).disabled(!hasDue).opacity(hasDue ? 1 : 0.4)
                    }

                    row("ยังรอ") {
                        ForEach(Self.waitingChoices, id: \.self) { w in
                            chip(w, on: waiting.contains(w)) { if waiting.contains(w) { waiting.remove(w) } else { waiting.insert(w) } }
                        }
                        TextField("อื่นๆ", text: $waitingOther).textFieldStyle(.roundedBorder).frame(width: 110)
                    }

                    Text("รายละเอียด / ที่สั่งมา / ข้อความที่วางจาก LINE").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text).frame(minHeight: 90).font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                }
                .padding(22)
            }
            Divider()
            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("ยกเลิก") { dismiss() }
                Button("เพิ่มงาน") { save() }.keyboardShortcut(.defaultAction).disabled(title.isEmpty && text.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 640, height: 620)
        .onAppear {
            text = initialText
            if !initialText.isEmpty {
                source = .line
                title = String(initialText.split(separator: "\n").first ?? "").prefix(60).trimmingCharacters(in: .whitespaces)
            }
        }
        .onChange(of: kind) { _, _ in versions = [] }
    }

    var summary: String {
        var parts: [String] = []
        if !versions.isEmpty { parts.append("ไฟล์ \(versions.count) เวอร์ชัน") }
        if hasDraft { parts.append("ดราฟต์ \(Fmt.short(draft))") }
        if hasDue { parts.append("\(hasDraft ? "ไฟนอล" : "ส่ง") \(Fmt.short(due))") }
        if !waiting.isEmpty || !waitingOther.isEmpty { parts.append("รอ \(waiting.count + (waitingOther.isEmpty ? 0 : 1)) อย่าง") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.callout.weight(.medium)).frame(width: 64, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { content() } }
        }
    }

    func chip(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    func dateRow(_ d: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            DatePicker("", selection: d, displayedComponents: .date).labelsHidden().frame(width: 120)
            ForEach(QuickDate.allCases, id: \.self) { q in
                chip(q.label, on: Calendar.current.isDate(d.wrappedValue, inSameDayAs: q.date)) { d.wrappedValue = q.date }
            }
        }
    }

    func save() {
        let job = Importer(context: context).addManual(title: title, kind: kind, source: source, text: text, due: nil)
        job.requester = requester.trimmingCharacters(in: .whitespaces)
        let spec = ([kind == .video ? "วิดีโอ" : nil, length.isEmpty ? nil : length].compactMap { $0 }.joined(separator: " "))
        if !versions.isEmpty || !length.isEmpty {
            let art = Artwork(number: 1, spec: spec.isEmpty ? (title.isEmpty ? "ชิ้นงาน" : title) : spec,
                              size: versions.count == 1 ? versions[0] : nil, warning: nil, order: 0)
            context.insert(art); art.job = job
            for (k, v) in (versions.isEmpty ? ["ไฟล์"] : versions).enumerated() {
                let f = ArtFile(label: v, order: k); context.insert(f); f.artwork = art
            }
        }
        if hasDraft { let m = Milestone(label: "ดราฟต์แรก", date: draft, team: nil); context.insert(m); m.job = job }
        if hasDue { let m = Milestone(label: hasDraft ? "ไฟนอล" : "ส่งงาน", date: due, team: nil); context.insert(m); m.job = job }
        for w in waiting.sorted() + (waitingOther.isEmpty ? [] : [waitingOther]) {
            let item = WaitingItem(text: w); context.insert(item); item.job = job
        }
        try? context.save()
        Task { await ReminderSync.shared.sync(job) }
        center.show("เพิ่ม \"\(job.title)\" แล้ว")
        center.focusSection = .jobs
        center.focusJob = job.persistentModelID
        dismiss()
    }
}

/// ปุ่มลัดวันที่
enum QuickDate: CaseIterable {
    case tomorrow, in3, friday, nextMonday
    var label: String {
        switch self { case .tomorrow: "พรุ่งนี้"; case .in3: "+3 วัน"; case .friday: "ศุกร์นี้"; case .nextMonday: "จันทร์หน้า" }
    }
    static func days(_ n: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: n, to: Calendar.current.startOfDay(for: Date()))!
    }
    /// วันในสัปดาห์ถัดไป (weekday: 1=อาทิตย์ … 6=ศุกร์) ถ้าวันนี้คือวันนั้น = วันนี้
    static func next(weekday: Int, skipToday: Bool) -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let wd = Calendar.current.component(.weekday, from: today)
        var add = (weekday - wd + 7) % 7
        if add == 0 && skipToday { add = 7 }
        return Calendar.current.date(byAdding: .day, value: add, to: today)!
    }
    var date: Date {
        switch self {
        case .tomorrow: Self.days(1)
        case .in3: Self.days(3)
        case .friday: Self.next(weekday: 6, skipToday: false)
        case .nextMonday: Self.next(weekday: 2, skipToday: true)
        }
    }
}

// MARK: - ตั้งค่า

struct SettingsView: View {
    @AppStorage("ownerEmails") private var ownerEmails = ""
    @AppStorage("remindersOn") private var remindersOn = true
    @State private var accessText = ""
    @AppStorage("exportPattern") private var exportPattern = ""
    @AppStorage(WorkFolder.rootKey) private var workRoot = ""
    @AppStorage("aiOn") private var aiOn = true

    var workRootDisplay: String { WorkFolder.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    func pickRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "ใช้โฟลเดอร์นี้"
        if p.runModal() == .OK, let u = p.url { workRoot = u.path }
    }

    var body: some View {
        Form {
            Section("อีเมลของฉัน") {
                TextField("อีเมลงาน (คั่นด้วย ,)", text: $ownerEmails)
                Text("ใช้หาส่วน \"Graphic: @ชื่อเรา\" ในบรีฟ MARCOM").font(.caption).foregroundStyle(.secondary)
            }
            Section("แจ้งเตือน") {
                Toggle("เตือนเดดไลน์ผ่าน Reminders (ไปถึง iPhone)", isOn: $remindersOn)
                Text("สร้างรายการในลิสต์ \"\(ReminderSync.listName)\" เตือนเช้าวันก่อนส่ง 09:00 และเช้าวันส่ง 09:00 ส่งขึ้น iCloud แค่ชื่องานกับวันที่")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("ขอสิทธิ์ Reminders") {
                        Task { accessText = await ReminderSync.shared.requestAccess() ? "ได้สิทธิ์แล้ว" : "ไม่ได้สิทธิ์ เปิดที่ System Settings › Privacy & Security › Reminders" }
                    }
                    Text(accessText).font(.caption)
                }
            }
            Section("โฟลเดอร์งาน") {
                LabeledContent("ที่เก็บ") {
                    HStack {
                        Text(workRootDisplay).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("เปลี่ยน…") { pickRoot() }
                    }
                }
                Text("ค่าเริ่มต้นอยู่นอก Documents/Desktop จะได้ไม่ถูก sync ขึ้น iCloud").font(.caption).foregroundStyle(.secondary)
                TextField("รูปแบบชื่อไฟล์ส่งออก", text: $exportPattern, prompt: Text(ExportName.defaultPattern))
                Text("ตัวอย่าง: \(ExportName.make(job: "Summer Glow Package", number: 6, size: "1920×1080", variant: "แนวนอน", pattern: exportPattern.isEmpty ? ExportName.defaultPattern : exportPattern))  ·  ใช้ได้: {job} {n} {size} {variant} {date}")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("หน้าตา") {
                Picker("ธีม", selection: Binding(get: { AppAppearance.current }, set: {
                    UserDefaults.standard.set($0.rawValue, forKey: AppAppearance.key); $0.apply()
                })) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("AI") {
                Toggle("ใช้ AI ช่วยอ่านเมลที่ไม่มีฟอร์ม และแยกเมลตอบกลับ", isOn: $aiOn)
                LabeledContent("ตัวช่วยแยกข้อมูล", value: aiOn && AppleFMEnhancer.isAvailable ? AppleFMEnhancer().name : NoAIEnhancer().name)
                LabeledContent("Apple Intelligence", value: AIStatus.text)
                Text("AI ทำงานในเครื่องนี้เท่านั้น ไม่ส่งเมลออกไปไหน · บรีฟ MARCOM ใช้กฎอย่างเดียว · ผลจาก AI ต้องผ่านหน้ารอตรวจทุกครั้ง")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ข้อมูล") {
                Button("เปิดโฟลเดอร์ข้อมูลของแอป") { NSWorkspace.shared.open(Storage.root) }
                Text("ฐานข้อมูล อีเมลต้นฉบับ และไฟล์แนบ เก็บในเครื่องนี้เท่านั้น").font(.caption).foregroundStyle(.secondary)
                LabeledContent("สำรองล่าสุด", value: StoreBackup.backups.first.map { $0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "BriefBox ", with: "") } ?? "ยังไม่มี")
                Button("เปิดโฟลเดอร์สำรอง") {
                    try? FileManager.default.createDirectory(at: StoreBackup.dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(StoreBackup.dir)
                }
                Text("สำรองอัตโนมัติวันละครั้ง เก็บ 7 วันล่าสุดใน \"_สำรองกล่องบรีฟ\" ในโฟลเดอร์งาน · ถ้าฐานข้อมูลเปิดไม่ได้ แอปจะกู้จากสำรองให้เอง")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
    }
}
