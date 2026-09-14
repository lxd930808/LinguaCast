#if os(iOS)
import AVFoundation
import ChineseSynthesis
import KokoroPipeline
import Foundation
import Observation
import OSLog
import MediaPlayer
import PodcastEnglishStudioCore

@MainActor
@Observable
final class EpisodeChinesePlayback: NSObject, AVAudioPlayerDelegate {
    var rhythm = SpeechRhythm(rawValue: UserDefaults.standard.string(forKey: "chinese-rhythm") ?? "") ?? .current
    private var speakers: [Int: String] = [:]
    private var rhythmResidency: [SpeechRhythm: [TTSPlaybackCursor: Ready]] = [:]
    private var parkedRevision: String?
    private var parkedResidency: [SpeechRhythm: [TTSPlaybackCursor: Ready]] = [:]
    private var parkedFragmentCounts: [Int: Int] = [:]
    private var isFillingBuffer = true
    private var renderedFragments: [TTSRenderedFragment] = []
    @ObservationIgnored private let metrics = Logger(subsystem: "LinguaCast", category: "ChinesePlayback")
    private var bufferingStarted: Date?
    private var completedPreparation: Set<Int> = []
    private var preparationIdentity: String {
        "chinese-prepared." + (snapshot?.revision ?? "") + "." + rhythm.version
    }


    func selectRhythm(_ next: SpeechRhythm) {
        guard next != rhythm else { return }
        cancelPreparation()
        commitIfHandoffElapsed()
        saveCheckpoint()
        let oldCursor = cursor
        let fraction = current.map { $0.player.currentTime / max(0.001, $0.player.duration) } ?? 0
        rhythmResidency[rhythm] = residency
        rhythm = next
        UserDefaults.standard.set(next.rawValue, forKey: "chinese-rhythm")
        residency = rhythmResidency[next] ?? [:]
        completedPreparation = Set(UserDefaults.standard.array(forKey: preparationIdentity) as? [Int] ?? [])
        failedCursors.removeAll()
        guard isSelected else { return }
        refreshPreparationSummary()
        if let target = residency[oldCursor], FileManager.default.fileExists(atPath: target.url.path) {
            prepare(index: oldCursor.segmentIndex, fragment: oldCursor.fragmentIndex, offset: fraction * target.seconds)
        } else {
            prepare(index: oldCursor.segmentIndex)
        }
    }

    var preparationProgress = ""
    var isPreparingOffline = false
    var preparedBytes = 0
    @ObservationIgnored private var preparationTask: Task<Void, Never>?

