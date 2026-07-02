import XCTest
@testable import SessionsHUD

final class SessionStoreTests: XCTestCase {
    // MARK: - Fixtures

    /// Builds a spool-envelope JSON string the way post-event.sh does and
    /// decodes it through the real HookEvent path, so tests cover decoding
    /// and reduction together.
    private func event(
        _ name: String,
        sid: String = "s1",
        ts: Int64 = 1_700_000_000_000_000,
        pid: Int32 = 4242,
        tty: String = "/dev/ttys003",
        termProgram: String = "Apple_Terminal",
        payloadExtra: String = ""
    ) throws -> HookEvent {
        let payload = "{\"session_id\":\"\(sid)\",\"cwd\":\"/Users/dev/myrepo\"\(payloadExtra)}"
        let json = """
        {"v":1,"event":"\(name)","ts":\(ts),"pid":\(pid),"tty":"\(tty)","term_program":"\(termProgram)","payload":\(payload)}
        """
        return try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    private func statuslineEvent(
        sid: String = "s1",
        ctx: Float = 42.5,
        ts: Int64 = 1_700_000_001_000_000
    ) throws -> HookEvent {
        let json = """
        {"v":1,"event":"Statusline","ts":\(ts),"pid":0,"tty":"","term_program":"","payload":{"session_id":"\(sid)","model":{"display_name":"Fable"},"context_window":{"used_percentage":\(ctx)},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20}},"workspace":{"current_dir":"/Users/dev/myrepo"}}}
        """
        return try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    // MARK: - Lifecycle

    func testSessionStartCreatesRunningSessionWithContext() throws {
        let store = SessionStore()
        XCTAssertTrue(store.apply(try event("SessionStart")))
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.status, .running)
        XCTAssertEqual(s.name, "myrepo")
        XCTAssertEqual(s.pid, 4242)
        XCTAssertEqual(s.tty, "/dev/ttys003")
        XCTAssertEqual(s.termProgram, "Apple_Terminal")
    }

    func testStopMarksDoneAndClearsActivity() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try event("PreToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        store.apply(try event("Stop"))
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.status, .done)
        XCTAssertNil(s.currentActivity)
        XCTAssertNil(s.pendingPrompt)
    }

