import XCTest
@testable import PicPicker

final class PicPickerTests: XCTestCase {
    func testNaturalCompareOrdersCameraNames() {
        XCTAssertTrue(naturalCompare("DSC2.jpg", "DSC10.jpg"))
        XCTAssertFalse(naturalCompare("DSC10.jpg", "DSC2.jpg"))
    }

    func testPlannedNamesAreGroupedAndStable() {
        let first = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let second = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let winner = first
        let group = PhotoGroup(id: 1, records: [second, first], winner: winner)

        let plans = FileActions.plannedNames(for: [group])
        XCTAssertEqual(plans.first { $0.0 === first }?.1, "1-DSC3345.jpg")
        XCTAssertEqual(plans.first { $0.0 === second }?.1, "1-DSC3346.jpg")
    }

    func testExistingPrefixIsReplaced() {
        let record = ImageRecord(url: URL(fileURLWithPath: "/tmp/7-DSC3345.jpg"))
        let group = PhotoGroup(id: 2, records: [record], winner: record)

        let plans = FileActions.plannedNames(for: [group])
        XCTAssertEqual(plans.first?.1, "2-DSC3345.jpg")
    }

    func testFinderGreenTagRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picpicker-tag-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try FinderTags.addGreen(to: url))
        XCTAssertTrue(FinderTags.read(from: url).contains("Green\n2"))
        try FinderTags.removeGreen(from: url)
        XCTAssertFalse(FinderTags.read(from: url).contains("Green\n2"))
    }

    func testFilenameSequenceParsing() {
        XCTAssertEqual(parseFilenameSequence("DSC3345.jpg")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("DSC3345.jpg")?.prefix, "dsc")
        XCTAssertEqual(parseFilenameSequence("1-DSC3345.JPG")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("DSC3345-2.jpg")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("IMG_2024_001.jpg")?.number, 1)
        XCTAssertNil(parseFilenameSequence("IMG_77.jpg"))
    }

    func testPhotoGroupDetectsBurstOnlyWithinSameSequence() {
        let first = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let second = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let third = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3347.jpg"))
        for (record, number) in [(first, 3345), (second, 3346), (third, 3347)] {
            record.sequenceKey = "|dsc"
            record.sequenceNumber = number
        }
        XCTAssertTrue(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)

        third.sequenceNumber = 3400
        XCTAssertFalse(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)

        third.sequenceNumber = 3347
        second.sequenceKey = "Day2|dsc"
        XCTAssertFalse(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)
    }
}
