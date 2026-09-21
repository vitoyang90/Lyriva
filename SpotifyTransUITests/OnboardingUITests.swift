import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func application(cancelFirst: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-ui-fixture"]
        if cancelFirst { app.launchArguments.append("--onboarding-cancel-first") }
        app.launchEnvironment["ONBOARDING_TEST_SUITE"] = "lyriva.onboarding-ui.\(UUID().uuidString)"
        return app
    }

    @MainActor func testCancelBackgroundResumeSkipAndRelaunch() {
        let app = application(cancelFirst: true)
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-begin"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["Spotify Client ID"].exists)
        app.buttons["onboarding-begin"].tap()
        app.buttons["onboarding-connect"].tap()
        XCTAssertTrue(app.staticTexts["登入未完成，請重試。"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["onboarding-connect"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-connect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding-begin"].exists)
        app.buttons["onboarding-connect"].tap()
        XCTAssertTrue(app.buttons["onboarding-enable-lyrics"].waitForExistence(timeout: 5))
        app.buttons["onboarding-skip-lyrics"].tap()
        XCTAssertTrue(app.buttons["onboarding-finish"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-finish"].waitForExistence(timeout: 5))
        app.buttons["onboarding-finish"].tap()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player-enable-lyrics"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["onboarding-begin"].exists)
        app.buttons["player-enable-lyrics"].tap()
        XCTAssertTrue(app.navigationBars["啟用歌詞"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["player-enable-lyrics"].waitForNonExistence(timeout: 5))
    }

    @MainActor func testLyricsCancellationAndCompletion() {
        let app = application()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-begin"].waitForExistence(timeout: 10))
        attachScreenshot("首次使用介紹")
        app.buttons["onboarding-begin"].tap()
        attachScreenshot("連接 Spotify")
        app.buttons["onboarding-connect"].tap()
        XCTAssertTrue(app.buttons["onboarding-enable-lyrics"].waitForExistence(timeout: 5))
        attachScreenshot("啟用歌詞")
        app.buttons["onboarding-enable-lyrics"].tap()
        XCTAssertTrue(app.navigationBars["啟用歌詞"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["onboarding-enable-lyrics"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-enable-lyrics"].waitForExistence(timeout: 5))
        app.buttons["onboarding-enable-lyrics"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["onboarding-finish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["歌詞登入已保存"].exists)
        attachScreenshot("開始使用")
        XCUIDevice.shared.orientation = .landscapeLeft
        let finish = app.buttons["onboarding-finish"]
        for _ in 0..<3 where !finish.isHittable { app.swipeUp() }
        XCTAssertTrue(finish.isHittable)
        finish.tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player-enable-lyrics"].exists)
    }

    @MainActor private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