    func testSessionEndRemoves() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try event("SessionEnd"))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testEventWithoutSessionIdIsIgnored() throws {
        let store = SessionStore()
        let json = """
        {"v":1,"event":"SessionStart","ts":1,"pid":1,"tty":"","term_program":"","payload":{}}
        """
        let ev = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        XCTAssertFalse(store.apply(ev))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - Prompts

    func testPermissionPromptNeedsApproval() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try event(
            "Notification",
            payloadExtra: ",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\""
        ))
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.status, .needsApproval)
        XCTAssertTrue(s.needsAttention)
        XCTAssertEqual(s.pendingPrompt, .permission(message: "Claude needs your permission to use Bash"))
    }

    func testPlanApprovalDetectedFromMessage() throws {
        let store = SessionStore()
        store.apply(try event(
            "Notification",
            payloadExtra: ",\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs approval for the plan\""
        ))
        XCTAssertEqual(
            store.sessions["s1"]?.pendingPrompt,
            .planApproval(message: "Claude needs approval for the plan")
        )
    }

    func testIdlePromptSetsIdleWithoutPrompt() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try event(
            "Notification",
            payloadExtra: ",\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\""
        ))
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.status, .idle)
        XCTAssertNil(s.pendingPrompt)
        XCTAssertFalse(s.needsAttention)
    }

    func testNotificationWithoutTypeOrMessageDoesNotFlipAttention() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try event("Notification")) // no notification_type, no message
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertNil(s.pendingPrompt)
        XCTAssertFalse(s.needsAttention)
        XCTAssertEqual(s.status, .running)
    }

    func testUnknownEventDoesNotCreatePhantomSession() throws {
        let store = SessionStore()
        XCTAssertFalse(store.apply(try event("SomeFutureEvent")))
        XCTAssertTrue(store.sessions.isEmpty)

        // …but on an existing session it still refreshes host context.
        store.apply(try event("SessionStart", tty: "/dev/ttys001"))
        store.apply(try event("SomeFutureEvent", ts: 1_700_000_005_000_000, tty: "/dev/ttys002"))
        XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys002")
    }

    func testToolUseClearsPrompt() throws {
        let store = SessionStore()
        store.apply(try event(
            "Notification",
            payloadExtra: ",\"notification_type\":\"permission_prompt\",\"message\":\"needs Bash\""
        ))
        store.apply(try event("PreToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.status, .running)
        XCTAssertNil(s.pendingPrompt)
    }

    // MARK: - Activity chips

    func testActivityLifecycle() throws {
        let store = SessionStore()
        store.apply(try event("PreToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        guard case .tool(let name, _)? = store.sessions["s1"]?.currentActivity else {
            return XCTFail("expected tool activity")
        }
        XCTAssertEqual(name, "Bash")

        // A Post for a different tool must not clear the newer chip.
        store.apply(try event("PostToolUse", payloadExtra: ",\"tool_name\":\"Read\""))
        XCTAssertNotNil(store.sessions["s1"]?.currentActivity)

        store.apply(try event("PostToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        XCTAssertNil(store.sessions["s1"]?.currentActivity)
    }

    func testPostToolUseWithoutToolNameClearsAnyToolChip() throws {
        let store = SessionStore()
        store.apply(try event("PreToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        store.apply(try event("PostToolUse")) // producer omitted tool_name
        XCTAssertNil(store.sessions["s1"]?.currentActivity)
    }

    func testPostToolUseAsFirstEventBootstrapsRunningRow() throws {
        // HUD launched mid-session: the first event we ever see can be a Post.
        let store = SessionStore()
        store.apply(try event("PostToolUse", payloadExtra: ",\"tool_name\":\"Bash\""))
        XCTAssertEqual(store.sessions["s1"]?.status, .running)
    }

    func testSubagentAndCompactActivity() throws {
        let store = SessionStore()
        store.apply(try event("SubagentStart", payloadExtra: ",\"subagent_type\":\"Explore\""))
        guard case .subagent(let name, _)? = store.sessions["s1"]?.currentActivity else {
            return XCTFail("expected subagent activity")
        }
        XCTAssertEqual(name, "Explore")
        store.apply(try event("SubagentStop"))
        XCTAssertNil(store.sessions["s1"]?.currentActivity)

        store.apply(try event("PreCompact"))
        guard case .compacting? = store.sessions["s1"]?.currentActivity else {
            return XCTFail("expected compacting activity")
        }
        store.apply(try event("PostCompact"))
        XCTAssertNil(store.sessions["s1"]?.currentActivity)
    }

    // MARK: - Statusline

    func testStatuslineMergesStatsWithoutTouchingActivityClock() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart", ts: 1_700_000_000_000_000))
        let before = try XCTUnwrap(store.sessions["s1"]).lastEventAt

        store.apply(try statuslineEvent())
        let s = try XCTUnwrap(store.sessions["s1"])
        XCTAssertEqual(s.stats?.modelDisplay, "Fable")
        XCTAssertEqual(s.stats?.ctxPct, 42.5)
        XCTAssertEqual(s.stats?.fiveHrPct, 10)
        XCTAssertEqual(s.stats?.sevenDayPct, 20)
        // Statusline redraws must not make a quiet session look active.
        XCTAssertEqual(s.lastEventAt, before)
        // …and must not wipe host context with its empty pid/tty.
        XCTAssertEqual(s.pid, 4242)
        XCTAssertEqual(s.tty, "/dev/ttys003")
    }

    func testStatuslineAloneCreatesSessionWithCwdFromWorkspace() throws {
        let store = SessionStore()
        store.apply(try statuslineEvent(sid: "solo"))
        let s = try XCTUnwrap(store.sessions["solo"])
        XCTAssertEqual(s.cwd, "/Users/dev/myrepo")
        XCTAssertEqual(s.name, "myrepo")
    }

    func testStatuslineKeepsPidlessSessionAliveThroughSweep() throws {
        // Statusline updates freeze lastEventAt by design, but must still
        // count as proof of life for pid-less sessions: sweep long after
        // lastEventAt, shortly after the latest quota refresh.
        let store = SessionStore()
        store.apply(try statuslineEvent(sid: "solo", ts: 1_700_000_001_000_000))
        let muchLater: Int64 = 1_700_000_001_000_000
            + Int64(SessionStore.unknownPidCutoff) * 1_000_000 * 3
        store.apply(try statuslineEvent(sid: "solo", ts: muchLater))

        let sweepAt = Date(timeIntervalSince1970: Double(muchLater) / 1_000_000 + 60)
        XCTAssertFalse(store.sweep(now: sweepAt, isAlive: { _ in true }))
        XCTAssertNotNil(store.sessions["solo"])
    }

    func testNameFallsBackToSessionIdPrefixWithoutCwd() throws {
        let store = SessionStore()
        let json = """
        {"v":1,"event":"SessionStart","ts":1,"pid":1,"tty":"","term_program":"","payload":{"session_id":"abcdef1234"}}
        """
        store.apply(try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)))
        XCTAssertEqual(store.sessions["abcdef1234"]?.name, "abcdef12")

        // Name upgrades once a cwd arrives.
        store.apply(try event("UserPromptSubmit", sid: "abcdef1234", ts: 2))
        XCTAssertEqual(store.sessions["abcdef1234"]?.name, "myrepo")
    }

    // MARK: - Resume / context updates

    func testTtyFollowsLatestEvent() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart", tty: "/dev/ttys001"))
        store.apply(try event("UserPromptSubmit", ts: 1_700_000_002_000_000, tty: "/dev/ttys009"))
        XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys009")
    }

    // MARK: - Sweep

    func testSweepDecaysDoneToIdle() throws {
        let store = SessionStore()
        store.apply(try event("Stop"))
        let later = Date(timeIntervalSince1970: 1_700_000_000 + SessionStore.doneDecay + 1)
        XCTAssertTrue(store.sweep(now: later, isAlive: { _ in true }))
        XCTAssertEqual(store.sessions["s1"]?.status, .idle)
    }

    func testSweepRemovesDeadPid() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        XCTAssertTrue(store.sweep(now: Date(), isAlive: { _ in false }))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSweepKeepsLiveSessionAndReportsNoChange() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart", ts: Int64(Date().timeIntervalSince1970 * 1_000_000)))
        XCTAssertFalse(store.sweep(now: Date(), isAlive: { _ in true }))
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testSweepExpiresPidlessSessionAfterCutoff() throws {
        let store = SessionStore()
        store.apply(try statuslineEvent(sid: "solo"))
        let later = store.sessions["solo"]!.lastEventAt
            .addingTimeInterval(SessionStore.unknownPidCutoff + 1)
        XCTAssertTrue(store.sweep(now: later, isAlive: { _ in true }))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    // MARK: - Snapshot

    func testSnapshotRoundTrip() throws {
        let store = SessionStore()
        store.apply(try event("SessionStart"))
        store.apply(try statuslineEvent())
        let data = try store.snapshotData()

        let restored = SessionStore()
        restored.loadSnapshot(data)
        XCTAssertEqual(restored.sessions["s1"], store.sessions["s1"])
    }

    func testCorruptSnapshotIsIgnored() {
        let store = SessionStore()
        store.loadSnapshot(Data("not json".utf8))
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
