import Foundation

struct SchemeInfo: Sendable {
    var schemes: [String]
    var configurations: [String]
}

/// Read-only inspection of a local iOS source folder. Never modifies the project.
final class SourceProjectService {
    private static let skippedDirectories: Set<String> = [
        "Pods", "Carthage", ".build", "build", "DerivedData", "node_modules", "SourcePackages", ".git", "vendor",
    ]

    // MARK: Detection

    /// Finds .xcworkspace / .xcodeproj (max depth 4), best candidate first.
    func detectContainers(in root: URL) -> [XcodeContainer] {
        var found: [(XcodeContainer, Int)] = []
        let rootDepth = root.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            let name = url.lastPathComponent
            if depth > 4 || Self.skippedDirectories.contains(name) { enumerator.skipDescendants(); continue }
            switch url.pathExtension {
            case "xcworkspace":
                enumerator.skipDescendants()
                // Skip the internal workspace of a project and the Pods workspace.
                if url.deletingLastPathComponent().pathExtension == "xcodeproj" { continue }
                found.append((XcodeContainer(kind: .workspace, url: url), depth))
            case "xcodeproj":
                enumerator.skipDescendants()
                if name == "Pods.xcodeproj" { continue }
                found.append((XcodeContainer(kind: .project, url: url), depth))
            default: break
            }
        }
        // Shallowest first; within the same depth prefer workspaces (dependency managers generate those).
        return found.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.kind != $1.0.kind { return $0.0.kind == .workspace }
            return $0.0.name < $1.0.name
        }.map(\.0)
    }

    /// Problems that would make the build fail before it starts.
    func preflightIssues(for container: XcodeContainer) -> [String] {
        var issues: [String] = []
        let folder = container.url.deletingLastPathComponent()
        let fm = FileManager.default
        let podfile = fm.fileExists(atPath: folder.appendingPathComponent("Podfile").path)
        if podfile && !fm.fileExists(atPath: folder.appendingPathComponent("Pods").path) {
            issues.append("Podfile found but the Pods folder is missing. Run `pod install` in \(folder.path).")
        }
        if podfile && container.kind == .project {
            issues.append("This project uses CocoaPods; building the .xcodeproj directly will fail. Use the generated .xcworkspace.")
        }
        return issues
    }

    // MARK: Schemes & configurations

    private struct ListOutput: Decodable {
        struct Body: Decodable { let schemes: [String]?; let configurations: [String]? }
        let workspace: Body?
        let project: Body?
    }

    func loadSchemes(for container: XcodeContainer) async throws -> SchemeInfo {
        let listing = try await list(container)
        var schemes = (listing.workspace ?? listing.project)?.schemes ?? []
        schemes = schemes.filter { !$0.hasPrefix("Pods-") }
        guard !schemes.isEmpty else {
            throw AppError("No shared scheme was found in \(container.url.lastPathComponent).",
                           recovery: "In Xcode: Product ▸ Scheme ▸ Manage Schemes ▸ tick “Shared” for the app scheme, then reselect the folder.")
        }
        var configurations = listing.project?.configurations ?? []
        if configurations.isEmpty, container.kind == .workspace {
            // Workspace listings don't include configurations; read them from a sibling project.
            let folder = container.url.deletingLastPathComponent()
            let sibling = folder.appendingPathComponent(container.name + ".xcodeproj")
            if FileManager.default.fileExists(atPath: sibling.path),
               let projectListing = try? await list(XcodeContainer(kind: .project, url: sibling)) {
                configurations = projectListing.project?.configurations ?? []
            }
        }
        if configurations.isEmpty { configurations = ["Debug", "Release"] }
        return SchemeInfo(schemes: schemes, configurations: configurations)
    }

    private func list(_ container: XcodeContainer) async throws -> ListOutput {
        let result = try await ProcessRunner.run("/usr/bin/xcodebuild", [container.flag, container.url.path, "-list", "-json"] + XcodeBuildService.packageArguments(for: container),
                                                 mergeStderr: false)
        guard result.succeeded, let data = JSONExtract.payload(from: result.output),
              let output = try? JSONDecoder().decode(ListOutput.self, from: data) else {
            throw AppError("`xcodebuild -list` failed for \(container.url.lastPathComponent): \(result.errorOutput.tailLines(4))",
                           recovery: "Make sure Xcode is installed, selected (`xcode-select -p`) and the project opens without errors.")
        }
        return output
    }

    // MARK: Persistent folder access

    func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        _ = url?.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: Accessibility identifiers (read-only grep, used to ground AI locators)

    func scanAccessibilityIdentifiers(in root: URL) async -> Set<String> {
        await Task.detached(priority: .utility) { Self.collectIdentifiers(in: root) }.value
    }

    private static func collectIdentifiers(in root: URL) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #"accessibilityIdentifier\s*(?:\(\s*|=\s*)"([^"\\\n]{1,80})""#) else { return [] }
        var identifiers = Set<String>()
        var fileCount = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in enumerator {
            if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            guard ["swift", "m", "mm"].contains(url.pathExtension) else { continue }
            fileCount += 1
            if fileCount > 3000 { break }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { identifiers.insert(String(text[r])) }
            }
        }
        return identifiers
    }
}
