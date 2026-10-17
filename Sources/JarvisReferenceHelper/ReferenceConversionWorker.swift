import Foundation
import PDFKit

enum ReferenceConversionWorker {
    static let processorVersion: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "native-text-1/pdfkit-page-1/docx-xml-1/zipfoundation-0.9.20/macos-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }()

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 3 else { return 64 }
        let parent = getppid()
        guard parent > 1 else { return ReferenceConversionError.unavailable.exitStatus }
        let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        parentWatch.schedule(deadline: .now(), repeating: .milliseconds(100))
        parentWatch.setEventHandler { if getppid() != parent { exit(ReferenceConversionError.unavailable.exitStatus) } }
        parentWatch.resume()
        defer { parentWatch.cancel() }
        do {
            let input = URL(fileURLWithPath: arguments[0])
            let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber,
                  bytes.intValue <= ReferenceSourceCapture.maximumSourceBytes else { throw ReferenceConversionError.limitExceeded }
            let output = try ReferenceTextOutput(url: URL(fileURLWithPath: arguments[2]))
            #if JARVIS_LIVE_E2E
            if arguments[1] == "__test_memory" {
                var allocations: [Data] = []
                for _ in 0..<48 {
                    allocations.append(Data(repeating: 0xA5, count: 16 * 1_024 * 1_024))
                    Thread.sleep(forTimeInterval: 0.02)
                }
                withExtendedLifetime(allocations) { Thread.sleep(forTimeInterval: 60) }
            }
            if arguments[1] == "__test_hang" { Thread.sleep(forTimeInterval: 60) }
            #endif
            switch arguments[1] {
            case "pdf":
                guard let document = PDFDocument(url: input), !document.isLocked else { throw ReferenceConversionError.unsupportedFormat }
                guard document.pageCount <= 10_000 else { throw ReferenceConversionError.limitExceeded }
                for index in 0..<document.pageCount {
                    try autoreleasepool {
                        guard let page = document.page(at: index) else { throw ReferenceConversionError.invalidDocument }
                        if let text = page.string, !text.isEmpty { try output.append(text); try output.append("\n") }
                    }
                }
                guard output.bytes > 0 else { throw ReferenceConversionError.unsupportedFormat }
            case "docx": try ReferenceDOCXReader.read(url: input, output: output)
            default: throw ReferenceConversionError.unsupportedFormat
            }
            try output.finish()
            return 0
        } catch let error as ReferenceConversionError { return error.exitStatus }
        catch { return ReferenceConversionError.classify(error, fallback: .invalidDocument).exitStatus }
    }
}
