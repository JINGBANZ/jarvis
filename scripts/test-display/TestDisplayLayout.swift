import CoreGraphics

struct TestDisplayLayout {
    struct Screen: Equatable {
        let id: UInt32
        let model: UInt32
        let frame: CGRect
        let mirrored: Bool
    }

    let screens: [Screen]
    let main: UInt32

    var isHeadless: Bool {
        // WindowServer's headless placeholder uses the model fourCC 'virt'.
        // https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
        screens.allSatisfy { $0.model == 0x76697274 }
    }

    func usable(display: UInt32, width: UInt32, height: UInt32) -> Bool {
        guard let test = screens.first(where: { $0.id == display }), !test.mirrored,
              test.frame.width == CGFloat(width), test.frame.height == CGFloat(height) else { return false }
        return screens.filter { $0.id != display }.allSatisfy { !$0.frame.intersects(test.frame) }
    }

    func matches(_ other: Self) -> Bool {
        main == other.main && screens.count == other.screens.count && screens.allSatisfy { other.screens.contains($0) }
    }

    func accepts(_ created: Self, display: UInt32) -> Bool {
        guard let test = created.screens.first(where: { $0.id == display }), !test.mirrored else {
            return false
        }
        let others = created.screens.filter { $0.id != display }
        if isHeadless {
            return created.main == display && others.allSatisfy { $0.model == 0x76697274 }
        }
        return created.main == main && others.count == screens.count
            && screens.allSatisfy { others.contains($0) && !$0.frame.intersects(test.frame) }
    }
}
