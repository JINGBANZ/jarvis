import Foundation
import JarvisCore

// eval-prep: the thin dev-side CLI half of the agentic session audit (`AgenticEvaluation`).
//
//   eval-prep <session-dir>
//
// Renders the session's recorded brain traffic to an owner-only `eval-transcript.txt` inside
// <session-dir> and prints the agent task prompt to stdout. `scripts/eval-session.sh` pipes that
// prompt into an agentic CLI (`claude -p` / `codex exec`) whose workspace is this repo + the session
// directory. Foundation-only, so it builds and runs on any machine (no macOS UI frameworks).

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: EvalPrep <session-dir>\n".utf8))
    exit(2)
}

let sessionDir = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    let prompt = try AgenticEvaluation.prepare(sessionDir: sessionDir)
    print(prompt)
} catch {
    FileHandle.standardError.write(Data("eval-prep: \(error.localizedDescription)\n".utf8))
    exit(1)
}
