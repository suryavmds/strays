import XCTest
@testable import StraysCore

final class SemanticVersionTests: XCTestCase {
    private func version(_ string: String) -> SemanticVersion { SemanticVersion(string)! }

    func testParsesCommonForms() {
        XCTAssertEqual(version("1.2.3").description, "1.2.3")
        XCTAssertEqual(version("v0.1.0").description, "0.1.0")
        XCTAssertEqual(version("2.5").description, "2.5.0")
        XCTAssertEqual(version("3").description, "3.0.0")
        XCTAssertEqual(version(" v1.0.0-beta.2+build.7 ").description, "1.0.0-beta.2")
    }

    func testRejectsThingsThatAreNotVersions() {
        for text in ["", "latest", "1.2.3.4", "1..2", "a.b.c", "-1.0.0", "1.x"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(version("0.9.9"), version("0.10.0"), "numeric, not alphabetical")
        XCTAssertLessThan(version("1.2.3"), version("1.2.4"))
        XCTAssertLessThan(version("1.9.9"), version("2.0.0"))
        XCTAssertEqual(version("v1.2.0"), version("1.2"))
        XCTAssertFalse(version("1.0.0") < version("1.0.0"))
    }

    func testPrereleasesSortBeforeTheirRelease() {
        XCTAssertLessThan(version("1.0.0-beta.1"), version("1.0.0"))
        XCTAssertLessThan(version("1.0.0-alpha"), version("1.0.0-beta"))
        XCTAssertLessThan(version("1.0.0-beta.2"), version("1.0.0-beta.10"))
        XCTAssertLessThan(version("1.0.0-beta"), version("1.0.0-beta.1"))
        XCTAssertLessThan(version("1.0.0-1"), version("1.0.0-alpha"))
        XCTAssertGreaterThan(version("1.0.1-beta"), version("1.0.0"))
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func checker(returning json: String) -> UpdateChecker {
        UpdateChecker(repository: "someone/strays") { _ in Data(json.utf8) }
    }

    private let release = #"{"tag_name": "v0.3.0", "html_url": "https://github.com/someone/strays/releases/tag/v0.3.0", "body": "Faster scans.", "draft": false}"#

    func testAsksGitHubForTheLatestReleaseOfTheRepository() {
        XCTAssertEqual(UpdateChecker(repository: "someone/strays").endpoint.absoluteString, "https://api.github.com/repos/someone/strays/releases/latest")
        XCTAssertEqual(UpdateChecker().repository, "suryavmds/strays")
    }

    func testReportsANewerRelease() async throws {
        let update = await checker(returning: release).update(newerThan: "0.2.4")
        let found = try XCTUnwrap(update)
        XCTAssertEqual(found.version.description, "0.3.0")
        XCTAssertEqual(found.tag, "v0.3.0")
        XCTAssertEqual(found.pageURL.absoluteString, "https://github.com/someone/strays/releases/tag/v0.3.0")
        XCTAssertEqual(found.notes, "Faster scans.")
    }

    func testSaysNothingWhenCurrentOrAhead() async {
        let same = await checker(returning: release).update(newerThan: "0.3.0")
        XCTAssertNil(same)
        let ahead = await checker(returning: release).update(newerThan: "0.4.0-beta.1")
        XCTAssertNil(ahead, "a development build ahead of the latest release")
    }

    func testAPrereleaseBuildIsOfferedItsFinalRelease() async {
        let update = await checker(returning: release).update(newerThan: "0.3.0-beta.2")
        XCTAssertEqual(update?.version.description, "0.3.0")
    }

    func testFailuresAreSilent() async {
        struct Offline: Error {}
        let offline = await UpdateChecker { _ in throw Offline() }.update(newerThan: "0.1.0")
        XCTAssertNil(offline)
        let garbage = await checker(returning: "<html>rate limited</html>").update(newerThan: "0.1.0")
        XCTAssertNil(garbage)
        let unknownInstalled = await checker(returning: release).update(newerThan: "development")
        XCTAssertNil(unknownInstalled)
    }

    func testRejectsMalformedOrUnsafeReleaseData() {
        for json in [
            "{}",
            #"{"tag_name": "nightly", "html_url": "https://github.com/x/y"}"#,
            #"{"tag_name": "v1.0.0", "html_url": "javascript:alert(1)"}"#,
            #"{"tag_name": "v1.0.0", "html_url": "http://insecure.example/release"}"#,
        ] {
            XCTAssertThrowsError(try UpdateChecker.parse(Data(json.utf8)), json)
        }
    }

    func testCoreVersionIsAValidVersion() {
        XCTAssertNotNil(SemanticVersion(StraysCore.version))
    }
}
