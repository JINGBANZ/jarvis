import Foundation
import Testing
@testable import JarvisCore

struct ReferenceSourceChangeTests {
    @Test func selectedFileIgnoresSiblingsAndIncludesAtomicReplacementPath() {
        let source = PrepMaterialSource(path: "/workspace/README.md", isDirectory: false)
        for path in ["/workspace/other.md", "/workspace/.jarvis/references/documents.sqlite", "/workspace/.build/output.txt"] {
            #expect(!ReferenceSourceChange.affects(path, directory: false, structural: false, sources: [source], excluding: []))
        }
        #expect(ReferenceSourceChange.affects(source.path, directory: false, structural: true, sources: [source], excluding: []))
    }
    @Test func directoriesIncludeNestedSupportedChangesAndExcludeOwnedCache() {
        let source = PrepMaterialSource(path: "/workspace", isDirectory: true)
        let excluded = ["/workspace/.jarvis/references"]
        #expect(ReferenceSourceChange.affects("/workspace/new/nested/design.docx", directory: false, structural: false, sources: [source], excluding: excluded))
        #expect(ReferenceSourceChange.affects("/workspace/old", directory: true, structural: true, sources: [source], excluding: excluded))
        #expect(!ReferenceSourceChange.affects("/workspace/unrelated.bin", directory: false, structural: false, sources: [source], excluding: excluded))
        #expect(!ReferenceSourceChange.affects("/workspace/.jarvis/references/staging/a.txt", directory: false, structural: true, sources: [source], excluding: excluded))
        #expect(!ReferenceSourceChange.affects("/workspace-other/design.md", directory: false, structural: true, sources: [source], excluding: excluded))
    }
}
