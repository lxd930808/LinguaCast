import XCTest
@testable import PodcastEnglishStudioCore

final class CloudSyncCoreTests: XCTestCase {
    func testPodcastIdentityNormalizesEquivalentURLs() {
        let first = SyncRecordIdentity.podcast(sourceURL: " HTTPS://Example.com/feed/ ")
        let second = SyncRecordIdentity.podcast(sourceURL: "https://example.com/feed#latest")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("podcast-"))
    }

    func testYouTubeIdentityUsesStableChannelID() {
        XCTAssertEqual(
            SyncRecordIdentity.youtube(channelID: " UCabc123 "),
            "youtube-UCabc123"
        )
    }

    func testMergeKeepsNewestValueForEachIndependentField() {
        let local = SyncDocument(
            recordName: "podcast-1",
            kind: .podcastSubscription,
            fields: [
                "displayName": field("Local title", seconds: 20, device: "phone"),
                "isEnabled": field("true", seconds: 10, device: "phone")
            ]
        )
        let remote = SyncDocument(
            recordName: "podcast-1",
            kind: .podcastSubscription,
            fields: [
                "displayName": field("TV title", seconds: 10, device: "tv"),
                "isEnabled": field("false", seconds: 30, device: "tv")
            ]
        )

        let merged = local.merged(with: remote)

        XCTAssertEqual(merged.fields["displayName"]?.value, "Local title")
        XCTAssertEqual(merged.fields["isEnabled"]?.value, "false")
        XCTAssertFalse(merged.isDeleted)
    }

    func testEqualTimestampUsesDeviceIDAsDeterministicTieBreaker() {
        let phone = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: ["model": field("phone-model", seconds: 10, device: "phone")]
        )
        let tv = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: ["model": field("tv-model", seconds: 10, device: "tv")]
        )

        XCTAssertEqual(phone.merged(with: tv).fields["model"]?.value, "tv-model")
        XCTAssertEqual(tv.merged(with: phone).fields["model"]?.value, "tv-model")
    }

    func testNewerDeletionWinsAndLaterUpsertRestoresRecord() {
        let original = SyncDocument(
            recordName: "youtube-UC1",
            kind: .youtubeSubscription,
            fields: ["displayName": field("Channel", seconds: 10, device: "phone")]
        )
        let deleted = SyncDocument(
            recordName: "youtube-UC1",
            kind: .youtubeSubscription,
            fields: [:],
            deletionVersion: version(seconds: 20, device: "tv")
        )

        let tombstone = original.merged(with: deleted)
        XCTAssertTrue(tombstone.isDeleted)

        let restored = SyncDocument(
            recordName: "youtube-UC1",
            kind: .youtubeSubscription,
            fields: ["displayName": field("Restored", seconds: 30, device: "phone")]
        )
        XCTAssertFalse(tombstone.merged(with: restored).isDeleted)
        XCTAssertEqual(tombstone.merged(with: restored).fields["displayName"]?.value, "Restored")
    }

    func testMissingLocalDefaultDoesNotOverwriteRemoteField() {
        let local = SyncDocument(recordName: "configuration", kind: .configuration, fields: [:])
        let remote = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: ["translationProvider": field("deepseek", seconds: 20, device: "tv")]
        )

        XCTAssertEqual(local.merged(with: remote).fields["translationProvider"]?.value, "deepseek")
    }

    func testMergeIsIdempotentAndCodableForOfflineReplay() throws {
        let document = SyncDocument(
            recordName: "podcast-1",
            kind: .podcastSubscription,
            fields: ["displayName": field("Saved offline", seconds: 20, device: "phone")],
            deletionVersion: version(seconds: 10, device: "tv")
        )

        XCTAssertEqual(document.merged(with: document), document)
        let replayed = try JSONDecoder().decode(SyncDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(replayed, document)
    }

    func testPersistencePartitionKeepsConfigurationOutOfOrdinaryStorage() {
        let configuration = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: ["translationAPIKey": field("super-secret", seconds: 20, device: "phone")]
        )
        let subscription = SyncDocument(
            recordName: "podcast-1",
            kind: .podcastSubscription,
            fields: ["displayName": field("Example", seconds: 20, device: "phone")]
        )

        let partition = SyncDocumentPersistencePartition.partition([
            configuration.recordName: configuration,
            subscription.recordName: subscription
        ])

        XCTAssertEqual(partition.secure, [configuration.recordName: configuration])
        XCTAssertEqual(partition.ordinary, [subscription.recordName: subscription])
        XCTAssertFalse(partition.ordinary.values.contains { document in
            document.fields.values.contains { $0.value == "super-secret" }
        })
        XCTAssertEqual(partition.recombined, [
            configuration.recordName: configuration,
            subscription.recordName: subscription
        ])
    }

    func testProviderSwitchFieldsShareOneConflictVersion() {
        let switchVersion = version(seconds: 30, device: "phone")
        let switched = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: [
                "translationProvider": .init(value: "cerebras", version: switchVersion),
                "translationBaseURL": .init(value: "https://api.cerebras.ai/v1", version: switchVersion),
                "translationModelID": .init(value: "gpt-oss-120b", version: switchVersion),
                "translationReasoningEffort": .init(value: "medium", version: switchVersion)
            ]
        )
        let older = SyncDocument(
            recordName: "configuration",
            kind: .configuration,
            fields: [
                "translationProvider": field("deepseek", seconds: 20, device: "tv"),
                "translationBaseURL": field("https://api.deepseek.com", seconds: 20, device: "tv")
            ]
        )

        let merged = older.merged(with: switched)
        XCTAssertEqual(Set(merged.fields.values.map(\.version)), [switchVersion])
        XCTAssertEqual(merged.fields["translationProvider"]?.value, "cerebras")
    }

    func testAccountSwitchRequiresConfirmationButSameAccountProceeds() {
        XCTAssertEqual(SyncAccountPolicy.decision(previousAccountID: "A", currentAccountID: "A"), .proceed)
        XCTAssertEqual(SyncAccountPolicy.decision(previousAccountID: "A", currentAccountID: "B"), .requireConfirmation)
        XCTAssertEqual(SyncAccountPolicy.decision(previousAccountID: nil, currentAccountID: "B"), .proceed)
    }

    func testMissingCloudRecordRecreatesWithoutChangeTagOnlyOnce() {
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .recordMissing,
                hasSystemFields: true,
                isZoneRecoveryQueued: false
            ),
            .recreateRecord
        )
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .recordMissing,
                hasSystemFields: false,
                isZoneRecoveryQueued: false
            ),
            .reportFailure
        )
    }

    func testCloudSaveRecoveryHandlesConflictsTransientErrorsAndMissingZones() {
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .serverRecordChanged,
                hasSystemFields: true,
                isZoneRecoveryQueued: false
            ),
            .mergeServerRecord
        )
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .transient,
                hasSystemFields: true,
                isZoneRecoveryQueued: false
            ),
            .awaitAutomaticRetry
        )
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .zoneMissing,
                hasSystemFields: true,
                isZoneRecoveryQueued: false
            ),
            .recreateZoneAndRetryRecord
        )
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .zoneMissing,
                hasSystemFields: true,
                isZoneRecoveryQueued: true
            ),
            .reportFailure
        )
        XCTAssertEqual(
            CloudRecordSaveRecoveryPolicy.action(
                for: .terminal,
                hasSystemFields: true,
                isZoneRecoveryQueued: false
            ),
            .reportFailure
        )
    }

    func testMissingZoneRecoveryRequeuesEveryRecordButCreatesTheZoneOncePerCycle() {
        let firstAttempt = CloudRecordSaveRecoveryPolicy.plan(
            for: [
                .init(failure: .zoneMissing, hasSystemFields: true),
                .init(failure: .zoneMissing, hasSystemFields: true)
            ],
            isZoneRecoveryQueued: false
        )
        XCTAssertEqual(
            firstAttempt.actions,
            [.recreateZoneAndRetryRecord, .recreateZoneAndRetryRecord]
        )
        XCTAssertTrue(firstAttempt.shouldQueueZoneSave)

        let repeatedAttempt = CloudRecordSaveRecoveryPolicy.plan(
            for: [.init(failure: .zoneMissing, hasSystemFields: true)],
            isZoneRecoveryQueued: true
        )
        XCTAssertEqual(repeatedAttempt.actions, [.reportFailure])
        XCTAssertFalse(repeatedAttempt.shouldQueueZoneSave)
    }

    func testCloudDeleteRecoveryTreatsAlreadyMissingRecordsAsDeleted() {
        XCTAssertEqual(CloudRecordDeleteRecoveryPolicy.action(for: .recordMissing), .acceptAsDeleted)
        XCTAssertEqual(CloudRecordDeleteRecoveryPolicy.action(for: .zoneMissing), .acceptAsDeleted)
        XCTAssertEqual(CloudRecordDeleteRecoveryPolicy.action(for: .transient), .awaitAutomaticRetry)
        XCTAssertEqual(CloudRecordDeleteRecoveryPolicy.action(for: .terminal), .reportFailure)
    }

    func testSubtitleArtifactPodcastIdentityIgnoresLocalEpisodeIDAndNormalizesFeedURL() {
        let first = SubtitleArtifactIdentity.podcast(
            sourceURL: " HTTPS://Example.com/feed/ ",
            episodeGUID: "episode-42",
            target: .simplifiedChinese
        )
        let second = SubtitleArtifactIdentity.podcast(
            sourceURL: "https://example.com/feed#latest",
            episodeGUID: "episode-42",
            target: .simplifiedChinese
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.contentKind, .podcastEpisode)
        XCTAssertTrue(first.recordName.hasPrefix("subtitle-v2-"))
    }

    func testSubtitleArtifactIdentitySeparatesTargetsAndKeepsYouTubeVideoStable() {
        let chinese = SubtitleArtifactIdentity.youtube(videoID: " abc123 ", target: .simplifiedChinese)
        let japanese = SubtitleArtifactIdentity.youtube(videoID: "abc123", target: .japanese)

        XCTAssertEqual(chinese.contentKey, japanese.contentKey)
        XCTAssertEqual(
            chinese.contentKey,
            SubtitleArtifactHash.sha256Hex("youtube-v3\nabc123")
        )
        XCTAssertTrue(chinese.recordName.hasPrefix("subtitle-v3-"))
        XCTAssertNotEqual(chinese.recordName, japanese.recordName)
    }

    func testSubtitleArtifactEnvelopeRequiresCompleteTranslation() throws {
        let identity = SubtitleArtifactIdentity.youtube(videoID: "abc123", target: .simplifiedChinese)
        let complete = SubtitleArtifactEnvelope(
            identity: identity,
            generatedAt: Date(timeIntervalSince1970: 20),
            segments: [segment(translation: "你好")]
        )
        let incomplete = SubtitleArtifactEnvelope(
            identity: identity,
            generatedAt: Date(timeIntervalSince1970: 20),
            segments: [segment(translation: "")]
        )

        XCTAssertTrue(complete.isComplete)
        XCTAssertFalse(incomplete.isComplete)
        let data = try complete.encoded()
        XCTAssertEqual(try SubtitleArtifactEnvelope.validated(data: data, expected: identity), complete)
        XCTAssertThrowsError(try SubtitleArtifactEnvelope.validated(data: data + Data([0]), expected: identity))
    }

    func testSubtitleArtifactPayloadValidatorRejectsHashAndByteCountMismatches() throws {
        let identity = SubtitleArtifactIdentity.youtube(videoID: "abc123", target: .simplifiedChinese)
        let original = SubtitleArtifactEnvelope(
            identity: identity,
            generatedAt: Date(timeIntervalSince1970: 20),
            segments: [segment(translation: "\u{4f60}\u{597d}")]
        )
        let originalData = try original.encoded()
        let metadata = SubtitleArtifactMetadata(
            identity: identity,
            version: version(seconds: 20, device: "phone"),
            sha256: SubtitleArtifactHash.sha256Hex(originalData),
            byteCount: Int64(originalData.count)
        )
        var tampered = original
        tampered.segments[0].translation = "\u{518d}\u{89c1}"
        let tamperedData = try tampered.encoded()

        XCTAssertEqual(originalData.count, tamperedData.count)
        XCTAssertThrowsError(try SubtitleArtifactPayloadValidator.validate(data: tamperedData, metadata: metadata))

        let wrongSize = SubtitleArtifactMetadata(
            identity: identity,
            version: metadata.version,
            sha256: metadata.sha256 ?? "",
            byteCount: Int64(originalData.count + 1)
        )
        XCTAssertThrowsError(try SubtitleArtifactPayloadValidator.validate(data: originalData, metadata: wrongSize))
    }

    func testSubtitleArtifactMetadataUsesVersionOrderingAndTombstonesBlockOldBackfill() {
        let identity = SubtitleArtifactIdentity.youtube(videoID: "abc123", target: .simplifiedChinese)
        let ready = SubtitleArtifactMetadata(
            identity: identity,
            version: version(seconds: 10, device: "phone"),
            sha256: "abc",
            byteCount: 123
        )
        let deletion = SubtitleArtifactMetadata.tombstone(
            identity: identity,
            version: version(seconds: 20, device: "tv")
        )

        XCTAssertEqual(SubtitleArtifactConflictPolicy.preferred(ready, deletion), deletion)
        XCTAssertTrue(deletion.isDeleted)
        let regenerated = SubtitleArtifactMetadata(
            identity: identity,
            version: version(seconds: 30, device: "phone"),
            sha256: "def",
            byteCount: 321
        )
        XCTAssertEqual(SubtitleArtifactConflictPolicy.preferred(deletion, regenerated), regenerated)
    }

    func testLocalArtifactStorageUsesCachesOnTvOSAndApplicationSupportOnIOS() {
        XCTAssertEqual(
            LocalArtifactStoragePolicy.directory(for: .tvOS),
            .cachesDirectory
        )
        XCTAssertEqual(
            LocalArtifactStoragePolicy.directory(for: .iOS),
            .applicationSupportDirectory
        )
    }

    // MARK: - SyncFieldVersion last-writer-wins ordering

    // The playback-progress merge in CloudSyncCoordinator resolves conflicts purely by
    // comparing SyncFieldVersion (newer modifiedAt wins; ties broken by deviceID). These
    // tests pin that ordering so the LWW contract the coordinator relies on cannot regress.
    func testFieldVersionOrdersByModificationDate() {
        let older = version(seconds: 10, device: "phone")
        let newer = version(seconds: 20, device: "phone")

        XCTAssertLessThan(older, newer)
        XCTAssertGreaterThan(newer, older)
        XCTAssertEqual(max(older, newer), newer)
        XCTAssertEqual(min(older, newer), older)
    }

    func testFieldVersionBreaksTiesByDeviceID() {
        let phone = version(seconds: 20, device: "phone")
        let tv = version(seconds: 20, device: "tv")

        // Same timestamp: ordering is deterministic by deviceID, so max() picks "tv".
        XCTAssertNotEqual(phone, tv)
        XCTAssertEqual(max(phone, tv), tv)
        XCTAssertEqual(min(phone, tv), phone)
        XCTAssertEqual(max(tv, phone), tv, "Tie-break must be order-independent")
    }

    func testFieldVersionIsEqualOnlyWhenDateAndDeviceMatch() {
        XCTAssertEqual(version(seconds: 20, device: "phone"), version(seconds: 20, device: "phone"))
        XCTAssertFalse(version(seconds: 20, device: "phone") < version(seconds: 20, device: "phone"))
        XCTAssertFalse(version(seconds: 20, device: "phone") > version(seconds: 20, device: "phone"))
    }

    private func field(_ value: String, seconds: TimeInterval, device: String) -> SyncFieldValue {        SyncFieldValue(value: value, version: version(seconds: seconds, device: device))
    }

    private func version(seconds: TimeInterval, device: String) -> SyncFieldVersion {
        SyncFieldVersion(modifiedAt: Date(timeIntervalSince1970: seconds), deviceID: device)
    }

    private func segment(translation: String) -> LearningSegment {
        LearningSegment(
            sequence: 1,
            startMS: 0,
            endMS: 1_000,
            text: "Hello",
            learningText: "Hello",
            translation: translation
        )
    }
}
