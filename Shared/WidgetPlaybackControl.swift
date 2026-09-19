import AppIntents
import Foundation
import WidgetKit
import OSLog

enum WidgetPlaybackAction: String, AppEnum {
    case play, pause, previous, next, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "播放操作"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .play: "播放", .pause: "暫停", .previous: "上一首", .next: "下一首", .toggle: "播放或暫停"
    ]

    var method: String {
        switch self {
        case .play, .pause, .toggle: return "PUT"
        case .previous, .next: return "POST"
        }
    }
}

enum WidgetPlaybackControlError: LocalizedError {
    case unavailableDevice, restricted, premiumRequired, missingScope, failed

    var errorDescription: String? {
        switch self {
        case .unavailableDevice: return "請先在 Spotify 開始播放，再試一次。"
        case .restricted: return "Spotify 目前不允許此播放操作。"
        case .premiumRequired: return "此操作需要 Spotify Premium。"
        case .missingScope: return "請重新連接 Spotify，授予播放控制權限。"
        case .failed: return "播放操作未完成，請稍後再試。"
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? AuthorizationError { return error.localizedDescription }
        if let error = error as? Self { return error.localizedDescription }
        if error is WidgetSpotifyClient.RateLimit { return "操作過於頻繁，請稍後再試。" }
        return Self.failed.localizedDescription
    }
}

struct WidgetPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "控制 Spotify 播放"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "操作") var action: WidgetPlaybackAction
    @Parameter(title: "登入識別") var authorizationID: String

    init() {}
    init(action: WidgetPlaybackAction, authorizationID: UUID?) {
        self.action = action
        self.authorizationID = authorizationID?.uuidString ?? ""
    }

    func perform() async throws -> some IntentResult {
        guard let sessionID = UUID(uuidString: authorizationID) else { throw AuthorizationError.signedOut }
        let storage = WidgetSnapshotStorage()
        let logger = Logger(subsystem: "order.SpotifyTrans", category: "WidgetPlayback")
        logger.info("Widget playback action received: \(action.rawValue, privacy: .public)")
        do {
            let client = WidgetSpotifyClient()
            let control = WidgetPlaybackController(storage: storage, command: {
                try await client.command($0, sessionID: $1)
            }, playback: { try await client.playback() }, stateChanged: {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
            })
            try await control.perform(action, sessionID: sessionID)
            logger.info("Widget playback command completed")
        } catch {
            logger.error("Widget playback command failed: \(WidgetPlaybackControlError.message(for: error), privacy: .public)")
            // The controller has already published this command's error. Always
            // reconcile: a timeout/error response does not prove playback stayed put.
            if error is WidgetSpotifyClient.RateLimit {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
                return .result()
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
        // The command lock has been released. Publish its local state first,
        // then fetch the new song now instead of relying on a budgeted timer.
        _ = await WidgetTimelineLoader().load(forceRefresh: true)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
        return .result()
    }
}

struct WidgetPlaybackController {
    let storage: WidgetSnapshotStorage
    var lockDirectory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSongSnapshot.appGroup)
    var command: (WidgetPlaybackAction, UUID) async throws -> Void
    var playback: (() async throws -> WidgetPlaybackState?)? = nil
    var stateChanged: () -> Void = {}
    var confirmationDelay: Duration = .milliseconds(350)

    func perform(_ requestedAction: WidgetPlaybackAction, sessionID: UUID) async throws {
        // Confirm the command before allowing the next command through. Slow
        // lyrics/artwork never hold this cross-process lock.
        let lock = try SharedFileLock(name: "widget-playback-control.lock", directory: lockDirectory)
        try await lock.acquire(attempts: 200)
        defer { withExtendedLifetime(lock) {} }
        let previous = storage.read()
        let action: WidgetPlaybackAction
        if requestedAction == .toggle {
            guard let previous, previous.authorizationID == sessionID else { throw AuthorizationError.signedOut }
            // A widget can still be displaying its previous timeline. Resolve
            // each tap from shared state after the preceding command finishes.
            action = previous.playbackIsPlaying ? .pause : .play
        } else { action = requestedAction }
        try await mutateStorage {
            try storage.updateAfterControl(action, at: Date(), sessionID: sessionID, inFlight: true)
        }
        let pending = storage.read()
        stateChanged()
        var commandError: Error?
        do { try await command(action, sessionID) }
        catch { commandError = error }

        var confirmed: WidgetPlaybackState?
        var lastObserved: WidgetPlaybackState?
        if let playback, !(commandError is WidgetSpotifyClient.RateLimit) {
            let deadline = Date().addingTimeInterval(4)
            for attempt in 0..<6 {
                do {
                    let state = try await playback()
                    lastObserved = state
                    if let state, pending?.acceptsPlayback(state, at: pending?.updatedAt ?? Date()) != false {
                        confirmed = state
                        break
                    }
                    if Date() >= deadline { break }
                    if attempt < 5 { try await Task.sleep(for: confirmationDelay) }
                } catch { break }
            }
        }
        // A confirmed effect takes precedence over a failed/ambiguous HTTP response.
        if confirmed != nil { commandError = nil }
        try await mutateStorage {
            try storage.finishControl(controlID: pending?.controlID,
                state: confirmed ?? (commandError != nil ? lastObserved : nil),
                errorMessage: commandError.map(WidgetPlaybackControlError.message), sessionID: sessionID,
                fallbackIsPlaying: action == .play || action == .pause ? previous?.playbackIsPlaying : nil)
        }
        stateChanged()
        if let commandError { throw commandError }
    }

    private func mutateStorage(_ operation: () throws -> Void) async throws {
        for attempt in 0..<10 {
            do { try operation(); return }
            catch AuthorizationError.busy where attempt < 9 { try await Task.sleep(for: .milliseconds(50)) }
        }
    }
}
