import CJarvisAEC
import Testing

struct HostedAECTests {
    @Test(arguments: [8_000, 16_000, 32_000, 48_000])
    func hostedLibraryProcessesNativeFrames(sampleRate: Int32) throws {
        let aec = try #require(jarvis_aec_create(sampleRate))
        defer { jarvis_aec_destroy(aec) }
        let count = Int(sampleRate / 100)
        var reference = [Int16](repeating: 0, count: count)
        var microphone = reference
        for _ in 0..<20 {
            #expect(jarvis_aec_process_reverse(aec, &reference, Int32(count)) == 0)
            #expect(jarvis_aec_process(aec, &microphone, Int32(count)) == 0)
            #expect(microphone.allSatisfy { $0 == 0 })
        }
        #expect(jarvis_aec_process_reverse(aec, &reference, Int32(count - 1)) != 0)
        #expect(jarvis_aec_process(aec, &microphone, Int32(count - 1)) != 0)
    }
}
