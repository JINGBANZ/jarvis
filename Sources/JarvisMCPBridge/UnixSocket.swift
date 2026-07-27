import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum UnixSocket {
    static let maximumMessageBytes = 64 * 1_024 * 1_024

    static func makeListener(path: String) throws -> Int32 {
        guard path.utf8CString.count <= MemoryLayout<sockaddr_un>.size
                - MemoryLayout<sa_family_t>.size else {
            throw error("private MCP socket path is too long")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("create private MCP socket") }
        do {
            try withAddress(path: path) { address, length in
                guard bind(descriptor, address, length) == 0 else {
                    throw posixError("bind private MCP socket")
                }
            }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw posixError("protect private MCP socket")
            }
            guard listen(descriptor, 4) == 0 else {
                throw posixError("listen on private MCP socket")
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
    }

    static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("create MCP bridge connection") }
        do {
            try withAddress(path: path) { address, length in
                guard Darwin.connect(descriptor, address, length) == 0 else {
                    throw posixError("connect to Jarvis action broker")
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func readMessage(from descriptor: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumMessageBytes {
            let count = withUnsafeMutablePointer(to: &byte) {
                read(descriptor, $0, 1)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw posixError("read private MCP message")
            }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        guard data.count < maximumMessageBytes else {
            throw error("private MCP message exceeded the size limit")
        }
        return data
    }

    static func writeMessage(_ data: Data, to descriptor: Int32) throws {
        var framed = data
        framed.append(0x0A)
        try framed.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                // A cancelled CLI can close its side of the bridge while the host is replying.
                // Convert that ordinary lifecycle race into EPIPE instead of terminating Jarvis.
                let count = send(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset,
                    Int32(MSG_NOSIGNAL))
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw posixError("write private MCP message")
                }
                offset += count
            }
        }
    }

    static func closeConnection(_ descriptor: Int32) {
        shutdownConnection(descriptor)
        close(descriptor)
    }

    static func shutdownConnection(_ descriptor: Int32) {
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    private static func withAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                _ = pathBytes.withUnsafeBufferPointer { source in
                    memcpy(destination, source.baseAddress, pathBytes.count)
                }
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }

    private static func error(_ description: String) -> NSError {
        NSError(
            domain: "JarvisMCPBridge",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
