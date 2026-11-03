import AppKit

struct TestDisplayDescriptor: Decodable {
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    let name: String
    let maxPixelsWide: UInt32
    let maxPixelsHigh: UInt32
    let millimetersWide: Double
    let millimetersHigh: Double
    let width: UInt32
    let height: UInt32
    let refreshRate: Double
    let hiDPI: UInt32
}

@MainActor
final class TestDisplay {
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    // Adapted from DeskPad; see DeskPad/README.md and LICENSE.md.
    init(_ value: TestDisplayDescriptor) throws {
        guard ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy({ NSClassFromString($0) != nil }) else {
            throw Failure("Virtual-display API unavailable")
        }
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = value.name
        descriptor.maxPixelsWide = value.maxPixelsWide
        descriptor.maxPixelsHigh = value.maxPixelsHigh
        descriptor.sizeInMillimeters = CGSize(width: value.millimetersWide, height: value.millimetersHigh)
        descriptor.vendorID = value.vendor
        descriptor.productID = value.product
        descriptor.serialNum = value.serial
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw Failure("Fixed display creation failed; no alternate identity")
        }
        self.display = display
    }

    func configure(_ value: TestDisplayDescriptor) throws {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = value.hiDPI
        settings.modes = [CGVirtualDisplayMode(width: UInt(value.width), height: UInt(value.height), refreshRate: value.refreshRate)]
        guard display.apply(settings) else { throw Failure("Fixed display configuration failed") }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