    /// Each fragment is published independently; a repeat resumes through validated cache hits.
    func prepareOffline(wholeEpisode: Bool) {
        guard let snapshot, !isPreparingOffline, isForeground else { return }
        let indices = wholeEpisode ? Array(snapshot.segments.indices) : [segmentIndex]
        let selectedRhythm = rhythm
        isPreparingOffline = true
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isPreparingOffline = false }
            do {
                for (position, index) in indices.enumerated() {
                    try Task.checkCancellation()
                    guard self.isForeground, self.pressure == .normal else { throw LocalChineseSpeechError.needsForeground }
                    let segment = snapshot.segments[index]
                    guard segment.isReadable else { throw TTSSynthesisError.invalidInput }
                    let fragments = try await Self.store.fragments(text: segment.text)
                    for (fragmentIndex, text) in fragments.enumerated() {
                        try Task.checkCancellation()
                        guard self.isForeground, self.pressure == .normal else { throw LocalChineseSpeechError.needsForeground }
                        // Let urgent playback refill first; offline preparation never queues a whole episode on the actor.
                        while self.isSelected && self.wantsPlayback && self.bufferedWallSeconds < self.policy.lowWaterSeconds {
                            guard self.isForeground, self.pressure == .normal else { throw LocalChineseSpeechError.needsForeground }
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        let key = snapshot.episodeID + "|" + snapshot.revision + "|" + segment.id + "|" + String(fragmentIndex)
                        let audio = try await Self.store.audio(text: text, key: key, rhythm: selectedRhythm,
                            boundary: fragmentIndex == fragments.count - 1 ? self.boundary(after: index) : nil,
                            retainPrepared: true)
                        try Task.checkCancellation()
                        self.recordRendered(TTSPlaybackCursor(segmentIndex: index, fragmentIndex: fragmentIndex),
                            audio: audio, fragmentCount: fragments.count, snapshot: snapshot, rhythm: selectedRhythm)
                        self.preparedBytes = await Self.store.retainedBytes()
                        self.preparationProgress = L10n.format("tts.prepared_progress", fallback: "Prepared %d/%d segments", position, indices.count)
                        await Task.yield()
                    }
                    self.completedPreparation.insert(index)
                    UserDefaults.standard.set(Array(self.completedPreparation).sorted(), forKey: self.preparationIdentity)
                    self.preparationProgress = L10n.format("tts.prepared_progress", fallback: "Prepared %d/%d segments", position + 1, indices.count)
                }
                self.preparationProgress = L10n.string("tts.prepared_ready", fallback: "Ready for offline playback")
            } catch is CancellationError {
                self.preparationProgress = L10n.string("tts.prepared_cancelled", fallback: "Cancelled. Prepare again to resume.")
            } catch {
                self.preparationProgress = L10n.string("tts.prepared_paused", fallback: "Preparation paused. Check foreground, translation and storage, then retry.")
            }
        }
    }

    func cancelPreparation() { preparationTask?.cancel() }

    func clearPreparedAudio() {
        guard !isPreparingOffline else { return }
        Task {
            try? await Self.store.clearPrepared()
            preparedBytes = await Self.store.retainedBytes()
            // Keep only players already in use. Stale file references must not count as ready.
            let active = Set([current?.cursor, pending?.cursor].compactMap { $0 })
            residency = residency.filter { active.contains($0.key) }
            rhythmResidency.removeAll()
            completedPreparation.removeAll()
            UserDefaults.standard.removeObject(forKey: preparationIdentity)
            preparationProgress = L10n.string("tts.prepared_cleared", fallback: "Unused prepared audio cleared")
            pump()
        }
    }

    private var bufferedWallSeconds: Double {
        policy.bufferedSeconds(units: candidates(limit: policy.maxUnits).map {
            TTSPrefetchUnit(cursor: $0, readySeconds: residency[$0]?.seconds)
        }, currentTime: current?.player.currentTime ?? 0, rate: Double(playbackRate))
    }

    private func protectPlaybackFiles() async {
        await Self.store.protect(Set(residency.values.map(\.url)))
    }

    private func trace(_ event: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-linguacast-ui-testing") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chinese-playback-diagnostic.txt")
        let previous = (try? String(contentsOf: url)) ?? ""
        let line = "\(Date().timeIntervalSince1970) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) \(event)\n"
        try? String((previous + line).suffix(24000)).write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    var didFinishEpisode = false
    var isSelected = false
    var isPlaying = false
    var isPreparing = false
    /// Playback wants to continue but the next clip is still being synthesized.
    var isBuffering = false
    var errorMessage: String?
    /// A sentence that stopped playback. V16 never skips generated content on its own, so
    /// the mode stays selected here and the user picks retry, skip or original audio.
    var stoppedSegmentID: String?
    var activeSequence: Int?
    var originalTime: Double = 0
    var duration: Double = 0
    var playbackRate: Float = 1 {
        didSet {
            current?.player.rate = playbackRate
            // A start armed at the old rate would fire early or late; re-arm it.
            rescheduleHandoff()
        }
    }
    private var isForeground = true
    private var episodeTitle = ""
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    private var snapshot: TTSTranscriptSnapshot?
    /// The authoritative playhead. It outlives the clip, which is nil while buffering.
    private var cursor = TTSPlaybackCursor(segmentIndex: 0)
    private var segmentIndex: Int { cursor.segmentIndex }
    private var fragmentIndex: Int { cursor.fragmentIndex }
    var originalSentenceStart: Double {
        guard let snapshot, snapshot.segments.indices.contains(segmentIndex) else { return originalTime }
        return Double(snapshot.segments[segmentIndex].startMS) / 1000
    }
    var shouldResumeOriginal: Bool { wantsPlayback }
    private var wantsPlayback = false
    private var generation = UUID()

    private struct Clip {
        let cursor: TTSPlaybackCursor
        let url: URL
        let player: AVAudioPlayer
    }
    private struct Ready {
        let url: URL
        let seconds: Double
        let wasCached: Bool
    }
    private struct Job {
        let cursor: TTSPlaybackCursor
        let text: String
        let key: String
        let allowsSynthesis: Bool
        let generation: UUID
        let rhythm: SpeechRhythm
        let boundary: SpeechBoundary?
    }

    @ObservationIgnored private var current: Clip?
    @ObservationIgnored private var pending: Clip?
    /// Absolute `deviceCurrentTime` at which `pending` is armed to start.
    @ObservationIgnored private var pendingStart: TimeInterval?
    @ObservationIgnored private var residency: [TTSPlaybackCursor: Ready] = [:]
    @ObservationIgnored private var fragmentCounts: [Int: Int] = [:]
    @ObservationIgnored private var failedCursors: Set<TTSPlaybackCursor> = []
    @ObservationIgnored private var producer: Task<Void, Never>?
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private let policy = TTSPrefetchPolicy()
    @ObservationIgnored private var pressure = TTSPrefetchPressure.from(ProcessInfo.processInfo.thermalState)
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var startWait: Date?
    @ObservationIgnored private var restoreOffset: Double = 0
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private static let store = LocalChineseSpeechStore(
        resources: Bundle.main.bundleURL.appendingPathComponent("ChineseVoice"),
        cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ChineseSpeech"))


    func select(episodeID: String, language: String, rows: [LearningSegment], original: AudioPlaybackControllerBridge) {
        do {
            guard #available(iOS 18, *) else { throw TTSSynthesisError.unsupportedDevice }
            guard Bundle.main.url(forResource: "validation-identity", withExtension: "json", subdirectory: "ChineseVoice") != nil else {
                throw TTSSynthesisError.modelUnavailable
            }
            let snapshot = try TTSTranscriptSnapshot(episodeID: episodeID, targetLanguage: language, segments: rows)
            guard let segment = snapshot.segment(atOriginalSeconds: original.time), segment.isReadable,
                  let index = snapshot.segments.firstIndex(of: segment) else { throw TTSSynthesisError.invalidInput }
            stop()
            self.snapshot = snapshot
            if parkedRevision == snapshot.revision {
                rhythmResidency = parkedResidency.mapValues { clips in
                    clips.filter { FileManager.default.fileExists(atPath: $0.value.url.path) }
                }
                residency = rhythmResidency[rhythm] ?? [:]
                fragmentCounts = parkedFragmentCounts
            } else {
                parkedRevision = nil
                parkedResidency.removeAll()
                parkedFragmentCounts.removeAll()
            }
            self.speakers = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.speaker.map { (row.sequence, $0) } })
            completedPreparation = Set(UserDefaults.standard.array(forKey: preparationIdentity) as? [Int] ?? [])
            preparationProgress = ""
            refreshPreparationSummary()
            episodeTitle = original.title
            installCommands()
            observeThermalState()
            duration = max(original.duration, Double(snapshot.segments.last?.endMS ?? 0) / 1000)
            playbackRate = original.rate
            wantsPlayback = original.isPlaying
            original.pause()
            isSelected = true
            // Switching follows the current original sentence. Local checkpoints never overwrite cloud progress.
            prepare(index: index)
        } catch {
            errorMessage = Self.message(error)
        }
    }

    func restore(episodeID: String, language: String, rows: [LearningSegment], original: AudioPlaybackControllerBridge) {
        guard let data = UserDefaults.standard.data(forKey: "chinese-playback." + episodeID),
              let checkpoint = try? JSONDecoder().decode(TTSPlaybackCheckpoint.self, from: data),
              let snapshot = try? TTSTranscriptSnapshot(episodeID: episodeID, targetLanguage: language, segments: rows),
              checkpoint.canRestore(in: snapshot),
              let index = snapshot.segments.firstIndex(where: { $0.id == checkpoint.segmentID }) else { return }
        let restoredOriginal = AudioPlaybackControllerBridge(title: original.title,
            time: Double(snapshot.segments[index].startMS) / 1000, duration: original.duration,
            rate: original.rate, isPlaying: false, pause: original.pause)
        select(episodeID: episodeID, language: language, rows: rows, original: restoredOriginal)
        guard isSelected else { return }
        wantsPlayback = false
        let compatible = checkpoint.rhythmVersion == rhythm.version
        prepare(index: index, fragment: compatible ? checkpoint.fragmentIndex : 0,
            offset: compatible ? checkpoint.fragmentSeconds : 0, restoring: true)
    }

    func forgetSelectedMode() {
        if let snapshot { UserDefaults.standard.removeObject(forKey: "chinese-playback." + snapshot.episodeID) }
    }

    func invalidateIfChanged(episodeID: String, language: String, rows: [LearningSegment]) {
        guard isSelected else { return }
        let updated = try? TTSTranscriptSnapshot(episodeID: episodeID, targetLanguage: language, segments: rows)
        if updated?.revision != snapshot?.revision { stop(); forgetSelectedMode() }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if !active { saveCheckpoint(); cancelPreparation() }
        // Cached clips still play in the background; only synthesis stops (FR-05.9).
        pump()
    }

    /// Route changes move the output clock an armed start was measured against.
    func handleRouteChange() {
        commitIfHandoffElapsed()
        rescheduleHandoff()
    }

    private func observeThermalState() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pressure = TTSPrefetchPressure.from(ProcessInfo.processInfo.thermalState)
                self.pump()
            }
        }
    }

    private func installCommands() {
        guard commands.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [
            (center.playCommand, 0), (center.pauseCommand, 1), (center.togglePlayPauseCommand, 2),
            (center.skipForwardCommand, 3), (center.skipBackwardCommand, 4)
        ] {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isSelected else { return }
                    switch action {
                    case 0: if !self.wantsPlayback { self.playPause() }
                    case 1: self.pause()
                    case 2: self.playPause()
                    case 3: self.seek(to: self.originalTime + 15)
                    default: self.seek(to: self.originalTime - 15)
                    }
                }
                return .success
            }
            commands.append((command, target))
        }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in if let self, self.isSelected { self.seek(to: time) } }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, target))
    }

    private func updateNowPlaying() {
        guard isSelected else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: episodeTitle + " · " + L10n.string("tts.chinese", fallback: "Chinese"),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: originalTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]
    }

    func playPause() {
        trace("func playPause() { wants=\(wantsPlayback) preparing=\(isPreparing) current=\(current != nil)")
        if wantsPlayback { pause(); return }
        commitIfHandoffElapsed()
        wantsPlayback = true
        errorMessage = nil
        startWait = Date()
        if let current { start(current.player) }
        else if isPreparing || isBuffering {
            isBuffering = true
            resumeIfReady()
            pump()
        }
        else { prepare(index: segmentIndex, fragment: fragmentIndex) }
    }

    func pause() {
        trace("func pause() { wants=\(wantsPlayback) preparing=\(isPreparing) current=\(current != nil)")
        // The boundary may already have passed without the callback having run.
        commitIfHandoffElapsed()
        wantsPlayback = false
        startWait = nil
        current?.player.pause()
        // An armed start would otherwise fire while paused: the device clock keeps running.
        unscheduleHandoff()
        isPlaying = false
        isBuffering = false
        updateNowPlaying()
        saveCheckpoint()
    }

    func stop() {
        // Keep a bounded set of validated file references across an original-audio
        // round trip. An obsolete, non-preemptible CoreML call must not hold up
        // replaying a clip already available locally.
        if isSelected, let snapshot {
            rhythmResidency[rhythm] = residency
            parkedRevision = snapshot.revision
            parkedResidency = rhythmResidency
            parkedFragmentCounts = fragmentCounts
        }
        cancelPreparation()
        pause()
        generation = UUID()
        producer?.cancel(); producer = nil
        wake?.finish(); wake = nil
        clock?.cancel(); clock = nil
        discardClips()
        residency.removeAll()
        rhythmResidency.removeAll()
        renderedFragments.removeAll()
        fragmentCounts.removeAll()
        failedCursors.removeAll()
        isPreparing = false
        isBuffering = false
        isSelected = false
        stoppedSegmentID = nil
        for (command, target) in commands { command.removeTarget(target) }
        commands.removeAll()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Task { self.trace("release begin"); await Self.store.protect([]); await Self.store.releaseModels(); self.trace("release end") }
    }

    func seek(to time: Double) {
        guard let snapshot, time.isFinite,
              let segment = snapshot.segment(atOriginalSeconds: min(max(0, time), max(0, duration - 0.001))),
              let index = snapshot.segments.firstIndex(of: segment) else { return }
        prepare(index: index)
    }

    func play(sequence: Int) {
        guard let snapshot, let segment = snapshot.segment(forDisplaySequence: sequence),
              let index = snapshot.segments.firstIndex(of: segment) else { return }
        wantsPlayback = true
        prepare(index: index)
    }

    /// A sentence without a translation has nothing to synthesize again.
    var canRetryStoppedSegment: Bool {
        guard let stoppedSegmentID, let snapshot else { return false }
        return snapshot.segments.first { $0.id == stoppedSegmentID }?.isReadable ?? false
    }

    func retryStoppedSegment() {
        guard canRetryStoppedSegment else { return }
        wantsPlayback = true
        failedCursors.remove(cursor)
        prepare(index: segmentIndex, fragment: fragmentIndex)
    }

    /// Only the user may pass over content that has a translation.
    func skipStoppedSegment() {
        guard let snapshot, stoppedSegmentID != nil else { return }
        guard let next = snapshot.nextReadableIndex(after: segmentIndex) else {
            stoppedSegmentID = nil
            errorMessage = nil
            originalTime = duration
            didFinishEpisode = true
            pause()
            clock?.cancel()
            return
        }
        wantsPlayback = true
        prepare(index: next)
    }

    // MARK: - Discontinuities

    /// The one entry point that throws work away: selecting, seeking, tapping a
    /// sentence, retrying, skipping and restoring. A natural advance never comes here.
    private func prepare(index: Int, fragment: Int = 0, offset: Double = 0, restoring: Bool = false) {
        guard let snapshot, snapshot.segments.indices.contains(index) else { pause(); return }
        trace("prepare index=\(index) fragment=\(fragment) wants=\(wantsPlayback)")
        didFinishEpisode = false
        generation = UUID()
        isFillingBuffer = true
        discardClips()
        isPlaying = false
        cursor = TTSPlaybackCursor(segmentIndex: index, fragmentIndex: fragment)
        restoreOffset = offset
        isRestoring = restoring
        startWait = Date()
        let segment = snapshot.segments[index]
        originalTime = Double(segment.startMS) / 1000
        activeSequence = segment.displaySequences.first
        saveCheckpoint()
        errorMessage = nil
        stoppedSegmentID = nil
        guard segment.isReadable else {
            isPreparing = false
            isBuffering = false
            wantsPlayback = false
            stoppedSegmentID = segment.id
            errorMessage = L10n.string("tts.missing_translation", fallback: "This sentence has no Chinese translation. Select another sentence or switch to original audio.")
            return
        }
        isPreparing = true
        isBuffering = wantsPlayback
        startProducer()
        // A seek/rhythm switch can already have a ready clip. It must not wait
        // for a producer callback when the high watermark requires no new job.
        resumeIfReady()
        armNextIfReady()
        observeTime()
    }

    private func discardClips() {
        for clip in [current, pending].compactMap({ $0 }) {
            // A dropped player must never deliver a late callback into the new state.
            clip.player.delegate = nil
            clip.player.stop()
        }
        current = nil
        pending = nil
        pendingStart = nil
    }

    // MARK: - Producer

    private func pump() { wake?.yield() }

    private func startProducer() {
        producer?.cancel()
        wake?.finish()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        wake = continuation
        producer = Task { [weak self] in
            for await _ in stream {
                while !Task.isCancelled {
                    guard let self else { break }
                    if self.current == nil { self.trace("producer awaiting protect") }
                    await self.protectPlaybackFiles()
                    guard let job = self.nextJob() else { break }
                    self.trace("job segment=\(job.cursor.segmentIndex) fragment=\(job.cursor.fragmentIndex)")
                    do {
                        let fragments = try await Self.store.fragments(text: job.text, allowSynthesis: job.allowsSynthesis)
                        self.record(fragmentCount: fragments.count, for: job.cursor.segmentIndex, generation: job.generation)
                        guard fragments.indices.contains(job.cursor.fragmentIndex) else { throw TTSSynthesisError.invalidInput }
                        self.trace("plan ready")
                        let synthesisStarted = Date()
                        let audio = try await Self.store.audio(text: fragments[job.cursor.fragmentIndex],
                            key: job.key, allowSynthesis: job.allowsSynthesis, rhythm: job.rhythm,
                            boundary: job.cursor.fragmentIndex == fragments.count - 1 ? job.boundary : nil)
                        let elapsed = Date().timeIntervalSince(synthesisStarted)
                        self.metrics.info("ready segment=\(job.cursor.segmentIndex) fragment=\(job.cursor.fragmentIndex) cached=\(audio.wasCached) synthesisSeconds=\(elapsed) mediaSeconds=\(audio.duration) rate=\(self.playbackRate) rhythm=\(job.rhythm.version, privacy: .public)")
                        self.clipReady(job.cursor, audio: audio, generation: job.generation)
                    } catch is CancellationError {
                        self.trace("producer cancelled token=\(job.generation)")
                        return
                    } catch let failure as LocalChineseSpeechError where failure.isNeedsForeground {
                        self.trace("needs foreground current=\(job.cursor == self.cursor)")
                        if self.generation == job.generation, job.cursor == self.cursor {
                            self.errorMessage = L10n.string("tts.cache_foreground", fallback: "Chinese cache exhausted. Return to the app to prepare audio.")
                        }
                        break
                    } catch {
                        self.clipFailed(job.cursor, error: error, generation: job.generation)
                    }
                }
            }
        }
        pump()
    }

    /// The next unit worth synthesizing, re-decided from the live playhead between
    /// every inference so a seek never waits behind a queue.
    private func nextJob() -> Job? {
        guard let snapshot, isSelected else { return nil }
        let units = candidates(limit: policy.maxUnits)
            .map { TTSPrefetchUnit(cursor: $0, readySeconds: residency[$0]?.seconds) }
        let buffered = policy.bufferedSeconds(units: units, currentTime: current?.player.currentTime ?? 0,
            rate: Double(playbackRate))
        if buffered < policy.lowWaterSeconds { isFillingBuffer = true }
        if buffered >= policy.secondsAhead { isFillingBuffer = false }
        guard isFillingBuffer || residency[cursor] == nil else { return nil }
        let remainingUnits = units.enumerated().map { index, unit in
            TTSPrefetchUnit(cursor: unit.cursor, readySeconds: unit.readySeconds.map {
                max(0.001, $0 - (index == 0 ? (current?.player.currentTime ?? 0) : 0))
            })
        }
        let resident = policy.residentCount(units: remainingUnits, rate: Double(playbackRate), pressure: pressure)
        for unit in units.prefix(resident) where !unit.isReady && !failedCursors.contains(unit.cursor) {
            let segment = snapshot.segments[unit.cursor.segmentIndex]
            return Job(cursor: unit.cursor, text: segment.text,
                       key: snapshot.episodeID + "|" + snapshot.revision + "|" + segment.id + "|" + String(unit.cursor.fragmentIndex),
                       allowsSynthesis: policy.allowsSynthesis(pressure: pressure, isForeground: isForeground),
                       generation: generation, rhythm: rhythm, boundary: boundary(after: unit.cursor.segmentIndex))
        }
        return nil
    }

    private func boundary(after index: Int) -> SpeechBoundary? {
        guard let snapshot else { return nil }
        guard index + 1 < snapshot.segments.count else { return .end }
        let segment = snapshot.segments[index]
        let next = snapshot.segments[index + 1]
        let speaker = segment.displaySequences.compactMap { speakers[$0] }.first
        let nextSpeaker = next.displaySequences.compactMap { speakers[$0] }.first
        if let speaker, let nextSpeaker, !speaker.isEmpty, !nextSpeaker.isEmpty, speaker != nextSpeaker { return .speaker }
        // The production transcript currently has no paragraph ID. Use the documented source-gap proxy.
        if next.startMS - segment.endMS >= 1500 { return .paragraphProxy }
        return .punctuation(segment.text)
    }

    /// Walks forward from the playhead. It stops at a sentence without a
    /// translation instead of reading past it — that one needs the user's decision.
    private func candidates(limit: Int) -> [TTSPlaybackCursor] {
        guard let snapshot else { return [] }
        var list: [TTSPlaybackCursor] = []
        var probe: TTSPlaybackCursor? = cursor
        while let next = probe, list.count < limit {
            guard snapshot.segments.indices.contains(next.segmentIndex),
                  snapshot.segments[next.segmentIndex].isReadable else { break }
            list.append(next)
            probe = nextCursor(after: next)
        }
        return list
    }

    private func nextCursor(after cursor: TTSPlaybackCursor) -> TTSPlaybackCursor? {
        guard let snapshot else { return nil }
        if cursor.fragmentIndex + 1 < (fragmentCounts[cursor.segmentIndex] ?? 1) {
            return TTSPlaybackCursor(segmentIndex: cursor.segmentIndex, fragmentIndex: cursor.fragmentIndex + 1)
        }
        let next = cursor.segmentIndex + 1
        // Never skip a segment here: an untranslated one must stop playback for the user.
        return snapshot.segments.indices.contains(next) ? TTSPlaybackCursor(segmentIndex: next) : nil
    }

    private func record(fragmentCount: Int, for segment: Int, generation token: UUID) {
        guard generation == token else { return }
        fragmentCounts[segment] = fragmentCount
    }

    private func clipReady(_ ready: TTSPlaybackCursor, audio: LocalChineseAudio, generation token: UUID) {
        guard generation == token, isSelected else { return }
        trace("ready segment=\(ready.segmentIndex) fragment=\(ready.fragmentIndex) cached=\(audio.wasCached)")
        residency[ready] = Ready(url: audio.url, seconds: audio.duration, wasCached: audio.wasCached)
        if let snapshot {
            recordRendered(ready, audio: audio, fragmentCount: fragmentCounts[ready.segmentIndex] ?? 1,
                snapshot: snapshot, rhythm: rhythm)
        }
        failedCursors.remove(ready)
        resumeIfReady()
        armNextIfReady()
        pump()
    }

    private func recordRendered(_ ready: TTSPlaybackCursor, audio: LocalChineseAudio,
                                fragmentCount: Int, snapshot: TTSTranscriptSnapshot, rhythm: SpeechRhythm) {
            let segment = snapshot.segments[ready.segmentIndex]
            renderedFragments.removeAll { $0.segmentID == segment.id && $0.fragmentIndex == ready.fragmentIndex && $0.rhythmVersion == rhythm.version }
            renderedFragments.append(TTSRenderedFragment(segment: segment, fragmentIndex: ready.fragmentIndex,
                fragmentCount: fragmentCount, sampleCount: Int((audio.duration * 24000).rounded()),
                rhythmVersion: rhythm.version, audioURL: audio.url))
            if let data = try? JSONEncoder().encode(renderedFragments) {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ChineseSpeech/mappings")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appendingPathComponent(snapshot.revision + ".json"), options: .atomic)
            }
    }

    private func refreshPreparationSummary() {
        guard let snapshot else { return }
        let selectedRhythm = rhythm
        let identity = preparationIdentity
        let recorded = completedPreparation
        Task { [weak self] in
            guard let self else { return }
            var validated = Set<Int>()
            for index in recorded where snapshot.segments.indices.contains(index) {
                guard self.snapshot?.revision == snapshot.revision, self.rhythm == selectedRhythm else { return }
                let segment = snapshot.segments[index]
                do {
                    let fragments = try await Self.store.fragments(text: segment.text, allowSynthesis: false)
                    for (fragmentIndex, text) in fragments.enumerated() {
                        let key = snapshot.episodeID + "|" + snapshot.revision + "|" + segment.id + "|" + String(fragmentIndex)
                        _ = try await Self.store.audio(text: text, key: key, allowSynthesis: false, rhythm: selectedRhythm,
                            boundary: fragmentIndex == fragments.count - 1 ? self.boundary(after: index) : nil)
                    }
                    validated.insert(index)
                } catch { /* Missing/invalid audio is no longer an offline guarantee. */ }
            }
            guard self.snapshot?.revision == snapshot.revision, self.rhythm == selectedRhythm, !self.isPreparingOffline else { return }
            self.completedPreparation = validated
            UserDefaults.standard.set(Array(validated).sorted(), forKey: identity)
            self.preparedBytes = await Self.store.retainedBytes()
            self.preparationProgress = L10n.format("tts.prepared_progress", fallback: "Prepared %d/%d segments", validated.count, snapshot.segments.count)
        }
    }

    private func clipFailed(_ failure: TTSPlaybackCursor, error: Error, generation token: UUID) {
        guard generation == token, isSelected else { return }
        trace("failed segment=\(failure.segmentIndex) error=\(error)")
        failedCursors.insert(failure)
        guard failure == cursor else { return }   // A lookahead failure is reported when playback reaches it.
        isPreparing = false
        isBuffering = false
        wantsPlayback = false
        isPlaying = false
        guard Self.isFatal(error) else {
            // One sentence failing is not the mode failing: hold position and let the
            // user retry, skip this sentence, or go back to the original audio.
            stoppedSegmentID = snapshot?.segments[failure.segmentIndex].id
            errorMessage = L10n.string("tts.segment_failed", fallback: "This sentence could not be synthesized. Retry, skip it, or switch to original audio.")
            saveCheckpoint()
            return
        }
        stop()
        forgetSelectedMode()
        errorMessage = Self.message(error)
    }

    // MARK: - Clips

    private func makePlayer(_ ready: Ready) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(contentsOf: ready.url) else { return nil }
        player.enableRate = true
        player.rate = playbackRate
        player.delegate = self
        player.prepareToPlay()
        return player
    }

    /// The playhead's clip exists (or has just arrived): build it, then apply the
    /// pre-buffer gate. Called from the producer and from every clock tick.
    private func resumeIfReady() {
        if current == nil, residency[cursor] != nil { installCurrent(); return }
        guard isBuffering, wantsPlayback, let clip = current, !clip.player.isPlaying else { return }
        guard canStartNow() else { return }
        isBuffering = false
        start(clip.player)
    }

    private func canStartNow() -> Bool {
        let next = nextCursor(after: cursor)
        return policy.canStart(playheadSeconds: residency[cursor]?.seconds,
                               nextIsReady: next.map { residency[$0] != nil } ?? false,
                               hasNext: next != nil,
                               rate: Double(playbackRate),
                               waitedSeconds: Date().timeIntervalSince(startWait ?? Date()))
    }

    /// Arms whatever the producer has already delivered for the next unit — it is
    /// usually ready well before the current sentence ends.
    private func armNextIfReady() {
        guard current != nil, pending == nil, isSelected,
              let next = nextCursor(after: cursor), residency[next] != nil else { return }
        installPending(next)
    }

    private func installCurrent() {
        guard let ready = residency[cursor], let snapshot else { return }
        if isRestoring, !ready.wasCached {
            // The checkpoint's audio is gone, so resume at the sentence start instead.
            isRestoring = false
            let index = cursor.segmentIndex
            prepare(index: index)
            errorMessage = L10n.string("tts.switch_hint", fallback: "Switching audio starts from the current sentence.")
            return
        }
        guard let player = makePlayer(ready) else {
            clipFailed(cursor, error: TTSSynthesisError.synthesisFailed, generation: generation)
            return
        }
        player.currentTime = min(max(0, restoreOffset), max(0, player.duration - 0.01))
        restoreOffset = 0
        isRestoring = false
        current = Clip(cursor: cursor, url: ready.url, player: player)
        isPreparing = false
        activeSequence = snapshot.segments[cursor.segmentIndex].displaySequences.first
        guard wantsPlayback else {
            isBuffering = false
            return
        }
        guard canStartNow() else {
            isBuffering = true   // Pre-buffer: the clock re-checks every tick.
            return
        }
        isBuffering = false
        start(player)
    }

    private func installPending(_ ready: TTSPlaybackCursor) {
        guard let clip = residency[ready], let player = makePlayer(clip) else { return }
        pending = Clip(cursor: ready, url: clip.url, player: player)
        pendingStart = nil
        scheduleHandoff()
    }

    /// Arms the next clip to start exactly when this one ends. This is what removes
    /// the seam: no callback, no file open, no main-thread hop at the boundary.
    private func scheduleHandoff() {
        guard wantsPlayback, isPlaying, pendingStart == nil, let current, let pending,
              let lead = TTSHandoffSchedule.leadSeconds(duration: current.player.duration,
                                                        currentTime: current.player.currentTime,
                                                        rate: Double(playbackRate)) else { return }
        let start = pending.player.deviceCurrentTime + lead
        guard pending.player.play(atTime: start) else { return }   // Fall back to the delegate.
        pendingStart = start
    }

    /// Cancels an armed start by rebuilding the player: `stop()` alone is not a
    /// contract for disarming `play(atTime:)`.
    private func unscheduleHandoff() {
        guard let pending else { pendingStart = nil; return }
        pending.player.delegate = nil
        pending.player.stop()
        pendingStart = nil
        if let ready = residency[pending.cursor], let player = makePlayer(ready) {
            self.pending = Clip(cursor: pending.cursor, url: ready.url, player: player)
        } else {
            self.pending = nil
        }
    }

    private func rescheduleHandoff() {
        guard pending != nil else { return }
        unscheduleHandoff()
        scheduleHandoff()
    }

    private func commitIfHandoffElapsed() {
        guard let current, let pending, let start = pendingStart,
              pending.player.deviceCurrentTime >= start else { return }
        promote(finished: current.player)
    }

    private func promote(finished: AVAudioPlayer) {
        guard let outgoing = current, outgoing.player === finished, let snapshot else { return }
        outgoing.player.delegate = nil
        outgoing.player.stop()
        current = nil
        guard let next = pending, pendingStart != nil, wantsPlayback else {
            advanceWithoutAudio(after: outgoing.cursor)
            return
        }
        pending = nil
        pendingStart = nil
        current = next
        cursor = next.cursor
        let segment = snapshot.segments[next.cursor.segmentIndex]
        originalTime = Double(segment.startMS) / 1000
        activeSequence = segment.displaySequences.first
        isPlaying = true
        isBuffering = false
        isPreparing = false
        prune()
        updateNowPlaying()
        saveCheckpoint()
        armNextIfReady()
        pump()
    }

    /// The boundary arrived with nothing ready: buffer, never skip (AC-10).
    private func advanceWithoutAudio(after finished: TTSPlaybackCursor) {
        guard let snapshot else { return }
        guard let next = nextCursor(after: finished) else {
            originalTime = duration
            didFinishEpisode = true
            pause()
            clock?.cancel()
            discardClips()
            return
        }
        cursor = next
        let segment = snapshot.segments[next.segmentIndex]
        originalTime = Double(segment.startMS) / 1000
        activeSequence = segment.displaySequences.first
        isPlaying = false
        prune()
        saveCheckpoint()
        guard segment.isReadable else {
            // Untranslated: stop here and let the user decide (FR-04.5).
            prepare(index: next.segmentIndex)
            return
        }
        guard wantsPlayback else { return }
        if failedCursors.contains(next) {
            clipFailed(next, error: TTSSynthesisError.synthesisFailed, generation: generation)
            return
        }
        isBuffering = true
        if residency[next] == nil {
            bufferingStarted = Date()
            metrics.info("buffer-empty segment=\(next.segmentIndex) fragment=\(next.fragmentIndex) rate=\(self.playbackRate)")
        }
        startWait = Date()
        resumeIfReady()
        pump()
    }

    /// Keeps residency from growing with the episode.
    private func prune() {
        let keep = Set(candidates(limit: policy.maxUnits))
        residency = residency.filter { keep.contains($0.key) || $0.key == cursor }
    }

    private func start(_ player: AVAudioPlayer) {
        trace("private func start(_ player: AVAudioPlayer) { wants=\(wantsPlayback) preparing=\(isPreparing) current=\(current != nil)")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard player.play() else { throw TTSSynthesisError.synthesisFailed }
            if let bufferingStarted {
                metrics.info("buffer-resumed waitSeconds=\(Date().timeIntervalSince(bufferingStarted))")
                self.bufferingStarted = nil
            }
            // This is the playback API start, not a measurement of acoustic first sound.
            metrics.info("play-api-start segment=\(self.segmentIndex) bufferSeconds=\(self.bufferedWallSeconds) rate=\(self.playbackRate)")
            isPlaying = true
            isBuffering = false
            updateNowPlaying()
            armNextIfReady()
            scheduleHandoff()
        } catch {
            wantsPlayback = false
            isPlaying = false
            errorMessage = Self.message(error)
        }
    }

    /// One clock for progress, the scheduled handoff and the buffering re-check.
    /// It must survive `current == nil`, which is exactly when buffering happens.
    private func observeTime() {
        clock?.cancel()
        let token = generation
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.generation == token, self.isSelected, let snapshot = self.snapshot else { return }
                self.pump()
                self.commitIfHandoffElapsed()
                self.armNextIfReady()
                self.scheduleHandoff()
                self.resumeIfReady()
                guard let clip = self.current else { continue }
                let segment = snapshot.segments[clip.cursor.segmentIndex]
                self.originalTime = (self.fragmentCounts[clip.cursor.segmentIndex] ?? 1) == 1
                    ? (snapshot.originalSeconds(segmentID: segment.id, playedSeconds: clip.player.currentTime,
                        totalSeconds: clip.player.duration) ?? Double(segment.startMS) / 1000)
                    : Double(segment.startMS) / 1000
                // A pending clip that has already started must not read as "stopped".
                if self.isPlaying, !clip.player.isPlaying, self.pendingStart == nil, !self.isBuffering {
                    self.isPlaying = false
                }
                self.updateNowPlaying()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isSelected, let finished = self.current, finished.player === player else { return }
            if !flag {
                self.pause()
                self.stoppedSegmentID = self.snapshot?.segments[finished.cursor.segmentIndex].id
                self.errorMessage = L10n.string("tts.segment_failed", fallback: "This sentence could not be synthesized. Retry, skip it, or switch to original audio.")
                return
            }
            self.promote(finished: player)
        }
    }

    private func saveCheckpoint() {
        guard isSelected, let snapshot, snapshot.segments.indices.contains(segmentIndex) else { return }
        let checkpoint = TTSPlaybackCheckpoint(episodeID: snapshot.episodeID, mode: .chinese, transcriptRevision: snapshot.revision,
            segmentID: snapshot.segments[segmentIndex].id, fragmentIndex: fragmentIndex, fragmentSeconds: current?.player.currentTime ?? restoreOffset, rhythmVersion: rhythm.version)
        if let data = try? JSONEncoder().encode(checkpoint) {
            UserDefaults.standard.set(data, forKey: "chinese-playback." + snapshot.episodeID)
        }
    }

    /// Device, model and resource failures end the mode; everything else is one sentence.
    private static func isFatal(_ error: Error) -> Bool {
        if let error = error as? TTSSynthesisError { return error.scope == .mode }
        if let error = error as? LocalChineseSpeechError {
            switch error {
            case .missingResources, .invalidResources: return true
            case .emptyAudio, .needsForeground, .insufficientStorage: return false
            }
        }
        return false
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? TTSSynthesisError, error == .unsupportedDevice {
            return L10n.string("tts.requires_ios18", fallback: "Chinese audio requires iOS 18 or later.")
        }
        if let error = error as? TTSSynthesisError, error == .modelUnavailable {
            return L10n.string("tts.resources_missing", fallback: "The Chinese voice is not included in this build.")
        }
        return L10n.string("tts.failed", fallback: "Chinese audio could not be prepared. Retry or switch to original audio.")
    }
}

private extension LocalChineseSpeechError {
    var isNeedsForeground: Bool {
        if case .needsForeground = self { return true }
        return false
    }
}

struct AudioPlaybackControllerBridge {
    var title: String = ""
    let time: Double
    let duration: Double
    let rate: Float
    let isPlaying: Bool
    let pause: () -> Void
}
#endif
