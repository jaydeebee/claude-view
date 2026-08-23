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
}
