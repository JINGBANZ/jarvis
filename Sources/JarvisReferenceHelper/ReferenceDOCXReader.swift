import Foundation
import ZIPFoundation

enum ReferenceDOCXReader {
    static func read(url: URL, output: ReferenceTextOutput) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        var declaredBytes: UInt64 = 0
        for entry in archive {
            guard entries.count < 10_000, entry.path.utf8.count <= 1_024, entries[entry.path] == nil else {
                throw ReferenceConversionError.limitExceeded
            }
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !entry.path.split(separator: "/").contains(".."), entry.type != .symlink else {
                throw ReferenceConversionError.invalidDocument
            }
            guard entry.uncompressedSize <= UInt64(ReferenceTextOutput.maximumBytes) - declaredBytes else {
                throw ReferenceConversionError.limitExceeded
            }
            declaredBytes += entry.uncompressedSize
            entries[entry.path] = entry
        }
        guard let relationship = entries["_rels/.rels"], relationship.type == .file else {
            throw ReferenceConversionError.invalidDocument
        }
        var relationships = Data()
        try extractXML(relationship, archive: archive, maximumBytes: 1_048_576) { relationships.append($0) }
        let mainPath = try ReferencePackageRelationships.mainDocument(in: relationships)
        guard let main = entries[mainPath], main.type == .file else { throw ReferenceConversionError.invalidDocument }
        let xml = output.directory.appendingPathComponent(UUID().uuidString + ".xml")
        let descriptor = open(xml.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw errno == ENOSPC ? ReferenceConversionError.diskFull : .unavailable }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: xml) }
        try extractXML(main, archive: archive, maximumBytes: ReferenceTextOutput.maximumBytes - relationships.count) {
            try file.write(contentsOf: $0)
        }
        try file.close()
        try ReferenceWordXMLReader(output: output).read(url: xml)
    }

    private static func extractXML(_ entry: Entry, archive: Archive, maximumBytes: Int, consume: (Data) throws -> Void) throws {
        var count = 0
        var tail = Data()
        let checksum = try archive.extract(entry, bufferSize: 32_768) { piece in
            guard piece.count <= maximumBytes - count else { throw ReferenceConversionError.limitExceeded }
            count += piece.count
            var scan = tail
            scan.append(piece)
            guard !scan.contains(0), scan.range(of: Data("<!DOCTYPE".utf8)) == nil,
                  scan.range(of: Data("<!ENTITY".utf8)) == nil else { throw ReferenceConversionError.invalidDocument }
            tail = scan.suffix(16)
            try consume(piece)
        }
        guard checksum == entry.checksum, count == entry.uncompressedSize else { throw ReferenceConversionError.invalidDocument }
    }
}
