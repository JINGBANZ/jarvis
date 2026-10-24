import JarvisProcess
#if DEBUG
import JarvisTestSupport
#endif

enum AppProcessComposition {
    static func makeLauncher() -> any ProcessLaunching {
        #if DEBUG
        TestCommandOwnership.makeLauncher()
        #else
        NativeProcessLauncher()
        #endif
    }

    static func registerApplication() throws {
        #if DEBUG
        try TestCommandOwnership.registerApplication()
        #endif
    }
}
