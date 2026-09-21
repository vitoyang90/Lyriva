import SwiftUI

/// Only navigation choices live in defaults. Credentials remain in Keychain.
@MainActor
final class OnboardingStore: ObservableObject {
    enum Step: String, Codable, CaseIterable {
        case welcome, spotify, lyrics, ready, completed
    }
    enum LyricsChoice: String, Codable { case pending, enabled, deferred }
    enum PlaybackAccess { case missing, authorized, reauthorizationRequired, unavailable }
    enum LyricsAccess { case missing, saved, unavailable }

    private struct Progress: Codable {
        var step: Step = .welcome
        var lyricsChoice: LyricsChoice = .pending
        var completedVersion: Int = 0
    }
    static let storageKey = "lyriva.onboarding.progress"
    @Published private var progress: Progress
    @Published private(set) var launchResolved = false
    @Published private(set) var lyricsAccess: LyricsAccess = .missing
    private let defaults: UserDefaults
    private var hadSavedProgress: Bool
    private var playbackAccess: PlaybackAccess = .unavailable

    var step: Step { progress.step }
    var lyricsChoice: LyricsChoice { progress.lyricsChoice }
    var isComplete: Bool { progress.completedVersion > 0 }
    var playbackUnavailable: Bool { playbackAccess == .unavailable }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Progress.self, from: $0) }
        progress = saved ?? Progress()
        hadSavedProgress = saved != nil
    }

    func reconcile(playback: PlaybackAccess, lyrics: LyricsAccess) {
        playbackAccess = playback
        lyricsAccess = lyrics
        // A completed tour stays completed after logout or a temporary storage failure.
        if isComplete { launchResolved = true; return }
        if !launchResolved {
            // Do not turn an unreadable existing login into a fresh installation.
            guard playback != .unavailable else { return }
            if !hadSavedProgress, playback == .authorized || playback == .reauthorizationRequired {
                progress.step = .completed
                progress.completedVersion = 1
            }
            launchResolved = true
            persist()
        }
        guard !isComplete, playback != .unavailable else { return }
        if playback != .authorized {
            if step == .lyrics || step == .ready { progress.step = .spotify }
        } else if step == .spotify {
            progress.step = progress.lyricsChoice == .deferred ? .ready : .lyrics
        }
        if step == .lyrics, lyrics == .saved {
            progress.lyricsChoice = .enabled
            progress.step = .ready
        } else if step == .ready, progress.lyricsChoice == .enabled, lyrics == .missing {
            progress.lyricsChoice = .pending
            progress.step = .lyrics
        }
        persist()
    }

    func begin() {
        guard step == .welcome else { return }
        progress.step = .spotify
        persist()
        reconcile(playback: playbackAccess, lyrics: lyricsAccess)
    }

    func deferLyrics() {
        guard step == .lyrics, playbackAccess == .authorized else { return }
        progress.lyricsChoice = .deferred
        progress.step = .ready
        persist()
    }

    func finish() {
        guard step == .ready, playbackAccess == .authorized else { return }
        progress.step = .completed
        progress.completedVersion = 1
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.storageKey)
        hadSavedProgress = true
    }
}
