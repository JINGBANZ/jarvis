import JarvisProcess
#if DEBUG
import JarvisTestProcesses
#endif

enum ReferenceHelperProcessComposition {
    static func makeLauncher() -> any ProcessLaunching {
        #if DEBUG
        TestCommandOwnership.makeLauncher()
        #else
        NativeProcessLauncher()
        #endif
    }
}
