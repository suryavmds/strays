import XCTest
@testable import StraysCore

final class ProjectResolverTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var resolver: ProjectResolver!

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        resolver = ProjectResolver(homeDirectory: home.path)
    }

    func testFindsNearestMarkerWalkingUp() throws {
        try home.makeDirectory("code/shop/.git")
        let deep = try home.makeDirectory("code/shop/src/api/handlers")
        let project = try XCTUnwrap(resolver.project(forDirectory: deep.path))
        XCTAssertEqual(project.name, "shop")
        XCTAssertEqual(project.rootPath, home.path + "/code/shop")
        XCTAssertEqual(project.marker, ".git")
    }

    func testNearestMarkerWinsInAMonorepo() throws {
        try home.makeDirectory("mono/.git")
        try home.write(#"{"name": "@acme/web"}"#, to: "mono/apps/web/package.json")
        let cwd = try home.makeDirectory("mono/apps/web/src")
        let project = try XCTUnwrap(resolver.project(forDirectory: cwd.path))
        XCTAssertEqual(project.name, "@acme/web")
        XCTAssertEqual(project.rootPath, home.path + "/mono/apps/web")
    }

    func testUsesPackageJSONNameEvenWhenGitIsTheMarker() throws {
        try home.makeDirectory("folder-name/.git")
        try home.write(#"{"name": "real-name", "version": "1.0.0"}"#, to: "folder-name/package.json")
        XCTAssertEqual(resolver.project(forDirectory: home.path + "/folder-name")?.name, "real-name")
    }

    func testFallsBackToFolderNameForUnnamedOrBrokenPackageJSON() throws {
        try home.write("{ not json", to: "broken/package.json")
        try home.write(#"{"name": "   "}"#, to: "blank/package.json")
        XCTAssertEqual(resolver.project(forDirectory: home.path + "/broken")?.name, "broken")
        XCTAssertEqual(resolver.project(forDirectory: home.path + "/blank")?.name, "blank")
    }

    func testRecognisesEveryMarker() throws {
        for marker in ProjectResolver.defaultMarkers where marker != ".git" {
            let name = "p-" + marker.replacingOccurrences(of: ".", with: "_")
            try home.write(marker == "package.json" ? "{}" : "", to: "\(name)/\(marker)")
            XCTAssertEqual(resolver.project(forDirectory: home.path + "/" + name)?.marker, marker)
        }
    }

    func testHomeFolderIsNeverAProject() throws {
        try home.makeDirectory(".git")
        let loose = try home.makeDirectory("scratch/notes")
        XCTAssertNil(resolver.project(forDirectory: home.path))
        XCTAssertNil(resolver.project(forDirectory: loose.path))
    }

    func testMissingDirectoryAndRootResolveToNothing() {
        XCTAssertNil(resolver.project(forDirectory: "/"))
        XCTAssertNil(resolver.project(forDirectory: home.path + "/does/not/exist"))
    }

    func testResultsAreCachedUntilInvalidated() throws {
        let cwd = try home.makeDirectory("late")
        XCTAssertNil(resolver.project(forDirectory: cwd.path))
        try home.write("", to: "late/go.mod")
        XCTAssertNil(resolver.project(forDirectory: cwd.path), "still cached")
        resolver.invalidate()
        XCTAssertEqual(resolver.project(forDirectory: cwd.path)?.name, "late")
    }
}

/// The mode the app uses: answers from memory, looks at the disk elsewhere.
final class BackgroundProjectResolverTests: XCTestCase {
    private var home: TemporaryDirectory!

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.write(#"{"name": "real-name"}"#, to: "code/shop/package.json")
    }

    private var shop: String { home.path + "/code/shop" }

    func testFirstCallAnswersAtOnceAndTheProjectFollows() async {
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background)
        XCTAssertNil(resolver.project(forDirectory: shop), "nothing is known yet, and it did not wait to find out")

        await resolver.settle(timeout: 5)
        XCTAssertFalse(resolver.hasPendingLookups)
        XCTAssertEqual(resolver.project(forDirectory: shop)?.rootPath, shop)
    }

    func testFolderNameComesFirstAndThePackageNameReplacesIt() async {
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background)
        _ = resolver.project(forDirectory: shop)
        let named = await eventually { resolver.project(forDirectory: self.shop)?.name == "real-name" }
        XCTAssertTrue(named)
    }

    func testPackageNamesCanBeTurnedOff() async {
        // Reading a file's contents is what macOS may prompt about.
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background, packageNames: .never)
        _ = resolver.project(forDirectory: shop)
        await resolver.settle(timeout: 5)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(resolver.project(forDirectory: shop)?.name, "shop")

        let inline = ProjectResolver(homeDirectory: home.path, packageNames: .never)
        XCTAssertEqual(inline.project(forDirectory: shop)?.name, "shop")
    }

    func testFoldersBehindAPrivacyPromptAreRecognised() {
        let resolver = ProjectResolver(homeDirectory: "/Users/me")
        for path in ["/Users/me/Documents", "/Users/me/Documents/Projects/shop", "/Users/me/Desktop/x", "/Users/me/Downloads/y",
                     "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/z", "/Users/me/Library/CloudStorage/Dropbox/w", "/Volumes/Work/shop"] {
            XCTAssertTrue(resolver.isProtectedByPrivacyPrompt(path), path)
        }
        for path in ["/Users/me/code/shop", "/Users/me/Developer/x", "/Users/me", "/Users/me/DocumentsBackup/x", "/private/tmp/x", "/opt/work"] {
            XCTAssertFalse(resolver.isProtectedByPrivacyPrompt(path), path)
        }
    }

    func testByDefaultNoFileIsOpenedWhereMacOSWouldPrompt() throws {
        // A stand-in home with a project in Documents and one outside it.
        try home.write(#"{"name": "in-documents"}"#, to: "Documents/Projects/shop/package.json")
        let cautious = ProjectResolver(homeDirectory: home.path, packageNames: .unprotectedOnly)

        XCTAssertEqual(cautious.project(forDirectory: home.path + "/Documents/Projects/shop")?.name, "shop", "found, but named by its folder")
        XCTAssertEqual(cautious.project(forDirectory: shop)?.name, "real-name", "outside the guarded folders the name is read")

        let trusting = ProjectResolver(homeDirectory: home.path, packageNames: .everywhere)
        XCTAssertEqual(trusting.project(forDirectory: home.path + "/Documents/Projects/shop")?.name, "in-documents")
    }

    func testChangingThePolicyTakesEffectAtOnce() {
        let resolver = ProjectResolver(homeDirectory: home.path, packageNames: .never)
        XCTAssertEqual(resolver.project(forDirectory: shop)?.name, "shop")
        let before = resolver.revision
        resolver.setPackageNamePolicy(.everywhere)
        XCTAssertNotEqual(resolver.revision, before)
        XCTAssertEqual(resolver.project(forDirectory: shop)?.name, "real-name")
    }

    func testADiskThatNeverAnswersNeverBlocksTheCaller() async {
        // Stands in for macOS holding a read until the user answers a
        // privacy prompt, or a network volume that has gone away.
        let gate = DispatchSemaphore(value: 0)
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background) { _ in gate.wait() }
        defer { gate.signal() }

        let started = Date()
        XCTAssertNil(resolver.project(forDirectory: shop))
        XCTAssertNil(resolver.project(forDirectory: shop), "asking again does not queue a second lookup or wait")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertTrue(resolver.hasPendingLookups)

        await resolver.settle(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "settle gives up at its timeout")
        XCTAssertNil(resolver.project(forDirectory: shop))
    }

    func testAnswerArrivesOnceTheDiskDoes() async {
        let gate = DispatchSemaphore(value: 0)
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background) { _ in gate.wait() }
        XCTAssertNil(resolver.project(forDirectory: shop))
        gate.signal()
        await resolver.settle(timeout: 5)
        XCTAssertEqual(resolver.project(forDirectory: shop)?.rootPath, shop)
    }

    func testAStaleAnswerIsServedWhileItIsRefreshed() async throws {
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background, cacheLifetime: 0.05) { _ in }
        _ = resolver.project(forDirectory: shop)
        await resolver.settle(timeout: 5)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotNil(resolver.project(forDirectory: shop), "expired, but still the best answer we have")
    }

    func testSettleReturnsImmediatelyWhenNothingIsPending() async {
        let resolver = ProjectResolver(homeDirectory: home.path, mode: .background)
        let started = Date()
        await resolver.settle(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}

final class DevProcessClassifierTests: XCTestCase {
    private var home: TemporaryDirectory!
    private var classifier: DevProcessClassifier!
    private let longAgo: UInt64 = 1_000

    override func setUpWithError() throws {
        home = try TemporaryDirectory()
        try home.makeDirectory("code/shop/.git")
        try home.makeDirectory("Library/Application Support/Tool")
        try home.makeDirectory(".vscode/extensions/ext")
        classifier = DevProcessClassifier(rules: .bundled, homeDirectory: home.path, minimumAge: 0)
    }

    private func process(path: String, arguments: [String] = [], cwd: String?, inspectable: Bool = true) -> ProcessDetails {
        makeDetails(makeEntry(100, name: (path as NSString).lastPathComponent), path: path, arguments: arguments, cwd: cwd, isInspectable: inspectable)
    }

    private var project: String { home.path + "/code/shop" }

    func testBundledRulesLoad() {
        let rules = RuntimeRules.bundled
        XCTAssertFalse(rules.runtimes.isEmpty)
        for id in ["node", "bun", "deno", "python", "ruby", "java", "php", "go", "rust"] {
            XCTAssertNotNil(rules.runtime(withID: id), "missing runtime \(id)")
        }
    }

    func testKnownRuntimesInsideAProjectAreDevProcesses() {
        let cases: [(String, String)] = [
            ("/usr/local/bin/node", "node"),
            ("/opt/homebrew/bin/bun", "bun"),
            ("/opt/homebrew/bin/deno", "deno"),
            ("/opt/homebrew/Cellar/python@3.12/3.12.3/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "python"),
            ("/usr/bin/python3", "python"),
            ("/opt/homebrew/bin/python3.12", "python"),
            ("/opt/homebrew/opt/ruby/bin/ruby", "ruby"),
            ("/usr/bin/java", "java"),
            ("/opt/homebrew/bin/php", "php"),
            ("/opt/homebrew/bin/cargo", "rust"),
            ("/opt/homebrew/bin/go", "go"),
        ]
        for (path, runtime) in cases {
            XCTAssertEqual(classifier.classify(process(path: path, cwd: project))?.runtimeID, runtime, path)
        }
    }

    func testOrdinaryProgramsAreNotDevProcesses() {
        for path in ["/bin/zsh", "/usr/bin/ssh", "/usr/bin/git", "/usr/bin/vim", "/Applications/Safari.app/Contents/MacOS/Safari"] {
            XCTAssertNil(classifier.classify(process(path: path, cwd: project)), path)
        }
    }

    func testWorkingDirectoryMustBeInsideHome() {
        let node = "/usr/local/bin/node"
        XCTAssertNotNil(classifier.classify(process(path: node, cwd: home.path)))
        XCTAssertNil(classifier.classify(process(path: node, cwd: "/")))
        XCTAssertNil(classifier.classify(process(path: node, cwd: "/usr/local/lib")))
        XCTAssertNil(classifier.classify(process(path: node, cwd: nil)))
        XCTAssertNil(classifier.classify(process(path: node, cwd: home.path + "-other/code")), "a sibling of home is not inside it")
    }

    func testLibraryHiddenToolFoldersAndAppBundlesAreExcluded() {
        let node = "/usr/local/bin/node"
        XCTAssertNil(classifier.classify(process(path: node, cwd: home.path + "/Library/Application Support/Tool")))
        XCTAssertNil(classifier.classify(process(path: node, cwd: home.path + "/.vscode/extensions/ext")))
        XCTAssertNil(classifier.classify(process(path: node, cwd: home.path + "/Apps/Tool.app/Contents/Resources")))
    }

    func testLanguageServersAreIgnored() {
        let node = "/usr/local/bin/node"
        let servers: [[String]] = [
            ["node", "/x/node_modules/typescript/lib/tsserver.js", "--useInferredProjectPerProjectRoot"],
            ["node", "/x/typescript-language-server", "--stdio"],
            ["node", "/Users/me/.vscode/extensions/dbaeumer.vscode-eslint/server/out/eslintServer.js", "--node-ipc"],
            ["node", "/x/pyright-langserver.js", "--stdio"],
        ]
        for arguments in servers {
            XCTAssertNil(classifier.classify(process(path: node, arguments: arguments, cwd: project)), arguments[1])
        }
        XCTAssertNotNil(classifier.classify(process(path: node, arguments: ["node", "server.js"], cwd: project)))
    }

    func testCompiledBinaryInsideAProjectCounts() throws {
        try home.makeDirectory("code/shop/bin")
        let binary = classifier.classify(process(path: project + "/bin/api", cwd: project))
        XCTAssertEqual(binary?.runtimeID, DevClassification.binaryRuntimeID)
        // The same binary outside any project is just a program.
        XCTAssertNil(classifier.classify(process(path: home.path + "/tools/api", cwd: home.path)))
    }

    func testBuildOutputPatternsCount() {
        for path in [
            "/Users/someone/proj/target/debug/api",
            "/private/var/folders/ab/T/go-build123456/b001/exe/main",
            "/Users/someone/proj/.build/arm64-apple-macosx/debug/Tool",
            "/Users/someone/proj/node_modules/@esbuild/darwin-arm64/bin/esbuild",
        ] {
            XCTAssertEqual(classifier.runtime(forExecutablePath: path, name: "x")?.runtimeID, DevClassification.binaryRuntimeID, path)
        }
    }

    func testBinariesInToolFoldersDoNotCount() throws {
        try home.write("{}", to: ".vscode/extensions/ext/package.json")
        XCTAssertNil(classifier.runtime(forExecutablePath: home.path + "/.vscode/extensions/ext/server/analyzer", name: "analyzer"))
        XCTAssertNil(classifier.runtime(forExecutablePath: home.path + "/Library/Tool/bin/helper", name: "helper"))
        XCTAssertNil(classifier.runtime(forExecutablePath: nil, name: "mystery"))
    }

    func testYoungProcessesWaitOutTheMinimumAge() {
        let patient = DevProcessClassifier(rules: .bundled, homeDirectory: home.path, minimumAge: 8)
        let now = Date()
        let young = makeDetails(
            ProcessEntry(
                identity: ProcessIdentity(pid: 5, startSeconds: UInt64(now.timeIntervalSince1970) - 2, startMicroseconds: 0),
                ppid: 1, pgid: 5, uid: getuid(), name: "node"
            ),
            path: "/usr/local/bin/node", cwd: project
        )
        XCTAssertNil(patient.classify(young, now: now))
        XCTAssertNotNil(patient.classify(young, now: now.addingTimeInterval(10)))
    }

    func testUninspectableProcessesAreNeverClassified() {
        XCTAssertNil(classifier.classify(process(path: "/usr/local/bin/node", cwd: project, inspectable: false)))
    }

    func testInvalidPatternsAreSkippedNotFatal() {
        let rules = RuntimeRules(
            runtimes: [.init(id: "x", displayName: "X", executableNames: ["xrun"], executableNamePatterns: ["([unclosed"])],
            ignore: .init(cwdPatterns: ["(bad"])
        )
        let lenient = DevProcessClassifier(rules: rules, homeDirectory: home.path, minimumAge: 0)
        XCTAssertEqual(lenient.classify(process(path: "/opt/xrun", cwd: project))?.runtimeID, "x")
    }
}

final class CommandSummaryTests: XCTestCase {
    private func title(_ arguments: [String], name: String = "x", interpreter: Bool = true) -> String {
        CommandSummary.title(arguments: arguments, executableName: name, isInterpreter: interpreter)
    }

    func testToolsRunThroughAnInterpreterAreNamedByTheTool() {
        XCTAssertEqual(title(["node", "/Users/me/shop/node_modules/.bin/next", "dev"]), "next dev")
        XCTAssertEqual(title(["node", "/Users/me/shop/node_modules/vite/bin/vite.js", "--port", "5173"]), "vite --port 5173")
        XCTAssertEqual(title(["node", "/usr/local/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"]), "npm run dev")
        XCTAssertEqual(title(["node", "/usr/local/bin/npm", "run", "dev"]), "npm run dev")
        XCTAssertEqual(title(["/x/.venv/bin/python", "/x/.venv/bin/uvicorn", "app:app", "--reload"]), "uvicorn app:app --reload")
    }

    func testInterpreterFlagsBeforeTheToolAreDropped() {
        XCTAssertEqual(title(["node", "--inspect", "--max-old-space-size=4096", "/a/node_modules/.bin/tsc", "--watch"]), "tsc --watch")
    }

    func testInterpreterFlagsAreNotPartOfTheName() {
        XCTAssertEqual(
            title(["node", "--env-file=.env.local", "--env-file=../api/.env", "/private/tmp/x/audit-strict.js", "/Users/me/shop", "/private/tmp/x/audit-strict.json"]),
            "node audit-strict.js shop audit-strict.json"
        )
        XCTAssertEqual(title(["node", "--inspect", "server.js", "--port", "3000"]), "node server.js --port 3000")
        XCTAssertEqual(title(["ruby", "-w", "script.rb"]), "ruby script.rb")
        XCTAssertEqual(title(["node", "--inspect"]), "node")
    }

    func testInlineCodeIsElided() {
        XCTAssertEqual(title(["/usr/bin/python3", "-c", "import time; time.sleep(60)"]), "python3 -c …")
        XCTAssertEqual(title(["node", "-e", "require('http').createServer().listen(0)"]), "node -e …")
    }

    func testVeryLongTitlesAreCut() {
        let long = title(["tool", String(repeating: "a", count: 200)], interpreter: false)
        XCTAssertEqual(long.count, 64)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testOwnScriptsKeepTheInterpreter() {
        XCTAssertEqual(title(["node", "server.js"]), "node server.js")
        XCTAssertEqual(title(["/usr/bin/python3", "-m", "http.server", "8000"]), "python3 -m http.server 8000")
        XCTAssertEqual(title(["python", "/Users/me/shop/manage.py", "runserver"]), "python manage.py runserver")
    }

    func testCompiledProgramsUseTheirBasenameAndShortenPaths() {
        XCTAssertEqual(title(["/Users/me/shop/target/debug/api", "--config", "/etc/shop/config.toml"], interpreter: false), "api --config config.toml")
        XCTAssertEqual(title(["redis-server", "127.0.0.1:6379"], interpreter: false), "redis-server 127.0.0.1:6379")
    }

    func testJavaIsNamedByItsJarOrMainClass() {
        XCTAssertEqual(title(["/usr/bin/java", "-Xmx2g", "-jar", "/opt/app/server.jar", "--port", "8080"], interpreter: false), "java -jar server.jar --port 8080")
        XCTAssertEqual(
            title(["java", "-Xmx512m", "-cp", "/a.jar:/b.jar", "-Dfile.encoding=UTF-8", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.5"], interpreter: false),
            "java GradleDaemon 8.5"
        )
        XCTAssertEqual(title(["java", "-version"], interpreter: false), "java")
    }

    func testFallsBackToTheExecutableName() {
        XCTAssertEqual(title([], name: "launchd"), "launchd")
        XCTAssertEqual(title([""], name: "launchd"), "launchd")
    }

    func testLongCommandsAreCapped() {
        let long = ["tool"] + (1...20).map { "arg\($0)" }
        XCTAssertEqual(title(long, interpreter: false).split(separator: " ").count, 6)
    }
}

final class AppBundleTests: XCTestCase {
    func testOutermostBundleNamesTheApp() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        XCTAssertEqual(AppBundle.name(forExecutablePath: helper), "Visual Studio Code")
        XCTAssertEqual(AppBundle.path(forExecutablePath: helper), "/Applications/Visual Studio Code.app")
    }

    func testProgramsOutsideABundleHaveNoApp() {
        XCTAssertNil(AppBundle.name(forExecutablePath: "/opt/homebrew/bin/redis-server"))
        XCTAssertNil(AppBundle.path(forExecutablePath: "/usr/sbin/httpd"))
    }
}

final class StraysFormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(StraysFormat.duration(0), "0s")
        XCTAssertEqual(StraysFormat.duration(45), "45s")
        XCTAssertEqual(StraysFormat.duration(60), "1m")
        XCTAssertEqual(StraysFormat.duration(12 * 60 + 30), "12m")
        XCTAssertEqual(StraysFormat.duration(3 * 3_600), "3h")
        XCTAssertEqual(StraysFormat.duration(3 * 3_600 + 12 * 60), "3h 12m")
        XCTAssertEqual(StraysFormat.duration(2 * 86_400 + 4 * 3_600 + 59), "2d 4h")
        XCTAssertEqual(StraysFormat.duration(86_400), "1d")
        XCTAssertEqual(StraysFormat.duration(-5), "0s")
    }

    func testUptime() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(StraysFormat.uptime(since: now.addingTimeInterval(-7_260), now: now), "2h 1m")
        XCTAssertEqual(StraysFormat.uptime(since: nil, now: now), "–")
    }

    func testMemory() {
        XCTAssertEqual(StraysFormat.memory(0), "0 KB")
        XCTAssertEqual(StraysFormat.memory(800 * 1_024), "800 KB")
        XCTAssertEqual(StraysFormat.memory(312 * 1_048_576), "312 MB")
        XCTAssertEqual(StraysFormat.memory(1_500 * 1_048_576), "1.5 GB")
    }

    func testCPU() {
        XCTAssertEqual(StraysFormat.cpu(0), "0%")
        XCTAssertEqual(StraysFormat.cpu(1.23), "1.2%")
        XCTAssertEqual(StraysFormat.cpu(48.4), "48%")
        XCTAssertEqual(StraysFormat.cpu(212), "212%")
    }
}
