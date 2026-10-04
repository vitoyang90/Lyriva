import SwiftUI
import UIKit

/// Each visible reader owns a request so one window cannot cancel another's request.
@MainActor
final class ReadingScreenAwake {
    static let preferenceKey = "lyricsKeepScreenAwake"
    static let shared = ReadingScreenAwake { UIApplication.shared.isIdleTimerDisabled = $0 }

    private var readers: Set<UUID> = []
    private let setIdleTimerDisabled: (Bool) -> Void

    init(setIdleTimerDisabled: @escaping (Bool) -> Void) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    func update(reader: UUID, enabled: Bool, reading: Bool, active: Bool) {
        let wasAwake = !readers.isEmpty
        if enabled && reading && active {
            readers.insert(reader)
        } else {
            readers.remove(reader)
        }
        let isAwake = !readers.isEmpty
        if wasAwake != isAwake { setIdleTimerDisabled(isAwake) }
    }
}

struct ReadingScreenAwakeModifier: ViewModifier {
    var reading: Bool
    @AppStorage(ReadingScreenAwake.preferenceKey) private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var reader = UUID()

    private var shouldKeepAwake: Bool {
        enabled && reading && scenePhase == .active
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                ReadingScreenAwake.shared.update(reader: reader, enabled: enabled,
                                                reading: reading, active: scenePhase == .active)
            }
            .onChange(of: shouldKeepAwake) { _, value in
                ReadingScreenAwake.shared.update(reader: reader, enabled: value, reading: true, active: true)
            }
            .onDisappear {
                ReadingScreenAwake.shared.update(reader: reader, enabled: false, reading: false, active: false)
            }
    }
}
