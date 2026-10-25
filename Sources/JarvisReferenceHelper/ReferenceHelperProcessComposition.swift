import JarvisProcess
#if DEBUG
import JarvisTestSupport
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
