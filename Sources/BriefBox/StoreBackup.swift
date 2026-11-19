import AppKit
import Foundation
import SQLite3
import SwiftData

/// สำรองฐานข้อมูลวันละครั้ง + กู้คืนเมื่อเปิดฐานข้อมูลไม่ได้
/// ที่เก็บ: <โฟลเดอร์งาน>/_สำรองกล่องบรีฟ/  (นอก Documents → ไม่ขึ้น iCloud, Time Machine เก็บได้)
///   BriefBox yyyy-MM-dd.store   ไฟล์เดียวสมบูรณ์ (VACUUM INTO) เก็บ 7 วันล่าสุด
///   files/<uuid>/               สำเนาอีเมลต้นฉบับ + ไฟล์แนบ (เพิ่มอย่างเดียว ไม่ลบ)
enum StoreBackup {
    static let keep = 7
    static var dir: URL { WorkFolder.root.appendingPathComponent("_สำรองกล่องบรีฟ", isDirectory: true) }
    static var storeURL: URL { Storage.root.appendingPathComponent("BriefBox.store") }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// ไฟล์สำรองทั้งหมด ใหม่สุดก่อน
    static var backups: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("BriefBox ") && $0.pathExtension == "store" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: สำรอง

    static var running = false

    /// เรียกได้บ่อย (ทุก 30 วิ) — ทำจริงแค่วันละครั้ง ทำงานเบื้องหลัง
    @MainActor static func runIfDue() {
        let target = dir.appendingPathComponent("BriefBox \(day(Date())).store")
        // รอบที่ต้องกู้ข้อมูล: ไม่สำรองทับ จะได้ไม่ดันสำรองดีๆ ตกจาก 7 วันล่าสุด
        guard !running, !StoreRecovery.recoveredThisLaunch,
              !FileManager.default.fileExists(atPath: target.path),
              FileManager.default.fileExists(atPath: storeURL.path) else { return }
        running = true
        // ให้ข้อมูลที่ค้างใน context ลงไฟล์ก่อน
        try? ImportCenter.shared.container.mainContext.save()
        let src = storeURL, filesSrc = Storage.root.appendingPathComponent("files", isDirectory: true), out = dir
        Task.detached(priority: .utility) {
            let result = backup(store: src, files: filesSrc, to: out, target: target)
            await MainActor.run {
                running = false
                HealthFile.write(backup: result)
            }
        }
    }

    /// คืนข้อความผล (บันทึกลง health.txt)
    nonisolated static func backup(store: URL, files: URL, to out: URL, target: URL) -> String {
        let fm = FileManager.default
        do { try fm.createDirectory(at: out, withIntermediateDirectories: true) } catch { return "สร้างโฟลเดอร์สำรองไม่ได้: \(error.localizedDescription)" }
        let tmp = out.appendingPathComponent(".tmp-\(UUID().uuidString).store")
        defer { try? fm.removeItem(at: tmp) }
        if let err = vacuumInto(source: store, dest: tmp) { return "สำรองไม่สำเร็จ: \(err)" }
        guard quickCheck(tmp) else { return "สำรองไม่สำเร็จ: ไฟล์สำรองตรวจไม่ผ่าน" }
        do { try fm.moveItem(at: tmp, to: target) } catch { return "ย้ายไฟล์สำรองไม่ได้: \(error.localizedDescription)" }

        // อีเมลต้นฉบับ + ไฟล์แนบ: คัดลอกเฉพาะโฟลเดอร์ใหม่
        let filesOut = out.appendingPathComponent("files", isDirectory: true)
        try? fm.createDirectory(at: filesOut, withIntermediateDirectories: true)
        var copied = 0
        for f in (try? fm.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? [] {
            let dest = filesOut.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: dest.path), (try? fm.copyItem(at: f, to: dest)) != nil { copied += 1 }
        }

        // เก็บ 7 ไฟล์ล่าสุด
        let all = ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("BriefBox ") && $0.pathExtension == "store" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(keep) { try? fm.removeItem(at: old) }
        return "สำรองแล้ว \(target.lastPathComponent) · ไฟล์แนบใหม่ \(copied) ชุด · เก็บ \(min(all.count, keep)) วัน"
    }

