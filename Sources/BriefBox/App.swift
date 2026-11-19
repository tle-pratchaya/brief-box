import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import BriefCore

@main
struct BriefBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var center = ImportCenter.shared

    var body: some Scene {
        // หน้าต่างเดียว: เปิดไฟล์ .eml (ดับเบิลคลิก/Open With) จะเข้า AppDelegate ไม่สร้างหน้าต่างซ้อน
        Window("กล่องบรีฟ", id: "main") {
            RootView()
                .environmentObject(center)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .modelContainer(ImportCenter.shared.container)
        .commands {
            CommandGroup(after: .newItem) {
                Button("นำเข้าไฟล์อีเมล (.eml)…") { center.openPanel() }.keyboardShortcut("o")
                Button("เพิ่มงานเอง…") { center.showAddSheet = true }.keyboardShortcut("n")
            }
            CommandMenu("ธีม") {
                ForEach(AppAppearance.allCases) { mode in
                    Button(mode.label) {
                        UserDefaults.standard.set(mode.rawValue, forKey: AppAppearance.key)
                        mode.apply()
                    }
                    .keyboardShortcut(mode == .dark ? "d" : (mode == .light ? "l" : "0"), modifiers: [.command, .shift])
                }
            }
        }
        Settings {
            SettingsView().environmentObject(center)
        }
        .modelContainer(ImportCenter.shared.container)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.current.apply()
        AIStatus.logNow()
        AITestRunner.runIfRequested()
        SelfUpdate.start()
        DockBadge.start()
        HealthFile.write(backup: nil)
        StoreBackup.runIfDue()
        // เปิดใหม่จากการอัปเดตอัตโนมัติ = อยู่เบื้องหลัง ไม่แย่งโฟกัส
        if !CommandLine.arguments.contains("--background") { NSApp.activate(ignoringOtherApps: true) }    }
    /// คลิกขวาไฟล์ .eml → Open With → กล่องบรีฟ
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await ImportCenter.shared.importFiles(urls) }
    }
}

/// ศูนย์กลางการนำเข้า + ข้อความแจ้งผล
@MainActor
final class ImportCenter: ObservableObject {
    static let shared = ImportCenter()

    let container: ModelContainer
    @Published var toast: String?
    @Published var showAddSheet = false
    @Published var addSheetText = ""
    @Published var focusJob: PersistentIdentifier?
    @Published var focusSection: SidebarSection?
    /// แจ้งผู้ใช้ครั้งเดียวเมื่อเปิดฐานข้อมูลเดิมไม่ได้และต้องกู้ (แสดงใน RootView)
    @Published var recoveryNotice: String?

    init() {
        let schema = Schema([Job.self, Artwork.self, ArtFile.self, Milestone.self, LogEntry.self,
                             CopyText.self, RefItem.self, WaitingItem.self, PendingReply.self])
        container = StoreRecovery.open(schema: schema)
        recoveryNotice = StoreRecovery.notice
    }

    func importFiles(_ urls: [URL]) async {
        var messages: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["eml", "msg", ""].contains(ext) || ext.isEmpty else {
                messages.append("\(url.lastPathComponent): รับเฉพาะไฟล์อีเมล .eml"); continue
            }
            if ext == "msg" { messages.append("\(url.lastPathComponent): ไฟล์ .msg ยังอ่านไม่ได้ ลากจาก Outlook ใหม่ให้เป็น .eml"); continue }
            let result = await Importer(context: container.mainContext).importEmail(at: url)
            messages.append(result.message)
            switch result {
            case .newJob(let j): focusSection = .review; focusJob = j.persistentModelID
            case .reply: focusSection = .review
            default: break
            }
        }
        show(messages.joined(separator: "\n"))
    }

    func receiveText(_ text: String) {
        addSheetText = text
        showAddSheet = true
    }

    func show(_ message: String) {
        toast = message
        let current = message
        Task { try? await Task.sleep(for: .seconds(4)); if toast == current { toast = nil } }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.prompt = "นำเข้า"
        if panel.runModal() == .OK { Task { await importFiles(panel.urls) } }
    }
}
