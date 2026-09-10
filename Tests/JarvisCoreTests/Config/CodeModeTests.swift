import Foundation
import Testing
@testable import JarvisCore

@Suite struct CodeModeTests {
    @Test func savedCodePreferenceOnlyEnablesCodingSessions() {
        let name = "CodeModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = CodePreferences(defaults: defaults)
        preference.isEnabled = true
        #expect(preference.isEnabled(for: .coding, boxEnabled: true))
        for format: InterviewFormat? in [nil, .systemDesign, .behavioral, .generalTechnical] {
            #expect(!preference.isEnabled(for: format, boxEnabled: true))
        }
        #expect(!preference.isEnabled(for: .coding, boxEnabled: false))
        #expect(preference.isEnabled, "Changing modes must not erase the user's code preference")
        preference.isEnabled = false
        #expect(!preference.isEnabled(for: .coding, boxEnabled: true))
    }
}
