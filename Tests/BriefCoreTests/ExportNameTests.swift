import Testing
@testable import BriefCore

@Test func shortJobName() {
    #expect(ExportName.shortJob("Summer Glow Package at Lotus Studé") == "SummerGlowLotusStude")
    #expect(ExportName.shortJob("Neighborhood Recycling Awareness 2026 (1 December)") == "NeighborhoodRecycling")
    #expect(ExportName.shortJob("คลิปเมนูใหม่") == "คลิปเมนูใหม่")
}

@Test func exportNames() {
    #expect(ExportName.make(job: "Summer Glow Package at Lotus Studé", number: 3, size: "1920×1005", variant: "ไฟล์")
            == "SummerGlowLotusStude_A3_1920x1005")
    #expect(ExportName.make(job: "Year End", number: 6, size: nil, variant: "แนวตั้ง") == "YearEnd_A6_V")
    #expect(ExportName.make(job: "Year End", number: 4, size: "1080×1920", variant: "แบบ 2") == "YearEnd_A4_1080x1920_v2")
    #expect(ExportName.make(job: "Year End", number: 7, size: "A4", variant: "ไฟล์พิมพ์") == "YearEnd_A7_A4_Print")
    #expect(ExportName.make(job: "Year End", number: 1, size: "4:5", variant: "ไฟล์") == "YearEnd_A1_4x5")
}
