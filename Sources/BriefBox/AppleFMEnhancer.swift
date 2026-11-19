import Foundation
import FoundationModels
import BriefCore

// AI บนเครื่อง (Apple Foundation Models) — ไม่มีอะไรออกนอกเครื่อง
// ใช้กับ 2 กรณีที่กฎทำไม่ได้: เมลธรรมดาที่ไม่มีฟอร์ม (เช่น สั่งงานวิดีโอ) และเมลตอบกลับ (แยกแก้/งานเพิ่ม)
// บรีฟ MARCOM ที่กฎแยกได้ครบ ไม่ส่งให้ AI

@Generable
enum GenKind { case graphic, video, other }

@Generable
enum GenDeadlineKind { case draft, final, deadline, other }

@Generable
struct GenDeliverable {
    @Guide(description: "A piece of work the designer must CREATE, short, in the email's language, with quantity if more than one. e.g. 'Christmas teaser video 15s', '3 short clips 10s'. Materials the sender will provide (photos, music, logo, menu, text) are NOT deliverables.")
    var spec: String
    @Guide(description: "Dimensions, ratio or paper size exactly as written, e.g. '1080x1350', '9:16', 'A4'. Empty if not stated. Never guess.")
    var size: String
    @Guide(description: "Output versions that are separate files, e.g. ['Reels 9:16','Facebook 16:9'] or ['horizontal','vertical']. Empty if just one file.")
    var variants: [String]
}

@Generable
struct GenDeadline {
    @Guide(description: "The exact words from the email that state this deadline, e.g. 'Please send by 5 January'")
    var quote: String
    @Guide(description: "draft = first draft / first cut / first version; final = final version; deadline = a single 'send by' date; other = shooting day or a meeting the designer must attend")
    var kind: GenDeadlineKind
    @Guide(description: "Date as YYYY-MM-DD. Resolve the year from the email date.")
    var date: String
    @Guide(description: "Short label if kind is other, e.g. 'shooting day'. Otherwise empty.")
    var note: String
}

@Generable
struct GenBrief {
    @Guide(description: "video if the work is a video/clip/reel/motion, graphic for images/print/artwork, other if unclear")
    var kind: GenKind
    @Guide(description: "Every deliverable requested from the designer. Empty if none.", .maximumCount(15))
    var deliverables: [GenDeliverable]
    @Guide(description: "Dates when the designer must SUBMIT work or must attend a shoot. NOT the dates of the event, promotion period, offer validity or opening hours.", .maximumCount(5))
    var deadlines: [GenDeadline]
    @Guide(description: "Materials or information the sender says will come later (photos, prices, text, logo...). Short phrases.", .maximumCount(8))
    var waitingFor: [String]
}

@Generable
struct GenReply {
    @Guide(description: "Changes requested to work already in progress. One short imperative item each, keep numbers/prices exact. Approval, thanks or 'looks good' is NOT a change: return an empty list.", .maximumCount(15))
    var revisions: [String]
    @Guide(description: "NEW deliverables not in the original brief (new size, new channel, extra piece). One item each.", .maximumCount(8))
    var additions: [String]
    @Guide(description: "Materials the sender says will come later.", .maximumCount(5))
    var waitingFor: [String]
}

struct AppleFMEnhancer: BriefEnhancer {
    let name = "Apple Intelligence บนเครื่อง"
    static let maxChars = 6000   // context ~4K token: ตัดเมลยาว/ข้อความเก่าที่อ้างถึงออก

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static let instructions = """
    You help a graphic designer and video editor turn work-request emails into a checklist.
    Extract only what the email actually says. Never invent sizes, dates or deliverables.
    Ignore greetings, signatures and disclaimers.
    """

    func enhance(_ draft: BriefDraft) async -> BriefDraft {
        var d = draft
        do {
            switch d.source {
            case .marcomBrief:
                return d
            case .plainEmail:
                let text = String(BriefParser.stripQuoted(d.bodyText).prefix(Self.maxChars))
                let prompt = """
                Email date: \(Self.iso(d.sentAt))
                Subject: \(d.title)
                From: \(d.requester)

                \(text)
                """
                let s = LanguageModelSession(instructions: Self.instructions)
                let r = try await s.respond(to: prompt, generating: GenBrief.self,
                                            options: GenerationOptions(samplingMode: .greedy)).content
                AIMerge.apply(Self.map(r), to: &d, calendar: Self.calendar)
            case .reply:
                let text = String((d.replyText ?? d.bodyText).prefix(Self.maxChars))
                let prompt = """
                This is a reply in the thread "\(d.title)". Split the sender's requests into revisions to existing work \
                and additional new deliverables.

                \(text)
                """
                let s = LanguageModelSession(instructions: Self.instructions)
                let r = try await s.respond(to: prompt, generating: GenReply.self,
                                            options: GenerationOptions(samplingMode: .greedy)).content
                AIMerge.apply(AIReplyResult(revisions: r.revisions, additions: r.additions, waitingFor: r.waitingFor), to: &d)
            }
        } catch {
            d.notes.append("AI อ่านเมลนี้ไม่สำเร็จ (\(Self.reason(error))) ใช้ผลจากกฎอย่างเดียว")
        }
        return d
    }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        return c
    }

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd (EEEE)"
        return f.string(from: d)
    }

    static func map(_ g: GenBrief) -> AIBriefResult {
        let kind: JobKind? = switch g.kind { case .graphic: .graphic; case .video: .video; case .other: nil }
        return AIBriefResult(
            kind: kind,
            deliverables: g.deliverables.map { AIDeliverable(spec: $0.spec, size: $0.size, variants: $0.variants) },
            deadlines: g.deadlines.map {
                let k: AIDeadline.Kind = switch $0.kind { case .draft: .draft; case .final: .final; case .deadline: .deadline; case .other: .other }
                return AIDeadline(kind: k, date: $0.date, note: $0.note, quote: $0.quote)
            },
            waitingFor: g.waitingFor)
    }

    static func reason(_ e: Error) -> String {
        guard let g = e as? LanguageModelSession.GenerationError else { return e.localizedDescription }
        switch g {
        case .exceededContextWindowSize: return "เมลยาวเกิน"
        case .guardrailViolation: return "ระบบกรองเนื้อหาของ Apple ไม่ยอมอ่าน"
        case .unsupportedLanguageOrLocale: return "ภาษาไม่รองรับ"
        case .assetsUnavailable: return "โมเดลยังไม่พร้อม"
        default: return "\(g)"
        }
    }
}
