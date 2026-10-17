import Foundation

@main
enum ReferenceHelperMain {
    static func main() async {
        umask(0o077)
        do {
            if CommandLine.arguments.dropFirst().first == "--worker" {
                exit(ReferenceConversionWorker.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
            }
            #if JARVIS_LIVE_E2E
            if CommandLine.arguments.dropFirst().first == "--test-conversion" {
                exit(await ReferenceConversionEvaluation.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
            }
            #endif
            guard CommandLine.arguments.count >= 2 else { exit(64) }
            let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            #if JARVIS_LIVE_E2E
            if CommandLine.arguments.dropFirst(2).contains("--test-fault") {
                try ReferenceHelperFault.run(home: home)
                exit(0)
            }
            #endif
            guard CommandLine.arguments.count == 2 else { exit(64) }
            let store = try ReferenceDocumentStore(home: home)
            let server = ReferenceHelperServer(store: store)
            try await server.run()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("reference helper: protocol or store failure\n".utf8))
            exit(2)
        }
    }
}
