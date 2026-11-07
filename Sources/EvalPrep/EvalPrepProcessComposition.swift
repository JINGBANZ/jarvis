import JarvisProcess
#if DEBUG
import JarvisTestProcesses
#endif

enum EvalPrepProcessComposition {
    static func makeLauncher() -> any ProcessLaunching {
        #if DEBUG
        TestCommandOwnership.makeLauncher()
        #else
        NativeProcessLauncher()
        #endif
    }
}
