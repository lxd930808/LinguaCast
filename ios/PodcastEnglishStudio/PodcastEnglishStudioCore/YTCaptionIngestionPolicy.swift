import Foundation

/// Acceptance gate for reusing saved English caption sources.
/// - `strict`: re-validates the timeline and rejects fragmented, overlapping or abnormal-CPS sources.
/// - `acceptParseableContent`: accepts any source that parses into non-empty segments
///   (iOS official-iframe playback).
public enum YTCaptionIngestionPolicy: String, CaseIterable, Hashable, Sendable {
    case strict
    case acceptParseableContent
}
