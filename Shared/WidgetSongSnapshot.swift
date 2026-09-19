import Foundation

struct WidgetSongSnapshot: Codable, Equatable, Sendable {
    static let kind = "SpotifyTransLyrics"
    static let appGroup = "group.order.SpotifyTrans"
    static let freshness: TimeInterval = 15 * 60
    let trackID: String
    let title: String
    let artist: String
    var original: String?
    var romanization: String?
    var nextOriginal: String?
    var nextRomanization: String?
    var updatedAt: Date
    var artwork: Data?
    var playback: PlaybackPlan?
    var playbackEndsAt: Date?
    var notice: String?
    var authorizationID: UUID?
    var isPlaying: Bool?
    var controlError: String?
    var needsPlaybackRefresh: Bool?
    var needsControlPresentation: Bool?
    var pendingPlaybackAction: String?
    // Retain the operation identity after confirmation, including while lyrics load.
    var controlID: UUID?
    var controlInFlight: Bool?
    var durationMS: Int?
    var positionMS: Double?

    var isControlInFlight: Bool {
        controlInFlight == true && Date().timeIntervalSince(updatedAt) < 30
    }

    func acceptsPlayback(_ state: WidgetPlaybackState?, at date: Date) -> Bool {
        guard let action = pendingPlaybackAction, date.timeIntervalSince(updatedAt) < 10 else { return true }
        guard let state else { return false }
        switch action {
        case "pause": return !state.isPlaying
        case "play": return state.isPlaying
        case "next": return state.track.id != trackID
        case "previous": return state.track.id != trackID || state.positionMS < 1500
        default: return true
        }
    }

    var playbackIsPlaying: Bool { isPlaying ?? (playback?.isValid == true || playbackEndsAt != nil) }

    struct PlaybackPlan: Codable, Equatable, Sendable {
        struct Line: Codable, Equatable, Sendable {
            let startMS: Double
            let original: String
            let romanization: String?
        }
        let sampledAt: Date
        let positionMS: Double
        let durationMS: Double
        let lines: [Line]

        var isValid: Bool {
            positionMS.isFinite && positionMS >= 0 && durationMS.isFinite && durationMS > positionMS
                && sampledAt.timeIntervalSince1970.isFinite && !lines.isEmpty
                && lines.allSatisfy { $0.startMS.isFinite && $0.startMS >= 0 && $0.startMS < durationMS }
                && zip(lines, lines.dropFirst()).allSatisfy { $0.startMS <= $1.startMS }
        }
        func date(for milliseconds: Double) -> Date { sampledAt.addingTimeInterval((milliseconds - positionMS) / 1000) }
    }

    var expiresAt: Date {
        let freshnessEnd = min(updatedAt.addingTimeInterval(Self.freshness), playbackEndsAt ?? .distantFuture)
        guard let playback, playback.isValid else { return freshnessEnd }
        return min(freshnessEnd, playback.date(for: playback.durationMS))
    }
    func isExpired(at date: Date) -> Bool { date >= expiresAt }

    func lyrics(at date: Date) -> Self {
        guard let playback, playback.isValid else { return self }
        var displayed = self
        let position = playback.positionMS + max(0, date.timeIntervalSince(playback.sampledAt)) * 1000
        let index = playback.lines.lastIndex { $0.startMS <= position }
        let current = index.map { playback.lines[$0] }
        let nextIndex = index.map { $0 + 1 } ?? 0
        let next = playback.lines.indices.contains(nextIndex) ? playback.lines[nextIndex] : nil
        displayed.original = current?.original
        displayed.romanization = current?.romanization
        displayed.nextOriginal = next?.original
        displayed.nextRomanization = next?.romanization
        return displayed
    }

    // These are requested presentation times. WidgetKit may delay or coalesce entries.
    func presentationDates(after now: Date) -> [Date] {
        guard !isExpired(at: now) else { return [now] }
        var dates = [now, expiresAt]
        if let playback, playback.isValid {
            dates += playback.lines.map { playback.date(for: $0.startMS) }.filter { $0 > now && $0 < expiresAt }
        }
        return Array(Set(dates)).sorted()
    }
}

