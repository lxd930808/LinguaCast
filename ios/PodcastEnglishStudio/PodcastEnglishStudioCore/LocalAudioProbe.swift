import Foundation

/// Distinguishes a real audio file from an HTML episode page that was saved as `source.mp3`.
public enum LocalAudioProbe: Sendable {
    /// Hosts that are episode pages, not enclosures. Repairing from these yields HTML.
    public static let webpageHosts: Set<String> = [
        "podcasts.apple.com",
        "itunes.apple.com",
        "music.apple.com"
    ]

    public static func isPlayableEnclosureURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        if webpageHosts.contains(host) { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    public static func looksLikeAudioFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 16)) ?? Data()
        return looksLikeAudioMagic(prefix)
    }

    public static func looksLikeAudioMagic(_ prefix: Data) -> Bool {
        guard prefix.count >= 3 else { return false }
        if prefix.starts(with: Array("ID3".utf8)) { return true }
        if prefix.starts(with: Array("OggS".utf8)) { return true }
        if prefix.starts(with: Array("fLaC".utf8)) { return true }
        if prefix.starts(with: Array("RIFF".utf8)) { return true }
        if prefix.count >= 8 {
            let brand = prefix.subdata(in: 4..<8)
            if brand == Data("ftyp".utf8) { return true }
        }
        // MPEG frame sync: 0xFFE? or 0xFFF?
        if prefix[0] == 0xFF, prefix[1] & 0xE0 == 0xE0 { return true }
        return false
    }
}
