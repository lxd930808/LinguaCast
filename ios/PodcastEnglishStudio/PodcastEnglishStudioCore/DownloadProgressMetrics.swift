import Foundation

public enum DownloadProgressMetrics {
    public static func fraction(completedBytes: Int64, expectedBytes: Int64) -> Double? {
        guard completedBytes >= 0, expectedBytes > 0 else { return nil }
        return min(max(Double(completedBytes) / Double(expectedBytes), 0), 1)
    }

    public static func bytesPerSecond(bytesDelta: Int64, elapsedSeconds: TimeInterval) -> Double? {
        guard bytesDelta >= 0, elapsedSeconds > 0 else { return nil }
        return Double(bytesDelta) / elapsedSeconds
    }

    public static func smoothedBytesPerSecond(
        previous: Double?,
        sample: Double,
        sampleWeight: Double = 0.25
    ) -> Double {
        guard let previous else { return max(sample, 0) }
        let weight = min(max(sampleWeight, 0), 1)
        return max(previous * (1 - weight) + sample * weight, 0)
    }
}

public enum SourceGenerationStateRecoveryPolicy {
    public static func shouldClear(step: String?, subtitleStatus: String) -> Bool {
        guard step != nil else { return false }
        return subtitleStatus == "failed" || subtitleStatus == "ready"
    }
}
