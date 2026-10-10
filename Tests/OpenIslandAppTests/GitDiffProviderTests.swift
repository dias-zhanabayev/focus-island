import Foundation
import Testing
@testable import OpenIslandApp

struct GitDiffProviderTests {
    @Test
    func parsesRegularRowsSortedByChurn() {
        let files = GitDiffProvider.parse(numstat: "1\t2\ta.swift\n10\t5\tb.swift\n")
        #expect(files.map(\.path) == ["b.swift", "a.swift"])
        #expect(files[0] == ChangedFile(id: "b.swift", path: "b.swift", added: 10, removed: 5))
    }

    @Test
    func binaryRowsCountAsZero() {
        let files = GitDiffProvider.parse(numstat: "-\t-\timg.png\n1\t0\tx.txt")
        #expect(files.map(\.path) == ["x.txt", "img.png"])
        #expect(files[1].added == 0 && files[1].removed == 0)
    }

    @Test
    func keepsSpacesInPaths() {
        let files = GitDiffProvider.parse(numstat: "3\t4\tdir/my file.swift")
        #expect(files.first?.path == "dir/my file.swift")
    }

    @Test
    func limitsToFive() {
        let raw = (1...8).map { "\($0)\t0\tf\($0).txt" }.joined(separator: "\n")
        let files = GitDiffProvider.parse(numstat: raw)
        #expect(files.count == 5)
        #expect(files.first?.path == "f8.txt")
    }

    @Test
    func ignoresMalformedAndEmpty() {
        #expect(GitDiffProvider.parse(numstat: "").isEmpty)
        #expect(GitDiffProvider.parse(numstat: "garbage\n\nx\ty").isEmpty)
    }
}
