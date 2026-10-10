import Foundation

struct ChangedFile: Equatable, Sendable, Identifiable {
    let id: String
    let path: String
    let added: Int
    let removed: Int
}

protocol GitDiffProviding: Sendable {
    func changedFiles(cwd: String) async -> [ChangedFile]
}

struct GitDiffProvider: GitDiffProviding {
    static let maxFiles = 5

    static func parse(numstat: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        for line in numstat.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[2].isEmpty else { continue }
            let path = String(parts[2])
            files.append(ChangedFile(
                id: path,
                path: path,
                added: Int(parts[0]) ?? 0,
                removed: Int(parts[1]) ?? 0
            ))
        }
        let sorted = files.enumerated().sorted { lhs, rhs in
            let l = lhs.element.added + lhs.element.removed
            let r = rhs.element.added + rhs.element.removed
            return l != r ? l > r : lhs.offset < rhs.offset
        }
        return Array(sorted.prefix(maxFiles).map(\.element))
    }

    func changedFiles(cwd: String) async -> [ChangedFile] {
        guard let output = await Self.runGit(cwd: cwd, timeout: 2) else { return [] }
        return Self.parse(numstat: output)
    }

    private static func runGit(cwd: String, timeout: TimeInterval) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", cwd, "diff", "--numstat", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let collector = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > timeout {
                process.terminate()
                return nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = await collector.value
        return String(data: data, encoding: .utf8)
    }
}