struct WidgetSnapshotStorage {
    private let directory: URL?
    private let sessionStorage: any SpotifySessionStorage
    init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSongSnapshot.appGroup),
         sessionStorage: any SpotifySessionStorage = KeychainSessionStorage()) {
        self.directory = directory
        self.sessionStorage = sessionStorage
    }
    private var file: URL? { directory?.appendingPathComponent("current-song.json") }
    func read() -> WidgetSongSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSongSnapshot.self, from: data)
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        let lock = try SharedFileLock(name: "current-song.lock", directory: directory)
        guard try lock.tryAcquire() else { throw AuthorizationError.busy }
        defer { withExtendedLifetime(lock) {} }
        return try operation()
    }
    private func writeFile(_ snapshot: WidgetSongSnapshot) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func write(_ snapshot: WidgetSongSnapshot) throws {
        try locked {
            // Late artwork or a suspended app must not replace a newer playback sample.
            if let current = read() {
                guard snapshot.controlID == current.controlID else { return }
                if current.updatedAt > snapshot.updatedAt || current.isControlInFlight { return }
                if current.pendingPlaybackAction != nil, Date().timeIntervalSince(current.updatedAt) < 10 { return }
            }
            try writeFile(snapshot)
        }
    }
    func updateFromWidget(_ snapshot: WidgetSongSnapshot?, observedAt: Date, sessionID: UUID,
                          controlID: UUID? = nil) throws -> WidgetSongSnapshot? {
        try locked {
            guard try sessionStorage.read()?.id == sessionID else { return nil }
            let current = read()
            guard current?.controlID == controlID, current?.isControlInFlight != true else { return current }
            if let current, current.updatedAt > (snapshot?.updatedAt ?? observedAt) { return current }
            if let snapshot { try writeFile(snapshot) }
            else { try removeFile() }
            return snapshot
        }
    }
    func updateAfterControl(_ action: WidgetPlaybackAction?, errorMessage: String? = nil,
                            at date: Date, sessionID: UUID, inFlight: Bool = false) throws {
        try locked {
            guard try sessionStorage.read()?.id == sessionID,
                  var song = read(), song.authorizationID == sessionID else { return }
            song.controlError = errorMessage
            song.needsControlPresentation = true
            if let action {
                // A newer playback response already knows more than this command.
                guard song.updatedAt <= date else { return }
                song = song.lyrics(at: date)
                if let position = song.positionMS, let duration = song.durationMS, song.playbackIsPlaying {
                    song.positionMS = min(Double(duration), position + max(0, date.timeIntervalSince(song.updatedAt)) * 1000)
                }
                song.playback = nil
                song.playbackEndsAt = nil
                song.updatedAt = date
                song.needsPlaybackRefresh = true
                song.pendingPlaybackAction = action.rawValue
                song.controlID = UUID()
                song.controlInFlight = inFlight
                switch action {
                case .toggle: throw WidgetPlaybackControlError.failed // Resolve under the command lock first.
                case .pause: song.isPlaying = false
                case .play: song.isPlaying = true
                case .previous, .next:
                    song.positionMS = nil
                    song.original = nil
                    song.romanization = nil
                    song.nextOriginal = nil
                    song.nextRomanization = nil
                    song.playbackEndsAt = date
                }
            }
            try writeFile(song)
        }
    }

    // Only this command may finish its own state. Network/lyrics responses use
    // updateFromWidget and must also match this identity after the lock is released.
    func finishControl(controlID: UUID?, state: WidgetPlaybackState?, errorMessage: String?,
                       sessionID: UUID, fallbackIsPlaying: Bool? = nil) throws {
        try locked {
            guard try sessionStorage.read()?.id == sessionID,
                  var song = read(), song.authorizationID == sessionID,
                  song.controlID == controlID else { return }
            if let state, var confirmed = WidgetSongSnapshot.snapshot(track: state.track, document: nil,
                readings: [:], position: state.positionMS, date: state.sampledAt) {
                if song.trackID == confirmed.trackID {
                    confirmed.original = song.original
                    confirmed.romanization = song.romanization
                    confirmed.artwork = song.artwork
                }
                confirmed.authorizationID = sessionID
                confirmed.controlID = controlID
                confirmed.isPlaying = state.isPlaying
                confirmed.playbackEndsAt = state.endsAt
                confirmed.needsPlaybackRefresh = true
                song = confirmed
            } else if errorMessage != nil, let fallbackIsPlaying {
                // A rejected toggle must not leave its optimistic icon stuck.
                // Keep lyrics frozen until the next authoritative playback read.
                song.isPlaying = fallbackIsPlaying
                song.pendingPlaybackAction = nil
            }
            song.controlInFlight = false
            song.controlError = errorMessage
            song.needsControlPresentation = true
            try writeFile(song)
        }
    }
    func consumeControlPresentation(sessionID: UUID) throws -> WidgetSongSnapshot? {
        try locked {
            guard try sessionStorage.read()?.id == sessionID,
                  var song = read(), song.authorizationID == sessionID,
                  song.needsControlPresentation == true else { return nil }
            song.needsControlPresentation = nil
            try writeFile(song)
            return song
        }
    }
    private func removeFile() throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func clear() throws { try locked { try removeFile() } }

    func clearPlayback(controlID: UUID?) throws -> Bool {
        try locked {
            let current = read()
            guard current?.controlID == controlID, current?.isControlInFlight != true else { return false }
            try removeFile()
            return true
        }
    }

}

