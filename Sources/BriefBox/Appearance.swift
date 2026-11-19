import AppKit
import SwiftUI

/// ธีมของแอป: ตามระบบ / สว่าง / มืด (ไม่ไปแตะธีมของเครื่อง)
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { switch self { case .system: "ตามเครื่อง"; case .light: "สว่าง"; case .dark: "มืด" } }
    var icon: String { switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" } }

    static let key = "appearance"
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// ใช้ NSApp.appearance แทน preferredColorScheme เพราะสลับกลับ "ตามเครื่อง" ได้ทันทีโดยไม่ต้องเปิดแอปใหม่
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// ปุ่มสลับธีม (วางบนแถบเครื่องมือ)
struct AppearanceButton: View {
    @AppStorage(AppAppearance.key) private var raw = AppAppearance.system.rawValue

    var mode: AppAppearance { AppAppearance(rawValue: raw) ?? .system }

    var body: some View {
        Menu {
            Picker("ธีม", selection: $raw) {
                ForEach(AppAppearance.allCases) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("ธีม: \(mode.label)", systemImage: mode.icon)
        }
        .help("สลับธีม สว่าง / มืด / ตามเครื่อง")
        .onChange(of: raw) { _, _ in mode.apply() }
    }
}
