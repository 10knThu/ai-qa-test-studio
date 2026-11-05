import XCTest
@testable import AIQATestStudio

/// Integration checks against the real machine (skipped when Xcode / Simulators are missing).
final class EnvironmentTests: XCTestCase {

    func testSimulatorDiscoveryUsesRealSimctl() async throws {
        let devices: [SimulatorDevice]
        do { devices = try await SimulatorService().listDevices() } catch { throw XCTSkip("No simulators: \(error)") }
        XCTAssertFalse(devices.isEmpty)
        XCTAssertTrue(devices.allSatisfy { !$0.udid.isEmpty && !$0.osVersion.isEmpty })
        print("DEVICES:", devices.prefix(3).map(\.displayName))
        let preferred = await MainActor.run { SimulatorViewModel.defaultDevice(in: devices) }
        XCTAssertNotNil(preferred)
    }

    /// Set AIQA_TEST_PROJECT=/path/to/ios/source to also exercise project detection and scheme discovery (read-only).
    func testProjectDetectionAndSchemes() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIQA_TEST_PROJECT"] else { throw XCTSkip("AIQA_TEST_PROJECT not set") }
        let service = SourceProjectService()
        let containers = service.detectContainers(in: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(containers.first, "no Xcode container found")
        print("CONTAINER:", first.displayName)
        let info = try await service.loadSchemes(for: first)
        print("SCHEMES:", info.schemes, info.configurations)
        XCTAssertFalse(info.schemes.isEmpty)
    }
}

final class NavigationAnalysisTests: XCTestCase {
    /// AIQA_TEST_PROJECT=/path AIQA_TEST_GOAL="Shop注文履歴" swift test --filter NavigationAnalysisTests
    func testSourceHintsForScreen() throws {
        guard let path = ProcessInfo.processInfo.environment["AIQA_TEST_PROJECT"],
              let goal = ProcessInfo.processInfo.environment["AIQA_TEST_GOAL"] else { throw XCTSkip("env not set") }
        let analysis = SourceNavigationAnalyzer.analyze(root: URL(fileURLWithPath: path), goal: goal)
        print("HINTS>>>\n\(analysis.hints)\nTEXTS: \(analysis.goalTexts)\n<<<")
        XCTAssertFalse(analysis.hints.isEmpty)
    }

    func testHierarchyParserFindsTitleAndTappables() {
        let xml = """
        <AppiumAUT><XCUIElementTypeApplication type="XCUIElementTypeApplication" name="App" visible="true">
        <XCUIElementTypeNavigationBar type="XCUIElementTypeNavigationBar" name="Shop注文履歴" visible="true"/>
        <XCUIElementTypeButton type="XCUIElementTypeButton" name="Account" label="Account" visible="true"/>
        </XCUIElementTypeApplication></AppiumAUT>
        """
        let elements = UIHierarchyParser.parse(xml)
        XCTAssertTrue(UIHierarchyParser.goalReached(elements, goals: ["Shop注文履歴"]))
        XCTAssertFalse(UIHierarchyParser.goalReached(elements, goals: ["Other"]))
        XCTAssertEqual(elements.filter(\.isInteractive).map(\.key), ["Account"])
    }
}
