import Foundation
import GRDB
import Testing
@testable import StockMaskCore

@Suite("Resume after the app is killed")
struct ResumeTests {
    @Test("The files as a killed app leaves them restore the session, its zone, counts and list")
    func resumeFromFilesOnDisk() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("live/stock.sqlite")
        let world = try World.make(at: url)
        let store = world.store
        let session = try world.startSession()
        let a = try store.saveCommit(makeDraft(session: session, zone: world.deposito, bottles: 6, cases: 1, misses: 1))
        try store.nameGroup(a.groups[0].group.id, sku: world.malbec.id)
        try store.switchZone(sessionID: session.id, to: world.camara.id)
        try store.saveCommit(makeDraft(session: session, zone: world.camara, cans: 12, x: 3))
        let undone = try store.saveCommit(makeDraft(session: session, zone: world.camara, bottles: 2, x: 6))
        try store.undoLastCommit(sessionID: session.id, expecting: undone.commit.id)
        try store.addManualLine(sessionID: session.id, zoneID: world.camara.id, skuID: world.keg.id, looseUnits: 3, note: "llenos")
        try store.setZoneMapFile(world.camara.id, path: "maps/camara.arworldmap")
        let before = try store.snapshot(sessionID: session.id)
        let sheetBefore = try store.stockSheet(sessionID: session.id)

        // Copy the database and its write-ahead log while the store still has them open, without
        // closing or checkpointing: exactly what is on disk if iOS kills the app now.
        let crashed = dir.appendingPathComponent("crashed")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: crashed.appendingPathComponent("stock.sqlite").path + suffix))
            }
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"), "the commits should still be in the WAL")

        let relaunched = try StockStore.open(at: crashed.appendingPathComponent("stock.sqlite"))
        let resumed = try #require(try relaunched.resumeActiveSession())
        #expect(resumed == before)
        #expect(resumed.session.currentZoneID == world.camara.id)
        #expect(resumed.currentZone?.mapFile == "maps/camara.arworldmap")
        #expect(resumed.commits.count == 2)
        #expect(resumed.items(inZone: world.camara.id).count == 12)
        #expect(resumed.items(inZone: world.deposito.id).count == 7)
        #expect(resumed.countedZones(inZone: world.deposito.id).count == 1)
        #expect(resumed.openPossibleMisses(inZone: world.deposito.id).count == 1)
        #expect(try relaunched.stockSheet(sessionID: session.id) == sheetBefore)
        #expect(try relaunched.events(sessionID: session.id) == store.events(sessionID: session.id))
        try relaunched.databaseReader.read { (db: Database) throws in
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
        }
    }

    @Test("No active session: nothing to resume")
    func nothingToResume() throws {
        let world = try World.make()
        #expect(try world.store.resumeActiveSession() == nil)
        let session = try world.startSession()
        try world.store.lockSession(session.id)
        #expect(try world.store.resumeActiveSession() == nil)
    }
}

#if os(macOS)
@Suite("Crash safety")
struct CrashTests {
    /// CrashProbe is built next to the test bundle (…/debug/CrashProbe and
    /// …/debug/StockMaskCorePackageTests.xctest/Contents/MacOS/StockMaskCorePackageTests).
    static var probePath: String? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: name))
        for _ in 0..<5 {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("CrashProbe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    @Test("SIGKILL while writing: every acknowledged commit is there and complete, none is partial")
    func killWhileWriting() throws {
        let probe = try #require(Self.probePath, "CrashProbe was not built next to the test bundle")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stock.sqlite")
        let itemsPerCommit = 20
        let (sessionID, zoneID): (UUID, UUID) = try {
            let world = try World.make(at: url)
            return (try world.startSession().id, world.deposito.id)
        }()

        var acknowledgedTotal = 0
        for round in 1...3 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: probe)
            process.arguments = [url.path, sessionID.uuidString, zoneID.uuidString, "\(itemsPerCommit)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            // Let it acknowledge a few dozen commits, then kill it without warning.
            let target = 10 * round + Int.random(in: 0..<10)
            var acknowledged = 0
            var lastSeq = 0
            var pending = ""
            while acknowledged < target {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }  // the probe exited on its own
                pending += String(decoding: chunk, as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = pending[..<newline]
                    pending = String(pending[pending.index(after: newline)...])
                    if line.hasPrefix("saved "), let seq = Int(line.dropFirst(6)) {
                        acknowledged += 1
                        lastSeq = seq
                    }
                }
            }
            // A random delay lands the kill at different points: mid-transaction, mid-fsync, or
            // just after a commit that wasn't acknowledged yet.
            usleep(UInt32.random(in: 0...4000))
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            #expect(process.terminationReason == .uncaughtSignal, "round \(round): the probe stopped by itself")
            #expect(acknowledged >= target)
            acknowledgedTotal += acknowledged

            let store = try StockStore.open(at: url)
            let snapshot = try store.snapshot(sessionID: sessionID)
            // Every acknowledged commit is there (more may be: committed while their "saved" line
            // was still in the pipe).
            #expect(snapshot.commits.count >= lastSeq)
            try #require(!snapshot.commits.isEmpty)
            #expect(snapshot.commits.map(\.seq) == Array(1...snapshot.commits.count))
            // No partial commit: each has all its items, its zone, its miss and its event.
            let itemsByCommit = Dictionary(grouping: snapshot.items, by: \.commitID)
            for commit in snapshot.commits {
                #expect(itemsByCommit[commit.id]?.count == itemsPerCommit, "commit \(commit.seq) is partial")
            }
            #expect(snapshot.countedZones.count == snapshot.commits.count)
            #expect(snapshot.openPossibleMisses.count == snapshot.commits.count)
            #expect(snapshot.groups.count == snapshot.commits.count * 2)
            #expect(try store.events(sessionID: sessionID).filter { $0.type == .commitSaved }.count == snapshot.commits.count)
            try store.databaseReader.read { (db: Database) throws in
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            let sheet = try store.stockSheet(sessionID: sessionID)
            #expect(sheet.lines.count == snapshot.commits.count * 2)
        }
        #expect(acknowledgedTotal >= 60)
    }
}
#endif
