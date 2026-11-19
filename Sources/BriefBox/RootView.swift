import SwiftData
import SwiftUI
import BriefCore

enum SidebarSection: String, Hashable, CaseIterable {
    case today, calendar, review, jobs, done
    var label: String {
        switch self { case .today: "วันนี้"; case .calendar: "ปฏิทิน"; case .review: "รอตรวจ"; case .jobs: "งานทั้งหมด"; case .done: "เสร็จแล้ว" }
    }
    var icon: String {
        switch self { case .today: "sun.horizon"; case .calendar: "calendar"; case .review: "tray.full"; case .jobs: "checklist"; case .done: "archivebox" }
    }
}

struct RootView: View {
    @EnvironmentObject var center: ImportCenter
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Job> { $0.isPendingReview }, sort: \Job.createdAt) private var pending: [Job]
    @Query(sort: \PendingReply.sentAt) private var replies: [PendingReply]
    @Query(filter: #Predicate<Job> { !$0.isPendingReview }) private var jobs: [Job]
    @AppStorage("ownerEmails") private var ownerEmails = ""

    @State private var section: SidebarSection? = .today
    @State private var selectedJob: PersistentIdentifier?
    @State private var selectedReply: PersistentIdentifier?
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SidebarSection.allCases, id: \.self) { s in
                    Label(s.label, systemImage: s.icon)
                        .badge(badge(for: s))
                        .tag(s)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    DropBox()
                    Button { center.addSheetText = ""; center.showAddSheet = true } label: {
                        Label("เพิ่มงานเอง", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .toolbar { ToolbarItem { AppearanceButton() } }
        } content: {
            switch section ?? .today {
            case .today: TodayView(selection: $selectedJob)
            case .calendar: CalendarView(selection: $selectedJob)
            case .review: ReviewListView(selectedJob: $selectedJob, selectedReply: $selectedReply)
            case .jobs: JobListView(done: false, selection: $selectedJob)
            case .done: JobListView(done: true, selection: $selectedJob)
            }
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let t = center.toast {
                Text(t)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 6)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.toast)
        .sheet(isPresented: $center.showAddSheet) { AddJobSheet(initialText: center.addSheetText) }
        .sheet(isPresented: $showOnboarding) { OnboardingSheet() }
        .alert("กู้ข้อมูลแล้ว", isPresented: Binding(get: { center.recoveryNotice != nil },
                                                      set: { if !$0 { center.recoveryNotice = nil } })) {
            Button("ตกลง") { center.recoveryNotice = nil }
            Button("เปิดโฟลเดอร์ข้อมูล") { NSWorkspace.shared.open(Storage.root); center.recoveryNotice = nil }
        } message: {
            Text(center.recoveryNotice ?? "")
        }
        .onAppear { if ownerEmails.trimmingCharacters(in: .whitespaces).isEmpty { showOnboarding = true } }
        .onChange(of: center.focusSection) { _, s in if let s { section = s; center.focusSection = nil } }
        .onChange(of: center.focusJob) { _, id in if let id { selectedJob = id; selectedReply = nil; center.focusJob = nil } }
        .onChange(of: section) { _, _ in selectedJob = nil; selectedReply = nil }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await center.importFiles(urls.filter(\.isFileURL)) }
            return true
        }
    }

    @ViewBuilder var detail: some View {
        if let id = selectedReply, let r = replies.first(where: { $0.persistentModelID == id }) {
            ReplyReviewView(reply: r) { selectedReply = nil }
        } else if let id = selectedJob, let job = (pending + jobs).first(where: { $0.persistentModelID == id }) {
            if job.isPendingReview {
                ReviewJobView(job: job) { selectedJob = nil }
            } else {
                JobDetailView(job: job)
            }
        } else if section == .review && pending.isEmpty && replies.isEmpty {
            VStack(spacing: 16) {
                Text("ยังไม่มีอะไรรอตรวจ").font(.title3)
                DropBox(tall: true).frame(maxWidth: 420)
            }.padding(40)
        } else {
            ContentUnavailableView("เลือกงานจากรายการ", systemImage: "square.stack.3d.up",
                                   description: Text("หรือลากอีเมลบรีฟจาก Outlook มาวางที่กล่องด้านซ้าย"))
        }
    }

    func badge(for s: SidebarSection) -> Int {
        switch s {
        case .review: pending.count + replies.count
        case .today: jobs.filter(\.isDueNow).count
        case .calendar: 0
        case .jobs: jobs.filter { $0.status != .done && ($0.daysLeft ?? 99) <= 2 }.count
        case .done: 0
        }
    }
}

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ownerEmails") private var ownerEmails = ""
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ตั้งค่าครั้งแรก").font(.title2.bold())
            Text("ใส่อีเมลงานของคุณ แอปใช้หาส่วน \"Graphic: @ชื่อคุณ\" ในบรีฟ เพื่อดึงเฉพาะงานที่สั่งคุณ")
                .foregroundStyle(.secondary)
            TextField("name.surname@company.com", text: $draft)
                .textFieldStyle(.roundedBorder)
            Text("ถ้ามีหลายอีเมล คั่นด้วยเครื่องหมายจุลภาค (,)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("ข้ามไปก่อน") { dismiss() }
                Button("บันทึก") { ownerEmails = draft; dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.contains("@"))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
