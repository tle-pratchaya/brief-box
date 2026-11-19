import AppKit
import SwiftUI

/// พื้นที่รับการลากวาง รองรับทั้งไฟล์ .eml, file promise (ลากจาก Outlook/Mail) และข้อความ (เช่น จาก LINE)
struct DropZone: NSViewRepresentable {
    var onFiles: ([URL]) -> Void
    var onText: (String) -> Void
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> DropNSView {
        let v = DropNSView()
        v.onFiles = onFiles; v.onText = onText; v.onHover = { hovering = $0 }
        return v
    }

    func updateNSView(_ v: DropNSView, context: Context) {
        v.onFiles = onFiles; v.onText = onText; v.onHover = { hovering = $0 }
    }
}

final class DropNSView: NSView {
    var onFiles: ([URL]) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    private let queue = OperationQueue()

    override init(frame: NSRect) {
        super.init(frame: frame)
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += [.fileURL, .string]
        registerForDraggedTypes(types)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onHover(true); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        onHover(false)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles(urls)
            return true
        }
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBoxDrop-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for r in receivers {
                r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { [weak self] url, error in
                    DispatchQueue.main.async {
                        if error == nil { self?.onFiles([url]) }
                    }
                }
            }
            return true
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onText(s)
            return true
        }
        return false
    }
}

/// กล่อง "ลากอีเมลมาวางที่นี่"
struct DropBox: View {
    @EnvironmentObject var center: ImportCenter
    @State private var hovering = false
    var tall = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: hovering ? 2.5 : 1.5, dash: [6, 4]))
                .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.accentColor.opacity(0.12) : Color.clear))
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: tall ? 34 : 20))
                Text("ลากอีเมลจาก Outlook มาวางที่นี่").font(tall ? .headline : .callout).multilineTextAlignment(.center)
                if tall {
                    Text("หรือลากข้อความจาก LINE เพื่อเพิ่มงานเอง").font(.callout).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(hovering ? Color.accentColor : .secondary)
            .padding(10)
            .allowsHitTesting(false)
            DropZone(onFiles: { urls in Task { await center.importFiles(urls) } },
                     onText: { center.receiveText($0) }, hovering: $hovering)
        }
        .frame(height: tall ? 200 : 92)
    }
}