extension WidgetSongSnapshot {
    static func snapshot(track: SpotifyTrack, document: LyricsDocument?, readings: [Int: String],
                         position: Double?, date: Date = Date()) -> WidgetSongSnapshot? {
        guard let id = track.id else { return nil }
        let index: Int?
        if let document, document.isSynced {
            let active = position.flatMap { document.activeLine(at: $0) }
            index = document.lines.firstIndex { $0.id == active }
        } else { index = document?.lines.firstIndex { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let line = index.flatMap { document?.lines[$0] }
        let next = index.flatMap { i -> LyricsDocument.Line? in
            guard let document, document.lines.indices.contains(i + 1) else { return nil }
            return document.lines[i + 1]
        }
        // Bound the shared payload even if a provider returns unusually long metadata or lyrics.
        func clipped(_ text: String?) -> String? { text.map { String($0.prefix(240)) } }
        return WidgetSongSnapshot(trackID: id, title: String(track.name.prefix(120)),
                                  artist: String(track.artists.map(\.name).joined(separator: " · ").prefix(160)),
                                  original: clipped(line?.words), romanization: clipped(line.flatMap { readings[$0.id] }),
                                  nextOriginal: clipped(next?.words), nextRomanization: clipped(next.flatMap { readings[$0.id] }),
                                  updatedAt: date, durationMS: track.duration_ms, positionMS: position)
    }

    static func plan(track: SpotifyTrack, document: LyricsDocument, readings: [Int: String],
                     sampledAt: Date, position: Double) -> PlaybackPlan? {
        let duration = Double(track.duration_ms)
        let lines = document.lines.compactMap { line -> WidgetSongSnapshot.PlaybackPlan.Line? in
            guard let start = line.startTimeMS, start < duration else { return nil }
            return .init(startMS: start, original: String(line.words.prefix(240)),
                         romanization: readings[line.id].map { String($0.prefix(240)) })
        }
        // Keep the current line plus future lines, bounded to the current song only.
        let current = lines.lastIndex { $0.startMS <= position } ?? 0
        let remaining = Array(lines.dropFirst(current).prefix(256))
        let cutoff = current + remaining.count
        let plannedEnd = lines.indices.contains(cutoff) ? min(duration, lines[cutoff].startMS) : duration
        let plan = WidgetSongSnapshot.PlaybackPlan(sampledAt: sampledAt, positionMS: position,
                                                   durationMS: plannedEnd, lines: remaining)
        return plan.isValid ? plan : nil
    }
}
