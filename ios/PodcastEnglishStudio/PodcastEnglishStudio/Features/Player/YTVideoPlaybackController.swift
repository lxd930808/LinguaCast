import Foundation
import Observation
import PodcastEnglishStudioCore

enum YTPlaybackAction: Equatable, Sendable {
    case play
    case pause
    case seek(to: TimeInterval, resumeAfterSeek: Bool)
}

struct YTPlaybackCommand: Equatable, Sendable {
    let sequence: Int
    let action: YTPlaybackAction
}

@MainActor
@Observable
final class YTVideoPlaybackController {
    private(set) var command: YTPlaybackCommand?
    private(set) var isPlaying = false
    private(set) var effectivePlaybackRate = 1.0
    private(set) var sentenceContext = SentencePlaybackContext(
        current: nil,
        previous: nil,
        next: nil,
        position: nil,
        totalCount: 0,
        repeatRange: nil
    )
    private(set) var repeatRange: ClosedRange<TimeInterval>?
    private(set) var isRepeatingSentence = false

    private var nextCommandSequence = 0

    func updateTimeline(currentTime: TimeInterval, segments: [LearningSegment]) {
        sentenceContext = SentencePlaybackPolicy.context(at: currentTime, segments: segments)
        repeatRange = isRepeatingSentence ? sentenceContext.repeatRange : nil
    }

    func report(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    func report(effectivePlaybackRate: Double) {
        guard effectivePlaybackRate.isFinite, effectivePlaybackRate > 0 else { return }
        self.effectivePlaybackRate = effectivePlaybackRate
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        isPlaying = true
        issue(.play)
    }

    func pause() {
        isPlaying = false
        issue(.pause)
    }

    func seek(to time: TimeInterval, resumeAfterSeek: Bool) {
        isPlaying = resumeAfterSeek
        issue(.seek(to: max(0, time), resumeAfterSeek: resumeAfterSeek))
    }

    func moveToPreviousSentence() {
        guard let segment = sentenceContext.previous ?? sentenceContext.current,
              let time = SentencePlaybackPolicy.startTime(for: segment)
        else { return }
        seek(to: time, resumeAfterSeek: isPlaying)
    }

    func moveToNextSentence() {
        guard let segment = sentenceContext.next,
              let time = SentencePlaybackPolicy.startTime(for: segment)
        else { return }
        seek(to: time, resumeAfterSeek: isPlaying)
    }

    func replayCurrentSentence() {
        guard let time = SentencePlaybackPolicy.startTime(for: sentenceContext.current) else { return }
        seek(to: time, resumeAfterSeek: true)
    }

    func toggleSentenceRepeat() {
        isRepeatingSentence.toggle()
        repeatRange = isRepeatingSentence ? sentenceContext.repeatRange : nil
    }

    func disableSentenceRepeat() {
        isRepeatingSentence = false
        repeatRange = nil
    }

    private func issue(_ action: YTPlaybackAction) {
        nextCommandSequence += 1
        command = YTPlaybackCommand(sequence: nextCommandSequence, action: action)
    }
}
