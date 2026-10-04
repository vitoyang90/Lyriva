import SwiftUI

struct ContentView: View {
    @StateObject private var spotify: SpotifyConnection
    @StateObject private var phoneLyrics: PhoneLyricsStore
    @StateObject private var widgetPublisher = WidgetSnapshotPublisher()
    @StateObject private var library: SongLibrary
    @StateObject private var onboarding = OnboardingStore()
    @State private var listeningSession = ListeningSession.spotify(.normal)
    private var listeningMode: ListeningMode {
        listeningSession.mode(for: spotify.track?.id)
    }
    @State private var lyricsExpanded = false
    @State private var playerExpanded = false
    @State private var favoritesShown = false
    @State private var settingsShown = false
    @State private var loginShown = false
    @State private var lyricsLoginShown = false
    @State private var loginRevision = 0
    @Environment(\.scenePhase) private var scenePhase
    private let publishesWidgets: Bool

    init() {
        #if DEBUG
        if let fixture = OnboardingUITestFixture.current {
            _onboarding = StateObject(wrappedValue: OnboardingStore(defaults: fixture.defaults))
            _spotify = StateObject(wrappedValue: fixture.connection())
            _phoneLyrics = StateObject(wrappedValue: PhoneLyricsStore(fetch: { _ in throw LyricsError.authenticationRequired }))
            _library = StateObject(wrappedValue: SongLibrary(file: FileManager.default.temporaryDirectory
                .appendingPathComponent("onboarding-favorites-\(UUID().uuidString).json")))
            publishesWidgets = false
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--landscape-ui-fixture") {
            let defaults = UserDefaults(suiteName: "lyriva.player-fixture.\(UUID().uuidString)")!
            let onboarding = OnboardingStore(defaults: defaults)
            onboarding.reconcile(playback: .authorized, lyrics: .saved)
            _onboarding = StateObject(wrappedValue: onboarding)
            _spotify = StateObject(wrappedValue: LandscapeUITestFixture.connection())
            _phoneLyrics = StateObject(wrappedValue: PhoneLyricsStore(
                preferences: ReadingPreferences(file: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ui-readings-\(UUID().uuidString).json")),
                fetch: { LandscapeUITestFixture.document(for: $0) }))
            let library = SongLibrary(file: FileManager.default.temporaryDirectory
                .appendingPathComponent("ui-favorites-\(UUID().uuidString).json"))
            if ProcessInfo.processInfo.arguments.contains("--favorite-playback-ui-fixture") {
                library.toggle(SpotifyTrack(id: "favorite-fixture-song", duration_ms: 180000,
                    name: "Favorite Session", artists: [.init(name: "Lyriva Studio")],
                    external_urls: .init(spotify: nil), album: nil))
            }
            _library = StateObject(wrappedValue: library)
            publishesWidgets = false
            return
        }
        #endif
        _spotify = StateObject(wrappedValue: SpotifyConnection())
        _phoneLyrics = StateObject(wrappedValue: PhoneLyricsStore())
        _library = StateObject(wrappedValue: SongLibrary())
        publishesWidgets = true
    }

    private var player: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Use the available canvas, including iPad split view, rather than device orientation.
                let landscape = geometry.size.width > geometry.size.height && geometry.size.width >= 600
                let layout = landscape
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                layout {
                    if !lyricsExpanded {
                        playerColumn(compact: landscape || geometry.size.height < 700,
                                     artworkSize: landscape ? 40 : (geometry.size.height < 700 ? 80 : 100))
                            .frame(width: landscape ? min(340, max(260, geometry.size.width * 0.36)) : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .geometryGroup()
                            .transition(.opacity)
                    }
                    SyncedLyricsView(spotify: spotify, store: phoneLyrics, loginRevision: loginRevision,
                                     expanded: $lyricsExpanded, playerExpanded: playerExpanded,
                                     landscape: landscape, listeningMode: listeningMode,
                                     readerVisible: !settingsShown && !favoritesShown && !loginShown && !lyricsLoginShown,
                                     lyricsSetupNeeded: onboarding.lyricsAccess == .missing && !phoneLyrics.needsLogin) {
                        lyricsLoginShown = true
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .safeAreaInset(edge: .bottom, spacing: 8) {
                    if lyricsExpanded, spotify.connected {
                        PlaybackTransport(spotify: spotify, starter: spotify.playbackStarter, buttonSize: 48)
                            .padding(.vertical, 8)
                            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("expanded-lyrics-controls")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, landscape ? 16 : 18)
                .padding(.vertical, 8)
                .frame(maxWidth: landscape ? .infinity : 720, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(landscape ? "landscape-player" : "portrait-player")
            }
            .background(Studio.background.ignoresSafeArea())
            .navigationTitle("Lyriva")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $settingsShown) {
                ConnectionSettingsView(spotify: spotify, lyrics: phoneLyrics) {
                    lyricsLoginChanged()
                }
            }
        }
    }

    var body: some View {
        Group {
            if onboarding.isComplete {
                player
            } else if onboarding.launchResolved {
                OnboardingView(store: onboarding, spotify: spotify,
                               onLyricsLogin: lyricsLoginChanged, refreshAccess: reconcileOnboarding)
            } else {
                VStack(spacing: 20) {
                    Text("正在恢復設定").font(.title2.bold())
                    Text(spotify.status).foregroundStyle(Studio.muted)
                    Button("重試讀取登入資料", action: reconcileOnboarding).buttonStyle(StudioButton())
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Studio.background.ignoresSafeArea())
            }
        }
        .foregroundStyle(Studio.ink).tint(Studio.accent).preferredColorScheme(.dark)
        .sheet(isPresented: $favoritesShown) {
            FavoriteSongsView(library: library, currentTrackID: spotify.track?.id) { song, mode in
                PlaybackDiagnostics.record("favorite selected track=\(song.id) mode=\(mode.rawValue)")
                favoritesShown = false
                guard spotify.connected, !spotify.requiresReauthorization else { loginShown = true; return }
                listeningSession = .favorite(trackID: song.id, mode: mode)
                Task { await spotify.playTrack(id: song.id) }
            }
        }
        .fullScreenCover(isPresented: $loginShown) {
            SpotifyLoginView(spotify: spotify, lyrics: phoneLyrics) {
                lyricsLoginChanged()
            }
        }
        .sheet(isPresented: $lyricsLoginShown, onDismiss: reconcileOnboarding) {
            SpotifyWebLogin { lyricsLoginChanged() }
        }
        .onAppear(perform: reconcileOnboarding)
        .onOpenURL { url in
            if url.scheme == "spotifytrans", url.host == "lyrics" {
                settingsShown = false
                guard onboarding.isComplete else { return }
                Task { await spotify.openFromWidget() }
                return
            }
            if spotify.playbackStarter.handleCallback(url) {
                Task { await spotify.refresh(showActivity: false) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            PlaybackDiagnostics.record("scene phase=\(phase)")
            spotify.playbackStarter.sceneChanged(phase)
            if phase == .active { reconcileOnboarding() }
            if publishesWidgets, onboarding.isComplete, phase != .active { widgetPublisher.update(spotify: spotify, lyrics: phoneLyrics, force: true) }
        }
        .onChange(of: spotify.track?.id) { previous, current in
            listeningSession.trackChanged(from: previous, to: current)
        }
        .onChange(of: spotify.connected) { _, connected in
            reconcileOnboarding()
            if !connected { listeningSession = .spotify(.normal) }
            if publishesWidgets, !connected { widgetPublisher.clear() }
        }
        .onChange(of: spotify.requiresReauthorization) { _, _ in reconcileOnboarding() }
        .onChange(of: phoneLyrics.needsLogin) { _, _ in reconcileOnboarding() }
        .task(id: "\(onboarding.isComplete)-\(scenePhase == .active)") {
            guard publishesWidgets, onboarding.isComplete, scenePhase == .active else { return }
            while !Task.isCancelled {
                widgetPublisher.update(spotify: spotify, lyrics: phoneLyrics)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: "\(onboarding.isComplete)-\(spotify.connected)-\(scenePhase == .active)") {
            guard onboarding.isComplete, spotify.connected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await spotify.refresh(showActivity: false)
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func lyricsLoginChanged() {
        phoneLyrics.loginDidChange()
        loginRevision += 1
        reconcileOnboarding()
    }

    private func reconcileOnboarding() {
        spotify.restoreSavedSession()
        let playback: OnboardingStore.PlaybackAccess = spotify.savedSessionUnavailable ? .unavailable
            : (spotify.requiresReauthorization ? .reauthorizationRequired : (spotify.connected ? .authorized : .missing))
        let lyrics: OnboardingStore.LyricsAccess
        #if DEBUG
        if let fixture = OnboardingUITestFixture.current {
            onboarding.reconcile(playback: playback, lyrics: fixture.lyricsSaved ? .saved : .missing)
            return
        }
        #endif
        if !publishesWidgets {
            lyrics = .saved
        } else {
            do { lyrics = try LyricsCredential.readIfPresent() != nil && !phoneLyrics.needsLogin ? .saved : .missing }
            catch { lyrics = .unavailable }
        }
        onboarding.reconcile(playback: playback, lyrics: lyrics)
    }

    private func playerColumn(compact: Bool, artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                Image("LyrivaMark").resizable().scaledToFit()
                    .frame(width: compact ? 28 : 40, height: compact ? 28 : 40)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
                    .accessibilityHidden(true)
                Text("Lyriva").font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Button { favoritesShown = true } label: {
                    Image(systemName: "heart.text.clipboard").font(.system(size: 19))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("收藏歌曲").accessibilityIdentifier("open-favorites")
                IconButton(symbol: "slider.horizontal.3", label: "設定") { settingsShown = true }
            }
            SpotifyConnectionView(spotify: spotify, starter: spotify.playbackStarter, expanded: $playerExpanded,
                compact: compact, artworkSize: artworkSize,
                listeningSession: listeningSession, setListeningMode: { mode in
                    listeningSession = .spotify(mode)
                },
                isFavorite: library.contains(spotify.track?.id), toggleFavorite: {
                    if let track = spotify.track { library.toggle(track) }
                }) { loginShown = true }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(Studio.accent) }
            if let error = widgetPublisher.error {
                Text(error).font(.caption).foregroundStyle(Studio.muted)
            }
        }
    }

}

#Preview { ContentView() }
