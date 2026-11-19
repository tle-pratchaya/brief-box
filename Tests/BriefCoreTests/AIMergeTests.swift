import Foundation
import Testing
@testable import BriefCore

let plainVideoMail = """
From: "Boss, Big" <big.boss@company.example>
To: "Designer, Ploy" <designer@company.example>
Subject: Christmas teaser video
Date: Tue, 3 Nov 2026 00:30:00 +0000
Message-ID: <vid1@company.example>
Content-Type: text/plain; charset="utf-8"

Hi Ploy, please make a short teaser for the Christmas dinner, around 15 seconds, for Reels and Story.
I will send the product photos later. Need it before Dec 1.
"""

let replyMail = """
From: "Writer, Nok" <nok.writer@company.example>
To: "Designer, Ploy" <designer@company.example>
Subject: RE: MARCOM BRIEF: Year-End Soiree
Date: Wed, 18 Nov 2026 03:00:00 +0000
Message-ID: <r1@company.example>
In-Reply-To: <abc123@company.example>
Content-Type: text/plain; charset="utf-8"

Hi Ploy, please change the price to 1,290 and make the logo bigger. Also can you do one more for LINE OA 1040x1040?
"""

struct AIMergeTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Bangkok")!; return c }()

    func draft(_ s: String) -> BriefDraft {
        BriefParser(ownerEmails: [me]).parse(MIMEMessage(data: Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8)))
    }

    @Test func fillsPlainEmail() {
        var d = draft(plainVideoMail)
        #expect(d.source == .plainEmail && d.artworks.isEmpty && d.notes.contains(AIMerge.noteManual))
        let ai = AIBriefResult(kind: .video,
            deliverables: [AIDeliverable(spec: "Christmas dinner teaser 15s", size: "9:16", variants: ["Reels", "Story"])],
            deadlines: [AIDeadline(kind: .deadline, date: "2026-12-01"), AIDeadline(kind: .final, date: "2031-01-01")],
            waitingFor: ["Menu photos"])
        AIMerge.apply(ai, to: &d, calendar: cal)
        #expect(d.kind == .video)
        #expect(d.artworks.count == 1 && d.artworks[0].files == ["Reels", "Story"] && d.artworks[0].warning == nil)
        #expect(d.deadlines.count == 1)   // ปี 2031 ถูกตัดทิ้ง
        #expect(cal.component(.day, from: d.deadlines[0].date) == 1 && d.deadlines[0].label == "ส่งงาน")
        #expect(d.waitingFor.contains { $0.lowercased().contains("product photos") })
        #expect(!d.notes.contains(AIMerge.noteManual) && d.notes.contains { $0.hasPrefix("🤖") })
    }

    @Test func rulesWinOverAI() {
        var d = draft(syntheticBrief)
        let arts = d.artworks, dls = d.deadlines, kind = d.kind
        AIMerge.apply(AIBriefResult(kind: .video, deliverables: [AIDeliverable(spec: "x")],
                                    deadlines: [AIDeadline(kind: .draft, date: "2026-11-10")], waitingFor: []), to: &d, calendar: cal)
        #expect(d.artworks == arts && d.deadlines == dls && d.kind == kind)
    }

    @Test func emptyAIChangesNothing() {
        var d = draft(plainVideoMail)
        AIMerge.apply(AIBriefResult(kind: nil, deliverables: [], deadlines: [AIDeadline(kind: .draft, date: "soon")], waitingFor: []), to: &d, calendar: cal)
        #expect(d.notes.contains(AIMerge.noteManual) && d.artworks.isEmpty && d.deadlines.isEmpty)
    }

    @Test func replySplit() {
        var d = draft(replyMail)
        #expect(d.source == .reply)
        AIMerge.apply(AIReplyResult(revisions: ["Change price to 1,290", "Make logo bigger", " "],
                                    additions: ["LINE OA 1040x1040"], waitingFor: []), to: &d)
        #expect(d.aiRevisions == ["Change price to 1,290", "Make logo bigger"])
        #expect(d.aiAdditions == ["LINE OA 1040x1040"])
    }

    @Test func filtersFromRealRun() {
        // ข้อผิดพลาดจริงจากรอบทดสอบแรกบน M5 (11-17)
        var d = draft(plainVideoMail)
        let ai = AIBriefResult(kind: .graphic,
            deliverables: [AIDeliverable(spec: "IG post", size: "1080x1350"), AIDeliverable(spec: "music"),
                           AIDeliverable(spec: "product photos")],
            deadlines: [AIDeadline(kind: .deadline, date: "2026-12-10", quote: "available 10-16 December"),
                        AIDeadline(kind: .deadline, date: "2026-11-30", quote: "Please send by 30 November")],
            waitingFor: ["product photos", "Product Photos"])
        AIMerge.apply(ai, to: &d, calendar: cal)
        #expect(d.artworks.map(\.spec) == ["IG post"])
        #expect(d.deadlines.count == 1 && cal.component(.day, from: d.deadlines[0].date) == 30)
        #expect(d.waitingFor.filter { $0.lowercased().contains("product photos") }.count == 1)
    }

    @Test func approvalIsNotRevision() {
        var d = draft(replyMail)
        AIMerge.apply(AIReplyResult(revisions: ["Looks great, approved.", "Thank you!", "Approved but change the date to 5 Dec"],
                                    additions: [], waitingFor: []), to: &d)
        #expect(d.aiRevisions == ["Approved but change the date to 5 Dec"])
    }

    @Test func ruleDeadlineWhenAIGivesNone() {
        var d = draft(plainVideoMail.replacingOccurrences(of: "Need it before Dec 1.", with: "Please send by 5 December. Available 10-16 February."))
        AIMerge.apply(AIBriefResult(kind: .graphic, deliverables: [AIDeliverable(spec: "IG post")], deadlines: [],
                                    waitingFor: ["product photos from the studio"]), to: &d, calendar: cal)
        #expect(d.deadlines.count == 1 && cal.component(.month, from: d.deadlines[0].date) == 12 && cal.component(.day, from: d.deadlines[0].date) == 5)
        #expect(AIMerge.sameWords("Photos will follow from the pastry team", "photos from the pastry team"))
        #expect(!AIMerge.sameWords("logo", "partner list"))
    }
}
