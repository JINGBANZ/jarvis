import AppKit

/// Persists the Vocabulary field on focus loss (or Enter), not on every keystroke, so a partial
/// term mid-edit never reaches `TranscriptionPreferences`.
extension TranscriptionControls: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === vocabularyField else { return }
        vocabularyChanged(field.stringValue)
    }
}
