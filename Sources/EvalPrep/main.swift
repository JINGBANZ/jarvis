import Foundation
import JarvisCore
import JarvisEvaluation

// eval-prep: the thin dev-side CLI entry point for the same agentic evaluator Activity uses.
//
//   eval-prep <session-dir>          renders the session's recorded brain traffic to an owner-only
//                                    `eval-transcript.txt` inside <session-dir> and prints the agent
//                                    task prompt to stdout
//   eval-prep --html <session-dir>   renders the saved `eval-report.md` to a browsable
//                                    `eval-report.html` beside it and prints the page's path
//   eval-prep --evaluate <repo> <session-dir> [claude|codex]
//                                    runs the read-only evaluator, saves the report, renders its page,
//                                    and prints the page's path
//
// Foundation-only, so it builds and runs on any machine (no macOS UI frameworks).

let args = CommandLine.arguments
do {
    switch (args.count, args.count > 1 ? args[1] : "") {
    case (2, _):
        let sessionDir = URL(fileURLWithPath: args[1], isDirectory: true)
        print(try AgenticEvaluation.prepare(sessionDir: sessionDir))
    case (3, "--html"):
        let sessionDir = URL(fileURLWithPath: args[2], isDirectory: true)
        guard let markdown = AgenticEvaluation.savedReport(in: sessionDir) else {
            FileHandle.standardError.write(Data("eval-prep: no eval-report.md in \(args[2])\n".utf8))
            exit(1)
        }
        let page = try EvalReportPage.write(
            markdown: markdown, in: sessionDir,
            title: "Session evaluation — \(sessionDir.lastPathComponent)")
        print(page.path)
    case (4...5, "--evaluate"):
        let repository = URL(fileURLWithPath: args[2], isDirectory: true)
        let sessionDir = URL(fileURLWithPath: args[3], isDirectory: true)
        let preferredProvider: BrainProvider?
        if args.count == 5 {
            switch args[4] {
            case "claude": preferredProvider = .claudeCode
            case "codex": preferredProvider = .codexCLI
            default:
                FileHandle.standardError.write(
                    Data("eval-prep: expected evaluator 'claude' or 'codex'\n".utf8))
                exit(2)
            }
        } else {
            preferredProvider = nil
        }
        let evaluator = AgenticEvaluator(repositoryDirectory: repository,
                                         preferredProvider: preferredProvider)
        let markdown = try await evaluator.evaluate(sessionDirectory: sessionDir)
        let page = try EvalReportPage.write(
            markdown: markdown, in: sessionDir,
            title: "Session evaluation — \(sessionDir.lastPathComponent)")
        print(page.path)
    default:
        FileHandle.standardError.write(
            Data("""
                usage: EvalPrep <session-dir> | EvalPrep --html <session-dir> | \
                EvalPrep --evaluate <repo> <session-dir> [claude|codex]
                """.utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("eval-prep: \(error.localizedDescription)\n".utf8))
    exit(1)
}
