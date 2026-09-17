import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ModelListStub: Sendable {
    private let descriptor: Int32

    /// `beforeResponding` runs on the stub's thread for every request, so it can hold an answer back.
    init(port: Int, body: String, beforeResponding: @escaping @Sendable () -> Void = {}) throws {
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
                beforeResponding()
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
