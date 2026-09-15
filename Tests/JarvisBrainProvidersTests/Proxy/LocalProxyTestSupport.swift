import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

/// A shell script standing in for the helper, written owner-only into `directory`.
func proxyStubExecutable(in directory: URL, named name: String = "helper", script: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.createFile(
        atPath: url.path, contents: Data("#!/bin/sh\n\(script)\n".utf8),
        attributes: [.posixPermissions: 0o700])
    else { throw CocoaError(.fileWriteUnknown) }
    return url
}

/// Polls until `condition` holds or `timeout` passes; the helper runs on its own schedule.
func eventually(
    timeout: Duration = .seconds(20), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Whether a process with this id still exists.
func processExists(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

/// A clock whose sleeps return at once, so the helper's restart backoff runs without waiting.
struct ImmediateClock: _Concurrency.Clock {
    typealias Duration = Swift.Duration

    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {}
}

/// Answers every HTTP request on 127.0.0.1 with one fixed JSON body, standing in for the helper's
/// model list. The listening descriptor is the only state, so the value is freely shareable.
struct ModelListStub: Sendable {
    private let descriptor: Int32

    init(port: Int, body: String) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        self.descriptor = descriptor
        let response = Array(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
        Thread.detachNewThread {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                var request = [UInt8](repeating: 0, count: 4_096)
                _ = read(client, &request, request.count)
                _ = response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
    }
}
