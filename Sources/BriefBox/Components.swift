import AppKit
import SwiftUI
import BriefCore

extension JobKind {
    var color: Color {
        switch self { case .graphic: .purple; case .video: .orange; case .other: .gray }
    }
}

extension JobStatus {
    var color: Color {
        switch self {
        case .todo: .gray; case .doing: .blue; case .draftSent: .teal
        case .revising: .orange; case .finalSent: .indigo; case .done: .green
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = .gray
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .lineLimit(1)
    }
}

enum Fmt {
    static let thai: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar.current
        f.dateFormat = "d MMM yyyy"
        return f
    }()
    static let thaiShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "th_TH")
        f.calendar = Calendar.current
        f.dateFormat = "EEE d MMM"
        return f
    }()
    static func date(_ d: Date) -> String { thai.string(from: d) }
    static func full(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "th_TH"); f.calendar = Calendar.current
        f.dateFormat = "EEEEที่ d MMMM yyyy"; return f.string(from: d)
    }
    static func month(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "th_TH"); f.calendar = Calendar.current
        f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }
    static func short(_ d: Date) -> String { thaiShort.string(from: d) }

    static func daysText(_ n: Int?) -> String {
        guard let n else { return "" }
        switch n {
        case ..<0: return "เลยมา \(-n) วัน"
        case 0: return "วันนี้"
        case 1: return "พรุ่งนี้"
        default: return "อีก \(n) วัน"
        }
    }
}

func urgencyColor(_ job: Job) -> Color {
    guard job.status != .done else { return .green }
    guard let n = job.daysLeft else { return .secondary.opacity(0.4) }
    if n < 0 { return .red }
    if n <= 2 { return .red.opacity(0.85) }
    if n <= 5 { return .orange }
    return .accentColor
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func openLocation(_ loc: String) {
    if loc.hasPrefix("http"), let u = URL(string: loc) { NSWorkspace.shared.open(u) }
    else { NSWorkspace.shared.open(URL(fileURLWithPath: loc)) }
}

struct SectionCard<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

/// ข้อความเมลพร้อมไฮไลต์ส่วนของเรา
struct EmailTextView: View {
    let body_: String
    let highlight: String?
    init(body: String, highlight: String?) { body_ = body; self.highlight = highlight }

    var body: some View {
        ScrollView {
            Text(attributed)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    var attributed: AttributedString {
        var a = AttributedString(body_)
        if let h = highlight?.trimmingCharacters(in: .whitespacesAndNewlines), h.count > 10,
           let r = a.range(of: String(h.prefix(60))) {
            let endKey = String(h.suffix(40))
            let end = a[r.lowerBound...].range(of: endKey)?.upperBound ?? r.upperBound
            a[r.lowerBound..<end].backgroundColor = Color.purple.opacity(0.18)
        }
        return a
    }
}
