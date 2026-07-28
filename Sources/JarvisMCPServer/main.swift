import Foundation
import JarvisMCPServerCore

do {
    try await JarvisMCPServer.run()
} catch {
    FileHandle.standardError.write(Data("Jarvis MCP server failed\n".utf8))
    exit(1)
}
