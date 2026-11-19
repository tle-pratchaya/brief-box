import Foundation
import Testing
@testable import BriefCore

/// เมลตัวอย่างสังเคราะห์ เลียนโครงบรีฟจริง (ชื่อคนสมมติ) ใช้ทดสอบได้ทุกเครื่อง
let me = "designer@company.example"

let syntheticBrief = """
From: "Writer, Nok" <nok.writer@company.example>
To: "Designer, Ploy" <designer@company.example>, "Social, Bee" <bee.social@company.example>
CC: "Boss, Big" <big.boss@company.example>
Subject: =?Windows-1252?Q?MARCOM_BRIEF:_Year-End_Soir=E9e?=
Thread-Topic: MARCOM BRIEF: Year-End Soiree
Date: Tue, 3 Nov 2026 00:30:00 +0000
Message-ID: <abc123@company.example>
X-Mentions: designer@company.example,bee.social@company.example
Content-Type: multipart/mixed; boundary="BOUND"
MIME-Version: 1.0

--BOUND
Content-Type: text/plain; charset="Windows-1252"
Content-Transfer-Encoding: quoted-printable

Dear Team,

Brief:
Brief Form.doc<https://example.sharepoint.com/sites/x/doc.aspx?id=3D1>

Graphic: @Designer, Ploy<mailto:designer@company.example>
Artwork request: 4 in total
Artwork 1: 4:5 artwork (for Instagram and Facebook)
Artwork 2: 1920 =D7 1005 px (Facebook post)
Artwork 3: LCD (horizontal and vertical)
Artwork 4: A4 Flyer for Customers (printed and digital)

Picture: Stock photo. Please see artwork from previous years.
First Draft - 16 November / Final Draft - 20 November 2026
Please include the website link (I will share with you later)

Social Media: @Social, Bee<mailto:bee.social@company.example>
Posts start from 25 Nov 2026.

Short Text:
Year-End Soiree
Join us for a Soir=E9e.
THB 1,900 net per person

--BOUND
Content-Type: image/jpeg; name="sample 2025.jpg"
Content-Disposition: attachment; filename="sample 2025.jpg"
Content-Transfer-Encoding: base64

/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/
--BOUND--
"""

let syntheticReply = """
From: "Writer, Nok" <nok.writer@company.example>
To: "Designer, Ploy" <designer@company.example>
Subject: RE: MARCOM BRIEF: Year-End Soiree
Date: Fri, 6 Nov 2026 03:00:00 +0000
Message-ID: <reply1@company.example>
In-Reply-To: <abc123@company.example>
References: <abc123@company.example>
Content-Type: text/plain; charset="utf-8"

Hi Ploy,

Please make the price bigger on all artworks, and add one more IG Story for New Year.
The website link will follow tomorrow.

________________________________
From: Designer, Ploy <designer@company.example>
Sent: Thursday, November 5, 2026
Subject: RE: MARCOM BRIEF

Draft attached.
"""

func cal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Bangkok")!
    return c
}

func ymd(_ d: Date) -> String {
    let c = cal().dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

@Test func mimeHeadersAndBody() {
    let m = MIMEMessage(data: Data(syntheticBrief.utf8))
    #expect(m.subject == "MARCOM BRIEF: Year-End Soirée")
    #expect(m.from?.displayName == "Nok Writer")
    #expect(m.mentions.contains(me))
    #expect(m.bodyText.contains("1920 × 1005 px"))
    #expect(m.attachments.count == 1)
    #expect(m.attachments.first?.filename == "sample 2025.jpg")
    #expect(m.attachments.first!.data.count > 50)
}

@Test func parsesMyBriefSection() {
    let d = BriefParser(ownerEmails: [me]).parse(MIMEMessage(data: Data(syntheticBrief.utf8)))
    #expect(d.source == .marcomBrief)
    #expect(d.title == "Year-End Soirée")
    #expect(d.kind == .graphic)
    #expect(d.mentionsMe)
    #expect(d.myRole == "Graphic")
    #expect(d.otherTeams == ["Social Media → Bee Social"])
    #expect(d.artworks.map(\.number) == [1, 2, 3, 4])
    #expect(d.artworks[0].size == "4:5")
    #expect(d.artworks[0].warning?.contains("1080×1350") == true)
    #expect(d.artworks[1].size == "1920×1005")
    #expect(d.artworks[2].files == ["แนวนอน", "แนวตั้ง"])
    #expect(d.artworks[2].warning?.contains("LCD") == true)
    #expect(d.artworks[3].files == ["ไฟล์พิมพ์", "ไฟล์ดิจิทัล"])
    #expect(d.deadlines.map(\.label) == ["ดราฟต์แรก", "ไฟนอล"])
    #expect(d.deadlines.map { ymd($0.date) } == ["2026-11-16", "2026-11-20"])
    #expect(d.usedOn.map { ymd($0.date) } == ["2026-11-25"])
    #expect(d.picture?.hasPrefix("Stock photo") == true)
    #expect(d.waitingFor.count == 1)
    #expect(d.copyBlocks.first?.title == "Short Text")
    #expect(d.copyBlocks.first?.text.contains("THB 1,900") == true)
    #expect(d.links.first?.title == "Brief Form.doc")
}

@Test func parsesReply() {
    let d = BriefParser(ownerEmails: [me]).parse(MIMEMessage(data: Data(syntheticReply.utf8)))
    #expect(d.source == .reply)
    #expect(d.threadKey == "MARCOM BRIEF: Year-End Soiree")
    #expect(d.inReplyTo == "<abc123@company.example>")
    #expect(d.replyText?.contains("price bigger") == true)
    #expect(d.replyText?.contains("Draft attached") == false)
    #expect(d.waitingFor.count == 1)
}

@Test func yearRollsOverForJanuary() {
    let p = BriefParser(ownerEmails: [])
    let sent = cal().date(from: DateComponents(year: 2026, month: 12, day: 20))!
    #expect(p.dates(in: "Deadline: 5 January", sent: sent).map(ymd) == ["2027-01-05"])
    #expect(p.dates(in: "Deadline: 28 December", sent: sent).map(ymd) == ["2026-12-28"])
}

@Test func plainEmailFallsBackToManual() {
    let raw = """
    From: Studio <studio@company.example>
    Subject: Video for new product
    Date: Mon, 16 Nov 2026 02:00:00 +0000
    Content-Type: text/html; charset=utf-8

    <p>Hi, please cut a 30s reel for the new product by <b>25 November</b>.</p>
    """
    let d = BriefParser(ownerEmails: [me]).parse(MIMEMessage(data: Data(raw.utf8)))
    #expect(d.source == .plainEmail)
    #expect(d.title == "Video for new product")
    #expect(d.bodyText.contains("30s reel"))
    #expect(d.notes.contains { $0.contains("กรอก") })
}

