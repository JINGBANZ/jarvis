import Foundation
import JarvisCore

// eval-prep: the thin dev-side CLI half of the agentic session audit (`AgenticEvaluation`).
//
//   eval-prep <session-dir>          renders the session's recorded brain traffic to an owner-only
//                                    `eval-transcript.txt` inside <session-dir> and prints the agent
//                                    task prompt to stdout
//   eval-prep --html <session-dir>   renders the saved `eval-report.md` to a browsable
//                                    `eval-report.html` beside it and prints the page's path
//
// `scripts/eval-session.sh` pipes the prompt into an agentic CLI (`claude -p` / `codex exec`) whose
// workspace is this repo + the session directory, then renders the page from what the agent wrote.
// Foundation-only, so it builds and runs on any machine (no macOS UI frameworks).

let args = CommandLine.arguments
do {
    switch (args.count, args.count > 1 ? args[1] : "") {
    case (2, _):
        let sessionDir = URL(fileURLWithPath: args[1], isDirectory: true)
        print(try AgenticEvaluation.prepare(sessionDir: sessionDir))
    case (3, "--html"):
        let sessionDir = URL(fileURLWithPath: args[2], isDirectory: true)
        guard let markdown = SessionEvaluator.savedReport(in: sessionDir) else {
            FileHandle.standardError.write(Data("eval-prep: no eval-report.md in \(args[2])\n".utf8))
            exit(1)
        }
        let page = try EvalReportPage.write(
            markdown: markdown, in: sessionDir,
            title: "Session evaluation — \(sessionDir.lastPathComponent)")
        print(page.path)
    default:
        FileHandle.standardError.write(
            Data("usage: EvalPrep <session-dir> | EvalPrep --html <session-dir>\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("eval-prep: \(error.localizedDescription)\n".utf8))
    exit(1)
}
