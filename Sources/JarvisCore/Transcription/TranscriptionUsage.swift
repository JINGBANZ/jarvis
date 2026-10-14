import Foundation

public struct TranscriptionUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let audioSeconds: Double?

    public static func openAI(from event: [String: Any]) -> Self? {
        guard let usage = event["usage"] as? [String: Any] else { return nil }
        return Self(inputTokens: usage["input_tokens"] as? Int,
            outputTokens: usage["output_tokens"] as? Int,
            totalTokens: usage["total_tokens"] as? Int,
            audioSeconds: usage["seconds"] as? Double)
    }

    public static func gemini(from event: [String: Any]) -> Self? {
        guard let usage = event["usageMetadata"] as? [String: Any] else { return nil }
        return Self(inputTokens: usage["promptTokenCount"] as? Int,
            outputTokens: usage["responseTokenCount"] as? Int,
            totalTokens: usage["totalTokenCount"] as? Int, audioSeconds: nil)
    }
}
