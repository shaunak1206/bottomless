import XCTest

/// Drives the real app in the simulator against a backend given by BOTTOMLESS_API_BASE / BOTTOMLESS_TOKEN
/// (scripts/sim_e2e.sh passes them as TEST_RUNNER_ variables). Screenshots go to SCREENSHOT_DIR when set.
final class BottomlessUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        for k in ["BOTTOMLESS_API_BASE", "BOTTOMLESS_TOKEN"] { if let v = env[k] { app.launchEnvironment[k] = v } }
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func tab(_ name: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[name]
        return inBar.exists ? inBar : app.buttons[name]
    }

    /// Lists only build rows that are on screen, so scroll until the element shows up.
    @discardableResult
    private func scrollTo(_ e: XCUIElement) -> Bool {
        for _ in 0..<8 where !e.exists { app.swipeUp() }
        for _ in 0..<8 where !e.exists { app.swipeDown() }
        return e.exists
    }

    private func setSwitch(_ e: XCUIElement, on: Bool) {
        guard (e.value as? String == "1") != on else { return }
        e.switches.firstMatch.exists ? e.switches.firstMatch.tap() : e.tap()
    }

    /// Back one screen: the back button (named differently across iOS versions), else the edge swipe.
    private func goBack() {
        let candidates = [app.navigationBars.buttons.firstMatch, app.buttons["BackButton"], app.buttons["Back"], app.buttons["Collections"]]
        if let b = candidates.first(where: { $0.exists && $0.isHittable }) { b.tap(); return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    }

    private var cells: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cell-'")) }

    func test1_LibraryViewerFavoriteShareAndBackup() throws {
        app.launch()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 30), "library shows backed-up photos")
        snap("01-library")

        // Open the newest photo (skip videos: the first image cell)
        let photoCell = cells.element(boundBy: 0)
        photoCell.tap()
        let fav = app.buttons["favoriteButton"]
        XCTAssertTrue(fav.waitForExistence(timeout: 15), "viewer opens with actions")
        sleep(2)
        snap("02-viewer")
        // Whatever the starting state, toggling must flip the heart right away; end on "favorite".
        let start = fav.value as? String
        fav.tap()
        let flipped = NSPredicate(format: "value != %@", start ?? "")
        expectation(for: flipped, evaluatedWith: fav)
        waitForExpectations(timeout: 10)
        if fav.value as? String != "on" {
            fav.tap()
            expectation(for: NSPredicate(format: "value == 'on'"), evaluatedWith: fav)
            waitForExpectations(timeout: 10)
        }
        snap("03-favorited")
        app.buttons["shareMenu"].tap()
        XCTAssertTrue(app.buttons["Share photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create link"].exists)
        snap("04-share-menu")
        app.buttons["Create link"].tap()
        XCTAssertTrue(app.buttons["Create link"].waitForExistence(timeout: 5))
        app.buttons["Create link"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Copy link"].waitForExistence(timeout: 15), "share link created")
        snap("05-share-link")
        app.buttons["Done"].tap()
        app.buttons["closeViewer"].tap()

        tab("Collections").tap()
        let favorites = app.buttons["collection-favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        snap("06-collections")
        favorites.tap()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10), "the favorite shows in Favorites")
        snap("06b-favorites")
        goBack()

        tab("Backup").tap()
        XCTAssertTrue(app.staticTexts["backupHeadline"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Everything is backed up"].waitForExistence(timeout: 60))
        snap("07-backup-status")
    }

    /// Free up space: needs the iCloud confirmation toggle, then iOS's own delete prompt. Removed photos stay in the library.
    func test3_FreeUpSpaceRemovesOldBackedUpPhotosFromThePhone() throws {
        app.launch()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 30))
        let before = cells.count
        tab("Backup").tap()
        let button = app.buttons["freeUpButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10) || scrollTo(button))
        if button.label.contains("Nothing to free up") {
            throw XCTSkip("an earlier run already freed this camera roll; scripts/sim_e2e.sh starts from a fresh one")
        }
        let toggle = app.switches["iCloud Photos is turned off"]
        XCTAssertTrue(scrollTo(toggle))
        setSwitch(toggle, on: false)    // a previous run may have left it on
        XCTAssertFalse(button.isEnabled, "disabled until iCloud Photos is confirmed off")
        setSwitch(toggle, on: true)
        XCTAssertTrue(button.isEnabled)
        snap("10-free-up-ready")
        button.tap()
        let remove = app.buttons["Remove from iPhone"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        snap("11-free-up-confirm")
        remove.tap()
        // iOS asks again (a system alert from Photos). It can take a while on a busy machine, and depending on the iOS
        // version it belongs to SpringBoard or to the app, so look in both until it or the result shows up.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let result = app.alerts.containing(NSPredicate(format: "label CONTAINS 'Removed' OR label CONTAINS 'Could not'")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline && !result.exists {
            if let delete = [springboard.buttons["Delete"], app.alerts.buttons["Delete"]].first(where: { $0.exists }) {
                snap("12-ios-delete-prompt"); delete.tap()
            }
            usleep(300_000)
        }
        let done = app.alerts.firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "result message")
        let text = done.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains("Removed"), text)
        snap("13-free-up-done")
        done.buttons.firstMatch.tap()
        tab("Library").tap()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(cells.count, before - 2, "removed photos are still in the library (from the cloud)")
    }

    func test2_OfflineStillShowsTheLibrary() throws {
        app.launchArguments = ["-forceOffline"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Offline: showing what is saved on this iPhone"].waitForExistence(timeout: 15))
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10), "thumbnails are on the phone")
        snap("08-offline-library")
        cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["closeViewer"].waitForExistence(timeout: 10))
        sleep(2)
        snap("09-offline-viewer")
    }

    /// A cloud-only Live Photo (seeded by sim_e2e.sh, like one imported from Google Photos): play its motion, turn Live
    /// off for it and back on, then turn Live Photos off for the whole library.
    func test4_LivePhotoPlaysAndCanBeTurnedOff() throws {
        guard let id = ProcessInfo.processInfo.environment["LIVE_ID"], !id.isEmpty else {
            throw XCTSkip("scripts/sim_e2e.sh seeds a Live Photo and passes its id as LIVE_ID")
        }
        app.launch()
        let cell = app.buttons["cell-\(id)"]
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the Live Photo is in the library")
        cell.tap()
        let live = app.buttons["liveMenu"]
        XCTAssertTrue(live.waitForExistence(timeout: 15), "Live Photos get a LIVE menu")
        XCTAssertEqual(live.value as? String, "on")

        // Press and hold, like in Photos.
        let page = app.descendants(matching: .any).matching(identifier: "photo-\(id)")
        XCTAssertTrue(page.firstMatch.waitForExistence(timeout: 10))
        page.firstMatch.press(forDuration: 3.5)
        let plays = page.allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertTrue(plays.contains("live plays: 1"), "press and hold plays the motion (\(plays))")

        live.tap()
        app.buttons["livePlay"].tap()
        XCTAssertTrue(app.otherElements["livePlaying"].waitForExistence(timeout: 15), "the motion plays")
        snap("14-live-playing")
        XCTAssertTrue(app.otherElements["livePlaying"].waitForNonExistence(timeout: 15), "and returns to the still at the end")

        live.tap()
        app.buttons["liveOff"].tap()
        expectation(for: NSPredicate(format: "value == 'off'"), evaluatedWith: live)
        waitForExpectations(timeout: 10)
        snap("15-live-off")
        live.tap()
        XCTAssertFalse(app.buttons["livePlay"].isEnabled, "a photo with Live off stays still")
        app.buttons["liveOn"].tap()
        expectation(for: NSPredicate(format: "value == 'on'"), evaluatedWith: live)
        waitForExpectations(timeout: 10)
        app.buttons["closeViewer"].tap()

        // Turn Live Photos off everywhere (Backup → Settings): no LIVE menu, the photo is a still.
        let setting = app.switches["playLivePhotos"]
        func openSettings() {
            tab("Backup").tap()
            if !setting.waitForExistence(timeout: 2) { app.buttons["settingsButton"].tap() }
            XCTAssertTrue(setting.waitForExistence(timeout: 10), "the Play Live Photos switch is in Settings")
        }
        openSettings()
        snap("18-settings")
        setSwitch(setting, on: false)
        snap("16-live-photos-off")
        tab("Library").tap()
        cell.tap()
        XCTAssertTrue(app.buttons["closeViewer"].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertFalse(app.buttons["liveMenu"].exists, "with Live Photos off every Live Photo is a still")
        app.buttons["closeViewer"].tap()
        openSettings()
        setSwitch(setting, on: true)
        XCTAssertEqual(setting.value as? String, "1")
    }

    /// Swiping through photos must land on a new photo every time (never stop half way between two).
    func test5_ViewerSwipesFarThroughTheLibrary() throws {
        app.launch()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 30))
        cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["closeViewer"].waitForExistence(timeout: 10))
        // Read the screen as one consistent snapshot per swipe (pages scrolled away are recycled while being read).
        func centred() -> String? {
            guard let root = try? app.snapshot() else { return nil }
            let screen = root.frame
            var stack = [root]
            while let e = stack.popLast() {
                if e.identifier.hasPrefix("photo-"), screen.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) { return e.identifier }
                stack.append(contentsOf: e.children)
            }
            return nil
        }
        var seen = Set<String>()
        var trail: [String] = []
        sleep(1)
        for _ in 0..<20 {
            app.swipeLeft()
            usleep(400_000)
            let id = centred()
            trail.append(id.map { String($0.suffix(4)) } ?? "?")
            if let id { seen.insert(id) }
        }
        print("SWIPE TRAIL:", trail.joined(separator: " > "))
        XCTAssertGreaterThanOrEqual(seen.count, 18, "swiped through \(seen.count) photos")
        snap("17-viewer-after-20-swipes")
        app.buttons["closeViewer"].tap()
    }

    /// Deleting from the viewer: the photo leaves the library at once (even when the cloud cannot take the change yet).
    func test6_DeleteFromTheViewer() throws {
        app.launch()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 30))
        let cell = cells.element(boundBy: 2)
        let cellId = cell.identifier
        cell.tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        let confirm = app.buttons["Delete Photo"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "asks before deleting")
        snap("19-delete-confirm")
        confirm.tap()
        XCTAssertTrue(app.buttons["closeViewer"].waitForNonExistence(timeout: 5), "the viewer closes")
        XCTAssertTrue(app.buttons[cellId].waitForNonExistence(timeout: 5), "the photo leaves the library right away")

        // Put it back for the next run (straight through the API).
        let env = ProcessInfo.processInfo.environment
        if let base = env["BOTTOMLESS_API_BASE"], let token = env["BOTTOMLESS_TOKEN"] {
            var req = URLRequest(url: URL(string: base)!.appendingPathComponent("v1/assets/\(cellId.dropFirst(5))/restore"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let done = expectation(description: "restored")
            URLSession.shared.dataTask(with: req) { _, _, _ in done.fulfill() }.resume()
            wait(for: [done], timeout: 10)
        }
    }

    /// Collections: Videos lists the videos, Places shows the map.
    func test7_CollectionsVideosAndPlaces() throws {
        app.launch()
        tab("Collections").tap()
        let videos = app.buttons["collection-videos"]
        XCTAssertTrue(videos.waitForExistence(timeout: 15))
        videos.tap()
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10), "videos are listed")
        snap("20-videos")
        goBack()
        let places = app.buttons["collection-places"]
        XCTAssertTrue(places.waitForExistence(timeout: 10))
        places.tap()
        XCTAssertTrue(app.navigationBars["Places"].waitForExistence(timeout: 10))
        sleep(4)
        snap("21-places")
    }
}
