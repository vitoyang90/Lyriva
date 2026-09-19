import Foundation
import SwiftUI

enum ListeningMode: String, CaseIterable, Identifiable {
    case normal, practice
    var id: Self { self }
    var title: String { self == .normal ? "一般播放" : "跟唱模式" }
}

struct FavoriteSong: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let addedAt: Date

    init?(track: SpotifyTrack, date: Date = Date()) {
        guard let id = track.id, !id.isEmpty else { return nil }
        self.id = id
        title = track.name
        artist = track.artists.map(\.name).joined(separator: " · ")
        artworkURL = track.smallArtworkURL
        addedAt = date
    }
}

@MainActor
final class SongLibrary: ObservableObject {
    @Published private(set) var songs: [FavoriteSong] = []
    @Published private(set) var error: String?
    private let file: URL
    private var loaded = false

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Lyriva/favorites.json")) {
        self.file = file
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let decoded = try JSONDecoder().decode([FavoriteSong].self, from: Data(contentsOf: file))
                var seen = Set<String>()
                songs = decoded.filter { seen.insert($0.id).inserted }.sorted { $0.addedAt > $1.addedAt }
            }
            loaded = true
        } catch { self.error = "收藏讀取失敗，請重新開啟 App 再試。" }
    }

    func contains(_ id: String?) -> Bool { songs.contains { $0.id == id } }

    func toggle(_ track: SpotifyTrack) {
        guard let song = FavoriteSong(track: track) else { return }
        if contains(song.id) { remove(song.id) }
        else { save([song] + songs) }
    }

    func remove(_ id: String) { save(songs.filter { $0.id != id }) }

    private func save(_ updated: [FavoriteSong]) {
        // A failed read must not turn into overwriting an existing collection.
        guard loaded else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            songs = updated
            error = nil
        } catch { self.error = "收藏儲存失敗，請稍後再試。" }
    }
}

struct FavoriteSongsView: View {
    @ObservedObject var library: SongLibrary
    let currentTrackID: String?
    let play: (FavoriteSong, ListeningMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selectedSong: FavoriteSong?
    @State private var modeChoiceShown = false

    private var filtered: [FavoriteSong] {
        library.songs.filter { search.isEmpty || ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let error = library.error {
                    Text(error).font(.caption).foregroundStyle(Studio.accent).padding(.horizontal)
                }
                if library.songs.isEmpty {
                    ContentUnavailableView("還沒有收藏", systemImage: "heart",
                        description: Text("播放歌曲時點愛心收藏，下次點歌名，選擇一般播放或跟唱模式。"))
                } else {
                    List {
                        ForEach(filtered) { song in
                            Button { selectedSong = song; modeChoiceShown = true } label: {
                                HStack(spacing: 14) {
                                    AsyncImage(url: song.artworkURL) { image in image.resizable().scaledToFill() }
                                        placeholder: { RecordArtwork() }
                                        .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(song.title).font(.headline).foregroundStyle(Studio.ink).lineLimit(2)
                                        Text(song.artist).font(.caption).foregroundStyle(Studio.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(Studio.accent)
                                }.padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(song.title)，\(song.artist)")
                            .accessibilityHint("選擇一般播放或跟唱模式")
                            .accessibilityIdentifier("favorite-\(song.id)")
                            .accessibilityValue(currentTrackID == song.id ? "目前歌曲" : "")
                            .listRowBackground(Studio.surface)
                            .swipeActions {
                                Button("取消收藏", role: .destructive) { library.remove(song.id) }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                    }
                }
                Text("點選收藏歌曲，再選擇一般播放或跟唱模式")
                    .font(.caption).foregroundStyle(Studio.muted).padding(.bottom, 8)
            }
            .background(Studio.background)
            .navigationTitle("收藏歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜尋收藏歌曲或歌手")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.tint(Studio.accent).preferredColorScheme(.dark)
        .confirmationDialog("選擇播放模式", isPresented: $modeChoiceShown,
                            titleVisibility: .visible, presenting: selectedSong) { song in
            ForEach(ListeningMode.allCases) { mode in
                Button(mode.title) { play(song, mode); selectedSong = nil }
            }
            Button("取消", role: .cancel) { selectedSong = nil }
        } message: { song in
            Text(song.title)
        }
    }
}
