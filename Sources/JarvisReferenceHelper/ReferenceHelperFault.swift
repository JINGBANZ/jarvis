#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

enum ReferenceHelperFault {
    static func run(home: URL) throws {
        let fault = try String(contentsOf: home.appendingPathComponent("fault"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data(String(getpid()).utf8).write(to: home.appendingPathComponent("pid"))
        signal(SIGTERM, SIG_IGN)
        func receive() throws -> ReferenceHelperRequest {
            guard let frame = try ReferenceHelperServer.receive() else { exit(0) }
            return try ReferenceHelperRequest(frame)
        }
        func send(_ request: ReferenceHelperRequest, result: Data = Data("{}".utf8)) throws {
            try ReferenceHelperServer.send(id: request.id, result: result)
        }
        func hang() { Thread.sleep(forTimeInterval: 60) }
        let hello = try receive()
        switch fault {
        case "startup-hang": hang(); return
        case "startup-malformed": FileHandle.standardOutput.write(Data([0, 32, 0, 0])); hang(); return
        case "startup-partial": FileHandle.standardOutput.write(Data([0, 0])); hang(); return
        case "startup-exit": exit(2)
        default: try send(hello, result: ReferenceHelperServer.hello())
        }
        if fault == "blocked-stdin" { hang() }
        var request = try receive()
        if fault == "exit" { exit(2) }
        if fault == "duplicate" { try send(request); try send(request); hang(); return }
        if fault == "out-of-order" {
            let second = try receive()
            try send(second); try send(request)
            request = try receive()
        }
        if fault == "blocked-output" {
            try FileHandle.standardOutput.write(contentsOf: Data(repeating: 33, count: 2_000_000))
            hang()
        }
        if fault == "cancel" {
            while true {
                request = try receive()
                if request.operation == "cancel" { try send(request) }
                if request.operation == "shutdown" { try send(request); return }
            }
        } else if fault == "out-of-order", request.operation == "shutdown" { try send(request) }
        else { hang() }
    }
}
#endif
