import Foundation

// Spotify owns the queue. Its listening mode lasts for this app session,
// including external skips and temporary empty playback responses.
enum ListeningSession: Equatable {
    case spotify(ListeningMode)
    case favorite(trackID: String, mode: ListeningMode)

    func mode(for trackID: String?) -> ListeningMode {
        switch self {
        case .spotify(let mode): return mode
        case .favorite(let selected, let mode): return selected == trackID ? mode : .normal
        }
    }

    mutating func trackChanged(from previous: String?, to current: String?) {
        if case .favorite(let selected, _) = self, previous == selected, current != selected {
            self = .spotify(.normal)
        }
    }
}
