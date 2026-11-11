import Foundation
import Testing
@testable import NetMDKit

@Suite struct BackupTests {
    @Test func fileNames() {
        #expect(backupFileName(trackNumber: 3, title: "Song", fileExtension: "aea") == "03 - Song.aea")
        #expect(backupFileName(trackNumber: 12, title: nil, fileExtension: "wav") == "12.wav")
        #expect(backupFileName(trackNumber: 1, title: "  ", fileExtension: "wav") == "01.wav")
        #expect(backupFileName(trackNumber: 1, title: "AC/DC: Live", fileExtension: "wav") == "01 - AC-DC- Live.wav")
        #expect(backupFileName(trackNumber: 1, title: "..hidden", fileExtension: "aea") == "01 - hidden.aea")
    }

    @Test func existingFilesAreNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMD-backup-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(uniqueURL(in: folder, name: "01 - A.wav").lastPathComponent == "01 - A.wav")
        try Data().write(to: folder.appendingPathComponent("01 - A.wav"))
        #expect(uniqueURL(in: folder, name: "01 - A.wav").lastPathComponent == "01 - A (2).wav")
        try Data().write(to: folder.appendingPathComponent("01 - A (2).wav"))
        #expect(uniqueURL(in: folder, name: "01 - A.wav").lastPathComponent == "01 - A (3).wav")
    }
}
