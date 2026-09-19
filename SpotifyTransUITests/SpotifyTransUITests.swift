import XCTest

final class SpotifyTransUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testManualLyricsScrollingPausesUntilResumedOrTrackChanges() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--spotify-queue-ui-fixture",
                               "-lyricsShowChinese", "NO", "-lyricsShowOriginal", "YES",
                               "-lyricsShowRomanization", "YES"]
        app.launch()
        let lyrics = app.scrollViews["lyrics-scroll-view"]
        let resume = app.buttons["resume-lyrics-follow"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10))
        XCTAssertFalse(resume.exists) // Initial programmatic positioning must keep following.
        lyrics.swipeUp()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["lyrics-options-summary"].label.contains("自動捲動已暫停"))

        // A display update must leave the user in manual reading mode.
        app.buttons["open-lyrics-options"].tap()
        let original = app.switches["原文"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        app.buttons["close-lyrics-options"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["lyrics-options-summary"].label.contains("自動捲動"))

        lyrics.swipeDown()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["Spotify Queue 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testReadingCandidatesCanBeSelectedAndRestored() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "-lyricsLanguage", "日文",
                               "-lyricsShowChinese", "NO", "-listeningMode", "normal"]
        app.launch()
        let review = app.buttons["reading-review-1"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if review.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(app.navigationBars["讀音檢查"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reading-review-original"].exists)
        let candidate = app.buttons.containing(.staticText, identifier: "明日 → ashita").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        let selected = NSPredicate(format: "value == %@", "已選擇")
        expectation(for: selected, evaluatedWith: candidate)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "讀音候選與完整原文"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["完成"].tap()
        review.tap()
        XCTAssertEqual(candidate.value as? String, "已選擇")
        let restore = app.buttons.containing(.staticText, identifier: "使用系統讀音").firstMatch
        if !restore.isHittable { app.swipeUp() }
        restore.tap()
        expectation(for: selected, evaluatedWith: restore)
        waitForExpectations(timeout: 5)
        app.buttons["完成"].tap()
    }

    @MainActor
    func testFavoriteNormalModePlaysSelectedSong() {
        verifyFavoritePlayback(mode: "一般播放")
    }

    @MainActor
    func testFavoritePracticeModePlaysSelectedSong() {
        verifyFavoritePlayback(mode: "跟唱模式")
    }

    @MainActor
    private func verifyFavoritePlayback(mode: String) {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--favorite-playback-ui-fixture", "-lyricsShowChinese", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Landscape Session"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["播放"].exists)
        app.buttons["open-favorites"].tap()
        let song = app.buttons["favorite-favorite-fixture-song"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap()
        app.buttons[mode].tap()
        XCTAssertTrue(app.navigationBars["收藏歌曲"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Favorite Session"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["暫停"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["playback-device"].label.contains("Mac"))
        XCTAssertFalse(app.buttons["更新播放裝置權限"].exists)
        XCTAssertFalse(app.staticTexts["Landscape Session"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        if mode == "跟唱模式" {
            XCTAssertTrue(app.staticTexts["practice-timing-note"].waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(app.staticTexts["practice-timing-note"].exists)
        }
    }

    @MainActor
    func testSpotifyQueueModesPreservePlaybackAndSurviveSkips() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--spotify-queue-ui-fixture", "-lyricsShowChinese", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Spotify Queue 1"].waitForExistence(timeout: 8))
        let modes = app.segmentedControls["listening-mode"]
        let timeline = app.sliders["播放進度"]
        let position = timeline.value as? String
        reveal(modes, in: app)
        XCTAssertTrue(modes.buttons["一般"].isSelected)
        XCTAssertLessThan(modes.buttons["一般"].frame.minX, modes.buttons["跟唱"].frame.minX)
        modes.buttons["跟唱"].tap()
        XCTAssertTrue(modes.buttons["跟唱"].isSelected)
        XCTAssertTrue(app.buttons["播放"].exists) // Choosing a mode must not resume or seek.
        XCTAssertEqual(timeline.value as? String, position)
        XCTAssertTrue(app.staticTexts["Spotify Queue 1"].exists)

        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Spotify queue mode portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice-timing-note"].waitForExistence(timeout: 5))
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["Spotify Queue 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["次の歌も一緒に"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice-timing-note"].exists)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Spotify queue practice after skip"
        landscape.lifetime = .keepAlways
        add(landscape)
        app.buttons["上一首"].tap()
        XCTAssertTrue(app.staticTexts["Spotify Queue 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice-timing-note"].exists)

        XCUIDevice.shared.orientation = .portrait
        reveal(modes, in: app)
        modes.buttons["一般"].tap()
        XCTAssertTrue(modes.buttons["一般"].isSelected)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["下一首"].isHittable)
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.staticTexts["Spotify Queue 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["次の歌も一緒に"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["practice-timing-note"].exists)
        XCTAssertFalse(app.staticTexts["Unexpected Queue Replacement"].exists)
    }

    @MainActor
    func testFavoritesAndPracticeMode() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "-listeningMode", "normal", "-practiceHighlight", "syllables"]
        app.launch()
        let favorite = app.buttons["favorite-current-song"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        favorite.tap()
        XCTAssertEqual(favorite.label, "取消收藏目前歌曲")
        app.buttons["open-favorites"].tap()
        XCTAssertTrue(app.navigationBars["收藏歌曲"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["跟唱模式"].exists)
        let song = app.buttons["favorite-landscape-fixture-song"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        let collection = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        collection.name = "收藏歌曲與練唱模式"
        collection.lifetime = .keepAlways
        add(collection)
        song.tap()
        XCTAssertTrue(app.buttons["一般播放"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["跟唱模式"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["收藏歌曲"].exists)
        song.tap()
        app.buttons["跟唱模式"].tap()
        XCTAssertTrue(app.navigationBars["收藏歌曲"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-favorites"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice-timing-note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice-timing-note"].label.contains("缺少逐字時間"))
        // A saved syllable setting cannot revive synthetic singing in line-only lyrics.
        XCTAssertFalse(app.staticTexts["estimated-practice-text"].exists)
        let practice = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        practice.name = "只有整句時間時的跟唱定位"
        practice.lifetime = .keepAlways
        add(practice)
        app.buttons["open-lyrics-options"].tap()
        XCTAssertTrue(app.navigationBars["歌詞選項"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["practice-highlight-picker"].exists)
        let timingExplanation = app.staticTexts["目前歌詞沒有逐字起訖時間，無法判斷句內停唱與間奏，因此不自動推算逐詞／音節反白。"]
        reveal(timingExplanation, in: app)
        XCTAssertTrue(timingExplanation.exists)
        app.buttons["close-lyrics-options"].tap()
        XCTAssertTrue(app.segmentedControls["listening-mode"].buttons["跟唱"].isSelected)
        app.buttons["open-favorites"].tap()
        song.tap()
        app.buttons["一般播放"].tap()
        XCTAssertTrue(app.navigationBars["收藏歌曲"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-favorites"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["practice-timing-note"].exists)
        XCTAssertFalse(app.buttons["practice-highlight-picker"].exists)
        // An old persisted mode must never enable follow-along at launch.
        app.terminate()
        app.launchArguments = ["--landscape-ui-fixture", "-listeningMode", "practice"]
        app.launch()
        XCTAssertTrue(app.buttons["open-favorites"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["practice-timing-note"].exists)
        XCTAssertTrue(app.segmentedControls["listening-mode"].buttons["一般"].isSelected)
    }

    @MainActor
    func testTranslationScopeKeepsBottomVisibleAndSupportsSearch() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--landscape-ui-fixture", "--translation-language-list-ui-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["設定"].waitForExistence(timeout: 5))
        app.buttons["設定"].tap()
        app.buttons.containing(.staticText, identifier: "翻譯語言").firstMatch.tap()
        let scope = app.buttons["translation-source-language"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.tap()
        let list = app.collectionViews["translation-source-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let korean = app.buttons["translation-source-option-ko"]
        for _ in 0..<12 {
            if korean.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(korean.isHittable)
        // Repeated overscroll must keep the bottom rows visible, not reopen at the top.
        for _ in 0..<3 {
            list.swipeUp()
            XCTAssertTrue(korean.isHittable)
            XCTAssertFalse(app.buttons["translation-source-option-all"].isHittable)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Translation scope scrolled to bottom"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        korean.tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.value as? String, "只翻韓文")
        scope.tap()
        let search = app.searchFields["搜尋語言名稱或代碼"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("ja")
        XCTAssertTrue(app.navigationBars["翻譯範圍"].buttons["完成"].isHittable)
        let japanese = app.buttons["translation-source-option-ja"]
        XCTAssertTrue(japanese.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["translation-source-option-ko"].exists)
        japanese.tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.value as? String, "只翻日文")
        scope.tap()
        app.buttons["translation-source-option-all"].tap()
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        XCTAssertEqual(scope.value as? String, "全部語言")
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
        let search = app.searchFields["搜尋語言"]
        search.tap()
        search.typeText("ja")
        let back = app.navigationBars["翻譯語言"].buttons.firstMatch
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(back.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Translation language search keeps back button"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        back.tap()
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
        XCTAssertTrue(app.buttons["open-lyrics-options"].isHittable)
        XCTAssertFalse(app.switches["繁體中文翻譯"].exists)
        app.buttons["open-lyrics-options"].tap()
        XCTAssertTrue(app.navigationBars["歌詞選項"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["繁體中文翻譯"].exists)
        XCTAssertFalse(app.buttons["practice-highlight-picker"].exists)
        let follow = app.switches["自動捲動歌詞"]
        reveal(follow, in: app)
        if follow.value as? String == "1" { follow.tap() }
        app.buttons["close-lyrics-options"].tap()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Lyriva landscape lyrics"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.scrollViews["portrait-player"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        app.buttons["open-lyrics-options"].tap()
        reveal(follow, in: app)
        XCTAssertEqual(follow.value as? String, "0")
        app.buttons["close-lyrics-options"].tap()
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
        app.buttons["open-lyrics-options"].tap()
        let chinese = app.switches["繁體中文翻譯"]
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        print("OPTIONS DEBUG \(app.debugDescription)")
        print("CHINESE VALUE \(String(describing: chinese.value))")
        if chinese.value as? String == "0" { chinese.tap() }
        for label in ["原文", "羅馬字"] {
            if app.switches[label].value as? String == "0" { app.switches[label].tap() }
        }
        app.buttons["close-lyrics-options"].tap()
        XCTAssertTrue(app.staticTexts["走向嶄新的世界"].waitForExistence(timeout: 5))
        let sizeMenu = app.buttons["歌詞字級"]
        var heights: [CGFloat] = []
        for size in ["小", "中", "大"] {
            app.buttons["open-lyrics-options"].tap()
            reveal(sizeMenu, in: app)
            sizeMenu.tap()
            app.buttons[size].tap()
            XCTAssertEqual(sizeMenu.value as? String, size)
            app.buttons["close-lyrics-options"].tap()
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
        app.buttons["open-lyrics-options"].tap()
        reveal(sizeMenu, in: app)
        sizeMenu.tap()
        app.buttons["小"].tap()
        let options = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        options.name = "歌詞選項面板"
        options.lifetime = .keepAlways
        add(options)
        app.buttons["close-lyrics-options"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.scrollViews["landscape-player"].waitForExistence(timeout: 5))
        app.buttons["open-lyrics-options"].tap()
        reveal(sizeMenu, in: app)
        XCTAssertEqual(sizeMenu.value as? String, "大")
        app.buttons["close-lyrics-options"].tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

}
