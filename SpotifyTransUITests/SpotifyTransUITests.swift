import XCTest

final class SpotifyTransUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectionSettingsCanOpenAndClose() {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["連線與設定"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Spotify 播放控制"].waitForExistence(timeout: 3))
        app.buttons["關閉設定"].tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["關閉設定"].exists)
    }
}
