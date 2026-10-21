import AppKit

@MainActor
final class TestDisplay {
    private var display: CGVirtualDisplay?
    private var identity: TestDisplayIdentity?

    var id: CGDirectDisplayID { display?.displayID ?? 0 }

    // Adapted from DeskPad's ScreenViewController; see DeskPad/README.md and LICENSE.md.
    init() throws {
        guard ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy({ NSClassFromString($0) != nil }) else {
            throw Failure("This macOS version does not provide the virtual-display API.")
        }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "Jarvis Tests"
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.vendorID = TestDisplayIdentity.vendor
        descriptor.productID = TestDisplayIdentity.product
        var excluded = try TestDisplayIdentity.onlineSerials()
        while display == nil {
            let identity = try TestDisplayIdentity.reserve(excluding: excluded)
            descriptor.serialNum = identity.serial
            excluded.insert(identity.serial)
            if let display = CGVirtualDisplay(descriptor: descriptor) {
                self.identity = identity
                self.display = display
            }
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
        guard display?.apply(settings) == true else {
            throw Failure("macOS could not configure the test display.")
        }
    }

    func close() {
        display = nil
        identity = nil
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
