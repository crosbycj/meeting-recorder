import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let words: [WordTiming]?
    let confidence: Double?
    let audioDuration: TimeInterval
    let processingTime: TimeInterval

    struct WordTiming: Sendable {
        let word: String
        let startTime: Double
        let endTime: Double
    }
}
