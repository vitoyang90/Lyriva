import SwiftUI

struct ContentView: View {
    @StateObject private var spotify: SpotifyConnection
    @StateObject private var phoneLyrics: PhoneLyricsStore
    @StateObject private var widgetPublisher = WidgetSnapshotPublisher()
    @StateObject private var library: SongLibrary
    @State private var listeningSession = ListeningSession.spotify(.normal)
    private var listeningMode: ListeningMode {
        listeningSession.mode(for: spotify.track?.id)
    }
    @State private var favoritesShown = false
    @State private var settingsShown = false
    @State private var loginShown = false
    @State private var checkedSavedLogin = false
    @State private var loginRevision = 0
    @Environment(\.scenePhase) private var scenePhase
    private let publishesWidgets: Bool

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--landscape-ui-fixture") {
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

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height && geometry.size.width >= 600
                let layout = landscape
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                ScrollView(landscape ? [] : .vertical) {
                    layout {
                        Group {
                            if landscape {
                                ScrollView {
                                    playerColumn(compact: true)
                                }.scrollIndicators(.hidden)
                            } else {
                                playerColumn(compact: false)
                            }
                        }
                        .frame(width: landscape ? min(320, max(260, geometry.size.width * 0.34)) : nil)
                        if spotify.connected || landscape {
                            SyncedLyricsView(spotify: spotify, store: phoneLyrics, loginRevision: loginRevision,
                                             landscape: landscape, listeningMode: listeningMode) { loginShown = true }
                                .frame(maxWidth: .infinity, maxHeight: landscape ? .infinity : nil, alignment: .top)
                        }
                    }
                    .padding(.horizontal, landscape ? 16 : 22)
                    .padding(.top, landscape ? 8 : 18)
                    .padding(.bottom, landscape ? 8 : 24)
                    .frame(maxWidth: landscape ? .infinity : 620)
                    .frame(height: landscape ? geometry.size.height : nil, alignment: .top)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier(landscape ? "landscape-player" : "portrait-player")
            }
            .background(Studio.background.ignoresSafeArea())
            .navigationTitle("Lyriva")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $settingsShown) {
                ConnectionSettingsView(spotify: spotify, lyrics: phoneLyrics) {
                    phoneLyrics.loginDidChange()
                    loginRevision += 1
                }
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
                phoneLyrics.loginDidChange()
                loginRevision += 1
            }
        }
        .onAppear {
            guard !checkedSavedLogin else { return }
            checkedSavedLogin = true
            loginShown = !spotify.connected || spotify.requiresReauthorization
        }
        .onOpenURL { url in
            if url.scheme == "spotifytrans", url.host == "lyrics" {
                settingsShown = false
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
            if publishesWidgets, phase != .active { widgetPublisher.update(spotify: spotify, lyrics: phoneLyrics, force: true) }
        }
        .onChange(of: spotify.track?.id) { previous, current in
            listeningSession.trackChanged(from: previous, to: current)
        }
        .onChange(of: spotify.connected) { _, connected in
            if !connected { listeningSession = .spotify(.normal) }
            if publishesWidgets, !connected { widgetPublisher.clear() }
        }
        .task(id: scenePhase == .active) {
            guard publishesWidgets, scenePhase == .active else { return }
            while !Task.isCancelled {
                widgetPublisher.update(spotify: spotify, lyrics: phoneLyrics)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: "\(spotify.connected)-\(scenePhase == .active)") {
            if scenePhase == .active { spotify.restoreSavedSession() }
            guard spotify.connected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await spotify.refresh(showActivity: false)
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func playerColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 28) {
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
            SpotifyConnectionView(spotify: spotify, starter: spotify.playbackStarter, compact: compact,
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
