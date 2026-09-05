import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct UpdateCheckTests {
    @Test func versionParsingAndComparison() {
        #expect(AppVersion("v0.1.0")! < AppVersion("0.2.0")!)
        #expect(AppVersion("0.9.9")! < AppVersion("1.0")!)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("1.0.1")! > AppVersion("1.0")!)
        #expect(AppVersion("1.2.3-beta.1")! == AppVersion("1.2.3")!)
        #expect(AppVersion("2.0")!.description == "2.0")
        #expect(AppVersion("not-a-version") == nil)
        #expect(AppVersion("") == nil)
    }

    @Test func releaseInfoParsesGitHubShape() throws {
        let json = try JSONValue(
            data: Data(
                #"{"tag_name":"v0.2.0","html_url":"https://github.com/x/y/releases/tag/v0.2.0","draft":false,"prerelease":false,"name":"Claude View 0.2.0"}"#
                    .utf8))
        let release = ReleaseInfo(json: json)
        #expect(release?.tagName == "v0.2.0")
        #expect(release?.version == AppVersion("0.2.0")!)
        #expect(release?.htmlURL.host == "github.com")
    }

    @Test func draftsAndPrereleasesAreIgnored() throws {
        let draft = try JSONValue(
            data: Data(
                #"{"tag_name":"v9.9.9","html_url":"https://github.com/x/y","draft":true,"prerelease":false}"#
                    .utf8))
        #expect(ReleaseInfo(json: draft) == nil)
        let pre = try JSONValue(
            data: Data(
                #"{"tag_name":"v9.9.9","html_url":"https://github.com/x/y","draft":false,"prerelease":true}"#
                    .utf8))
        #expect(ReleaseInfo(json: pre) == nil)
    }

    @Test func developmentBuildsSkipChecks() async {
        let status = await UpdateCheck.run(
            currentVersion: nil, owner: "x", repo: "y")
        guard case .development = status else {
            Issue.record("expected .development for missing version")
            return
        }
    }

    @Test func unparseableVersionsReportUnavailableNotDevelopment() async {
        // A present-but-unparseable bundle version is a config problem worth
        // reporting, not a `swift run` development build. Fails before any
        // networking, so this stays offline.
        let status = await UpdateCheck.run(
            currentVersion: "0.3.0b1", owner: "x", repo: "y")
        guard case .unavailable = status else {
            Issue.record("expected .unavailable for unparseable version")
            return
        }
    }

    /// The release URL is opened with NSWorkspace, which opens whatever
    /// scheme it is handed. It comes off the network; it is checked.
    @Test func onlyWebReleaseURLsAreAccepted() throws {
        func release(_ url: String) -> ReleaseInfo? {
            let json = try? JSONValue(
                data: Data(
                    #"{"tag_name":"v9.9.9","html_url":"\#(url)","draft":false,"prerelease":false}"#
                        .utf8))
            return json.flatMap(ReleaseInfo.init(json:))
        }
        #expect(release("https://github.com/x/y/releases/tag/v9.9.9") != nil)
        #expect(release("http://example.com/r") != nil)
        #expect(release("file:///Applications/Calculator.app") == nil)
        #expect(release("x-apple-something://do-a-thing") == nil)
        #expect(release("") == nil)
    }
}
