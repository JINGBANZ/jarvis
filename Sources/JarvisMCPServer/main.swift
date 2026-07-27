import Foundation
import JarvisMCPBridge

do {
    try MCPStdioServer.run()
} catch {
    FileHandle.standardError.write(Data("Jarvis MCP server failed\n".utf8))
    exit(1)
}
