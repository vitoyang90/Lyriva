import XCTest

final class SpotifyTransUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDownloadedLanguagesAppearBeforeMissingLanguages() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--translation-model-status-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        app.buttons["設定"].tap()
        app.buttons.containing(.staticText, identifier: "翻譯語言").firstMatch.tap()
        let downloaded = app.staticTexts["language-section-0"]
        let missing = app.staticTexts["language-section-1"]
        XCTAssertTrue(downloaded.waitForExistence(timeout: 5))
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        XCTAssertLessThan(downloaded.frame.minY, missing.frame.minY)
        XCTAssertLessThan(app.staticTexts["日文"].frame.minY, missing.frame.minY)
        XCTAssertLessThan(app.staticTexts["英文"].frame.minY, missing.frame.minY)
        XCTAssertGreaterThan(app.staticTexts["法文"].frame.minY, missing.frame.minY)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Downloaded and available languages"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testTranslationLanguagesSettingsReturnToPlayer() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        app.buttons["設定"].tap()
        app.buttons.containing(.staticText, identifier: "翻譯語言").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["翻譯語言"].waitForExistence(timeout: 5))
        for language in ["日文", "英文", "韓文", "法文"] {
            XCTAssertTrue(app.staticTexts[language].exists)
        }
        XCTAssertFalse(app.buttons["下載"].exists) // Simulator cannot run Apple models.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Translation language settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["翻譯語言"].buttons.firstMatch.tap()
        app.navigationBars["設定"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Landscape Session"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsNavigationAndAccountLoginReturnToPlayer() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["關閉登入頁"].waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["連接你的 Spotify"].exists)
            app.buttons["關閉登入頁"].tap()
        }
        let settings = app.buttons["設定"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Spotify 帳號"].waitForExistence(timeout: 3))
        let settingsNavigation = app.navigationBars["設定"]
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["關閉設定"].exists)
        app.buttons["管理 Spotify 帳號"].tap()
        XCTAssertTrue(app.buttons["關閉登入頁"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["登入 Spotify 網頁"].exists)
        app.buttons["關閉登入頁"].tap()
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 3))
        settingsNavigation.buttons.firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertFalse(settingsNavigation.exists)
        settings.tap()
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 3))
        settingsNavigation.buttons.firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
    }
    @MainActor
    func testLandscapeLyricsAndControlsSurviveRotation() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Landscape Session"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let lyrics = app.staticTexts["lyrics-heading"]
        let title = app.staticTexts["Landscape Session"]
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(lyrics.frame.minX, title.frame.maxX)
        XCTAssertTrue(app.buttons["播放"].isHittable)
        XCTAssertTrue(app.sliders["播放進度"].isHittable)
        XCTAssertTrue(app.buttons["繁體中文翻譯"].isHittable)
        let follow = app.buttons["自動捲動歌詞"]
        if follow.value as? String == "開啟" { follow.tap() }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Lyriva landscape lyrics"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.scrollViews["portrait-player"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertEqual(follow.value as? String, "關閉")
        XCTAssertTrue(app.buttons["播放"].isHittable)
        XCTAssertTrue(app.sliders["播放進度"].isHittable)
        app.buttons["設定"].tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 3))
        app.navigationBars["設定"].buttons.firstMatch.tap()
        XCTAssertTrue(app.sliders["播放進度"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLandscapeTextSizesWithThreeSubtitleRows() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--translated-lyrics-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Landscape Session"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        let chinese = app.buttons["繁體中文翻譯"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        if chinese.value as? String == "關閉" { chinese.tap() }
        for label in ["原文", "羅馬字"] {
            if app.buttons[label].value as? String == "關閉" { app.buttons[label].tap() }
        }
        XCTAssertTrue(app.staticTexts["走向嶄新的世界"].waitForExistence(timeout: 5))
        let sizeMenu = app.buttons["歌詞字級"]
        var heights: [CGFloat] = []
        for size in ["小", "中", "大"] {
            sizeMenu.tap()
            app.buttons[size].tap()
            XCTAssertEqual(sizeMenu.value as? String, size)
            let original = app.staticTexts["新しい世界へ"]
            XCTAssertTrue(original.waitForExistence(timeout: 3))
            heights.append(original.frame.height)
            XCTAssertTrue(app.buttons["播放"].isHittable)
            XCTAssertTrue(app.sliders["播放進度"].isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Landscape subtitles \(size)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertLessThan(heights[0], heights[1])
        XCTAssertLessThan(heights[1], heights[2])
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.scrollViews["portrait-player"].waitForExistence(timeout: 5))
        app.swipeUp()
        sizeMenu.tap()
        app.buttons["小"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertEqual(sizeMenu.value as? String, "大")
    }

}