    /// สำเนาไฟล์เดียวที่สมบูรณ์ แม้ฐานข้อมูลเปิดอยู่และมี -wal ค้าง
    nonisolated static func vacuumInto(source: URL, dest: URL) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return String(cString: sqlite3_errmsg(db))
        }
        sqlite3_busy_timeout(db, 5000)
        let sql = "VACUUM INTO '\(dest.path.replacingOccurrences(of: "'", with: "''"))'"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return String(cString: sqlite3_errmsg(db)) }
        return nil
    }

    nonisolated static func quickCheck(_ url: URL) -> Bool {
        var db: OpaquePointer?, stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: c) == "ok"
    }
}

/// เปิดฐานข้อมูลแบบไม่ล้ม: เปิดไม่ได้ → ย้ายไฟล์เดิมไปเก็บ → กู้จากสำรองล่าสุด → ไม่ได้อีกค่อยเริ่มว่าง
enum StoreRecovery {
    nonisolated(unsafe) static var notice: String?
    nonisolated(unsafe) static var recoveredThisLaunch = false

    static func open(schema: Schema) -> ModelContainer {
        let url = StoreBackup.storeURL
        let config = ModelConfiguration(schema: schema, url: url)
        if let c = try? ModelContainer(for: schema, configurations: config) { return c }
        // ลองซ้ำ 1 ครั้ง (เผื่อไฟล์ถูกล็อกชั่วคราวตอนเปิดเครื่อง)
        Thread.sleep(forTimeInterval: 1)
        if let c = try? ModelContainer(for: schema, configurations: config) { return c }

        recoveredThisLaunch = true
        let fm = FileManager.default
        let stamp = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"; return f.string(from: Date()) }()
        let broken = Storage.root.appendingPathComponent("ข้อมูลที่เปิดไม่ได้ \(stamp)", isDirectory: true)
        try? fm.createDirectory(at: broken, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let f = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: f.path) { try? fm.moveItem(at: f, to: broken.appendingPathComponent(f.lastPathComponent)) }
        }
        let keptNote = "ไฟล์เดิมเก็บไว้ที่ \(broken.path)"

        for b in StoreBackup.backups {
            try? fm.removeItem(at: url)
            guard (try? fm.copyItem(at: b, to: url)) != nil else { continue }
            if let c = try? ModelContainer(for: schema, configurations: config) {
                notice = "เปิดฐานข้อมูลเดิมไม่ได้ จึงกู้จากสำรอง \(b.lastPathComponent) แล้ว\nงานที่เพิ่ม/แก้หลังวันนั้นอาจหายไป ให้ตรวจอีกครั้ง\n\(keptNote)"
                return c
            }
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        }
        if let c = try? ModelContainer(for: schema, configurations: config) {
            notice = "เปิดฐานข้อมูลเดิมไม่ได้ และไม่มีสำรองที่ใช้ได้ จึงเริ่มฐานข้อมูลใหม่ว่างเปล่า\n\(keptNote)"
            return c
        }
        notice = "เปิด/สร้างฐานข้อมูลไม่ได้เลย แอปเปิดแบบชั่วคราว — สิ่งที่ทำตอนนี้จะไม่ถูกบันทึก\n\(keptNote)"
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

}

/// /Users/Shared/BriefBox/health.txt — ให้ตรวจจากบัญชีอื่นผ่าน ssh ได้ (เหมือน ai-status.txt)
@MainActor
enum HealthFile {
    static var lastBackup = "-"

    static func write(backup: String?) {
        if let backup { lastBackup = backup }
        let latest = StoreBackup.backups.first?.lastPathComponent ?? "ไม่มี"
        let text = """
        \(ISO8601DateFormatter().string(from: Date())) user=\(NSUserName()) version=\(SelfUpdate.launchedVersion)
        recovery: \(StoreRecovery.notice?.replacingOccurrences(of: "\n", with: " | ") ?? "ไม่มี")
        backup: \(lastBackup)
        latest: \(latest) (ทั้งหมด \(StoreBackup.backups.count))
        dir: \(StoreBackup.dir.path)

        """
        let d = URL(fileURLWithPath: "/Users/Shared/BriefBox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? text.write(to: d.appendingPathComponent("health.txt"), atomically: true, encoding: .utf8)
    }
}
