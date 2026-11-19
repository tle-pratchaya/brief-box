import AppKit

/// อัปเดตจากระยะไกลโดยไม่ต้องให้ผู้ใช้ปิด/เปิดเอง:
/// เมื่อ rsync เวอร์ชันใหม่ทับใน /Applications แล้ว แอปจะเปิดตัวเองใหม่ (เบื้องหลัง ไม่แย่งโฟกัส)
/// เฉพาะตอนที่ผู้ใช้ไม่ได้ใช้แอปมาแล้ว ≥ 2 นาที · ทุก 30 วินาทียังตรวจโฟลเดอร์ทดสอบ AI ด้วย
@MainActor
enum SelfUpdate {
    static let launchedVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    static var inactiveSince: Date? = nil
    static var timer: Timer?
    static var seenVersion: String? = nil   // ต้องเห็นเวอร์ชันใหม่เดิม 2 รอบติด (กันอ่านระหว่าง rsync/build)

    static var diskVersion: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: url) else { return nil }
        return d["CFBundleVersion"] as? String
    }

    static func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { inactiveSince = Date() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { inactiveSince = nil }
        }
        if !NSApp.isActive { inactiveSince = Date() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func tick() {
        AITestRunner.runIfRequested()
        StoreBackup.runIfDue()
        guard let v = diskVersion, !v.isEmpty, v != launchedVersion else { seenVersion = nil; return }
        defer { seenVersion = v }
        guard seenVersion == v,
              FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BriefBox").path),
              let since = inactiveSince, Date().timeIntervalSince(since) >= 120,
              NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return }
        relaunch()
    }

    static func relaunch() {
        try? ImportCenter.shared.container.mainContext.save()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; for i in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/open -g \"$0\" --args --background && exit 0; sleep 5; done", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
