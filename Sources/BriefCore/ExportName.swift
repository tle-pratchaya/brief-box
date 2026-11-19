import Foundation

/// ชื่อไฟล์ส่งออกของแต่ละชิ้นงาน เช่น SummerGlow_A3_1920x1005_H
public enum ExportName {
    public static let defaultPattern = "{job}_A{n}_{size}_{variant}"

    /// คำในชื่องานที่ตัดทิ้งเพราะยาวเกินโดยไม่ได้ช่วยแยกงาน
    static let stopWords: Set<String> = ["the", "a", "an", "at", "of", "for", "and", "in", "on", "to", "by", "with", "package", "marcom", "brief"]

    /// "Summer Glow Package at Lotus Studio" → "SummerGlowLotusStudio" (ตัดให้ไม่เกิน maxLength)
    public static func shortJob(_ title: String, maxLength: Int = 28) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let kept = words.filter { !stopWords.contains($0.lowercased()) && Int($0) == nil }
        var out = ""
        for w in (kept.isEmpty ? words : kept) {
            let cap = w.prefix(1).uppercased() + w.dropFirst()
            if out.count + cap.count > maxLength { break }
            out += cap
        }
        return out.isEmpty ? "Job" : out
    }

    /// "1080×1350" → "1080x1350", "4:5" → "4x5", "A4" → "A4"
    public static func sizeToken(_ size: String?) -> String {
        guard let s = size, !s.isEmpty else { return "" }
        return s.replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: ":", with: "x")
            .replacingOccurrences(of: " ", with: "")
    }

    /// ไฟล์ย่อยภาษาไทย → ตัวย่อสั้นๆ ในชื่อไฟล์
    public static func variantToken(_ label: String) -> String {
        let map = ["แนวนอน": "H", "แนวตั้ง": "V", "ไฟล์พิมพ์": "Print", "ไฟล์ดิจิทัล": "Digital", "ไฟล์": ""]
        if let v = map[label] { return v }
        if label.hasPrefix("แบบ") {
            let n = label.filter(\.isNumber)
            return n.isEmpty ? "v" : "v\(n)"
        }
        let ascii = label.folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return ascii
    }

    public static func make(job: String, number: Int, size: String?, variant: String,
                            pattern: String = defaultPattern, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyMMdd"
        var s = pattern
            .replacingOccurrences(of: "{job}", with: shortJob(job))
            .replacingOccurrences(of: "{n}", with: String(number))
            .replacingOccurrences(of: "{size}", with: sizeToken(size))
            .replacingOccurrences(of: "{variant}", with: variantToken(variant))
            .replacingOccurrences(of: "{date}", with: f.string(from: date))
        // เก็บกวาด _ ซ้อน หรือ _ ท้ายเมื่อบางช่องว่าง
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        return s
    }
}
