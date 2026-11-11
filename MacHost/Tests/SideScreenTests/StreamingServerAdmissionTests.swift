import XCTest
import Network
@testable import SideScreen

/// Issue #69: a new TCP connection used to evict the streaming client before
/// anything was known about it. Real loopback connections against a real
/// server: the newcomer must be admitted before it takes the slot.
final class StreamingServerAdmissionTests: XCTestCase {
    private let clientQueue = DispatchQueue(label: "StreamingServerAdmissionTests.client")

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var connected = 0
        private var disconnected = 0
        var connects: Int { lock.lock(); defer { lock.unlock() }; return connected }
        var disconnects: Int { lock.lock(); defer { lock.unlock() }; return disconnected }
        func didConnect() { lock.lock(); connected += 1; lock.unlock() }
        func didDisconnect() { lock.lock(); disconnected += 1; lock.unlock() }
    }

    private func connect(to port: UInt16) -> NWConnection {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.start(queue: clientQueue)
        return conn
    }

    /// Payload-free type 8 (frame-metadata opt-in): what every current client
    /// sends last in its capability adverts.
    private func advertise(on conn: NWConnection) {
        conn.send(content: Data([8]), completion: .contentProcessed { _ in })
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// A server with one live, streaming-ready loopback client.
    private func liveServer() async throws -> (server: StreamingServer, port: UInt16, counter: Counter, client: NWConnection) {
        let server = StreamingServer(port: 0)
        let counter = Counter()
        server.onClientConnected = { counter.didConnect() }
        server.onClientDisconnected = { counter.didDisconnect() }
        try await server.start()
        let port = try XCTUnwrap(server.boundPort)
        let client = connect(to: port)
        advertise(on: client)
        let ready = await waitUntil(3) { counter.connects == 1 }
        XCTAssertTrue(ready, "first client never became ready")
        return (server, port, counter, client)
    }

    func testSilentProbeThatClosesDoesNotDropTheStreamingClient() async throws {
        let (server, port, counter, client) = try await liveServer()
        defer { server.stop(); client.cancel() }

        // The tablet's USB checklist probe: connect, say nothing, close.
        let probe = connect(to: port)
        try await Task.sleep(nanoseconds: 300_000_000)
        probe.cancel()

        try await Task.sleep(nanoseconds: UInt64((StreamingServer.loopbackSilenceGrace + 0.5) * 1_000_000_000))
        XCTAssertEqual(counter.disconnects, 0, "the streaming client was dropped by a probe")
        XCTAssertEqual(counter.connects, 1)
    }

    func testNewcomerThatSpeaksReplacesTheStreamingClient() async throws {
        let (server, port, counter, client) = try await liveServer()
        defer { server.stop(); client.cancel() }

        // Auto-reconnect after a half-dead link: the new client advertises at once.
        let replacement = connect(to: port)
        defer { replacement.cancel() }
        advertise(on: replacement)

        let replaced = await waitUntil(3) { counter.connects == 2 && counter.disconnects >= 1 }
        XCTAssertTrue(replaced, "a speaking newcomer must take the slot (connects=\(counter.connects), disconnects=\(counter.disconnects))")
    }

    func testSilentNewcomerThatStaysOpenIsTakenAsALegacyClient() async throws {
        let (server, port, counter, client) = try await liveServer()
        defer { server.stop(); client.cancel() }

        // Legacy clients send no capability adverts at all.
        let legacy = connect(to: port)
        defer { legacy.cancel() }

        try await Task.sleep(nanoseconds: UInt64((StreamingServer.loopbackSilenceGrace - 0.7) * 1_000_000_000))
        XCTAssertEqual(counter.disconnects, 0, "replaced before the silence grace ran out")

        let replaced = await waitUntil(StreamingServer.loopbackSilenceGrace + 2) { counter.connects == 2 }
        XCTAssertTrue(replaced, "a silent but open loopback newcomer must get the slot after the grace")
    }
}
