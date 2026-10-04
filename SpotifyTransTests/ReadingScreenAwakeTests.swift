import Foundation
import Testing
@testable import SpotifyTrans

@MainActor
struct ReadingScreenAwakeTests {
    @Test func leavingReadingOrBackgroundingRestoresAutomaticLock() {
        var changes: [Bool] = []
        let controller = ReadingScreenAwake { changes.append($0) }
        let reader = UUID()
        controller.update(reader: reader, enabled: true, reading: true, active: true)
        controller.update(reader: reader, enabled: true, reading: false, active: true)
        controller.update(reader: reader, enabled: true, reading: true, active: true)
        controller.update(reader: reader, enabled: true, reading: true, active: false)
        controller.update(reader: reader, enabled: true, reading: true, active: true)
        controller.update(reader: reader, enabled: false, reading: true, active: true)
        #expect(changes == [true, false, true, false, true, false])
    }

    @Test func disabledReadingDoesNotChangeSystemTimer() {
        var changes: [Bool] = []
        let controller = ReadingScreenAwake { changes.append($0) }
        controller.update(reader: UUID(), enabled: false, reading: true, active: true)
        controller.update(reader: UUID(), enabled: true, reading: false, active: true)
        controller.update(reader: UUID(), enabled: true, reading: true, active: false)
        #expect(changes.isEmpty)
    }

    @Test func multipleReadersReleaseIndependently() {
        var changes: [Bool] = []
        let controller = ReadingScreenAwake { changes.append($0) }
        let first = UUID(), second = UUID()
        controller.update(reader: first, enabled: true, reading: true, active: true)
        controller.update(reader: first, enabled: true, reading: true, active: true)
        controller.update(reader: second, enabled: true, reading: true, active: true)
        controller.update(reader: first, enabled: false, reading: false, active: false)
        #expect(changes == [true])
        controller.update(reader: second, enabled: false, reading: false, active: false)
        #expect(changes == [true, false])
    }
}
