import XCTest
@testable import SessionsHUD

@MainActor
final class EventSpoolTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, event: String, sid: String, ts: Int64) throws {
        let json = """
        {"v":1,"event":"\(event)","ts":\(ts),"pid":99,"tty":"","term_program":"","payload":{"session_id":"\(sid)"}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func files() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    func testDrainDeliversChronologicallyAndDeletesEventFiles() throws {
        // Written out of order on purpose — names must decide the order.
        try write("0000000000000002-1.json", event: "Stop", sid: "s1", ts: 2)
        try write("0000000000000001-1.json", event: "SessionStart", sid: "s1", ts: 1)

        var seen: [String] = []
        let spool = EventSpool(directory: dir)
        spool.onEvents = { seen.append(contentsOf: $0.map(\.event)) }
        spool.drain()

        XCTAssertEqual(seen, ["SessionStart", "Stop"])
        XCTAssertTrue(files().isEmpty, "event files must be consumed")
    }

    func testStatuslineFilesPersistAndSkipUnchanged() throws {
        let json = """
        {"v":1,"event":"Statusline","ts":5,"pid":0,"tty":"","term_program":"","payload":{"session_id":"s1"}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("statusline-s1.json"))

        var batches = 0
        let spool = EventSpool(directory: dir)
        spool.onEvents = { _ in batches += 1 }

        spool.drain()
        XCTAssertEqual(batches, 1)
        XCTAssertTrue(files().contains("statusline-s1.json"), "statusline files are state, not events")

        // Unchanged mtime → no re-ingest, no callback.
        spool.drain()
        XCTAssertEqual(batches, 1)
    }

    func testRetainStatuslineFilesDropsDeadSessions() throws {
        for sid in ["live", "dead"] {
            let json = """
            {"v":1,"event":"Statusline","ts":5,"pid":0,"tty":"","term_program":"","payload":{"session_id":"\(sid)"}}
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("statusline-\(sid).json"))
        }
        let spool = EventSpool(directory: dir)
        spool.retainStatuslineFiles(for: ["live"])
        XCTAssertEqual(files(), ["statusline-live.json"])
    }

    func testHiddenTmpFilesAreIgnoredByDrainAndFreshOnesSurvivePrune() throws {
        try Data("half-written".utf8).write(to: dir.appendingPathComponent(".tmp.123"))

        var batches = 0
        let spool = EventSpool(directory: dir)
        spool.onEvents = { _ in batches += 1 }
        spool.drain()
        XCTAssertEqual(batches, 0)

        // A fresh tmp file belongs to an in-flight hook — prune must not
        // unlink it out from under the writer's mv.
        spool.prune()
        XCTAssertTrue(files().contains(".tmp.123"))
    }

    func testUndecodableEventFileIsDeletedAndCounted() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("0000000000000001-1.json"))
        let spool = EventSpool(directory: dir)
        spool.onEvents = { _ in XCTFail("nothing decodable to deliver") }
        spool.drain()
        XCTAssertTrue(files().isEmpty)
        XCTAssertEqual(spool.decodeFailureCount, 1)
    }

    func testUnsupportedEnvelopeVersionIsRejected() throws {
        let json = """
        {"v":2,"event":"SessionStart","ts":1,"pid":1,"tty":"","term_program":"","payload":{"session_id":"s1"}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("0000000000000001-1.json"))
        let spool = EventSpool(directory: dir)
        spool.onEvents = { _ in XCTFail("v2 must not be delivered") }
        spool.drain()
        XCTAssertTrue(files().isEmpty)
    }

    func testPruneDropsOldFilesAndKeepsRecent() throws {
        try write("0000000000000001-1.json", event: "Stop", sid: "old", ts: 1)
        let oldURL = dir.appendingPathComponent("0000000000000001-1.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-EventSpool.maxAge - 60)],
            ofItemAtPath: oldURL.path
        )
        try write("0000000000000002-1.json", event: "Stop", sid: "new", ts: 2)

        let spool = EventSpool(directory: dir)
        spool.prune()
        XCTAssertEqual(files(), ["0000000000000002-1.json"])
    }
}
