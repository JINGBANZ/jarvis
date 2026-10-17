import Foundation

public enum ReferenceOmissionReason: String, Equatable, Sendable {
    case disabled, empty, timeout, failed

    public var warning: String? {
        switch self {
        case .disabled, .empty: nil
        case .timeout: "References were not ready before this session started."
        case .failed: "References could not be prepared for this session."
        }
    }
}
