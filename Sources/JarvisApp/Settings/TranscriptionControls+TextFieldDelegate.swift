import AppKit

/// Saves when editing ends, not per keystroke, so a half-typed term never reaches preferences.
extension TranscriptionControls: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === vocabularyField {
            vocabularyChanged(field.stringValue)
        } else if field === geminiVocabularyField {
            geminiVocabularyChanged(field.stringValue)
        }
    }
}
