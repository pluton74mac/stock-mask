// Test helper for CrashTests: saves commits as fast as it can and prints "saved <seq>" after each
// one returns, until it is killed. The test kills it with SIGKILL mid-stream, reopens the
// database and checks that every acknowledged commit is there, complete.
//
// usage: CrashProbe DB_PATH SESSION_ID ZONE_ID ITEMS_PER_COMMIT

import Foundation
import StockMaskCore
import simd

let args = CommandLine.arguments
guard args.count == 5, let sessionID = UUID(uuidString: args[2]), let zoneID = UUID(uuidString: args[3]),
    let perCommit = Int(args[4]), perCommit > 0
else {
    FileHandle.standardError.write(Data("usage: CrashProbe DB_PATH SESSION_ID ZONE_ID ITEMS_PER_COMMIT\n".utf8))
    exit(2)
}

do {
    let store = try StockStore.open(at: URL(fileURLWithPath: args[1]))
    var n = 0
    while true {
        n += 1
        let commitID = UUID()
        let items = (0..<perCommit).map { i in
            NewItem(
                id: UUID(), cls: i % 5 == 4 ? .case : .bottle,
                position: SIMD3(Float(n) * 0.5, Float(i) * 0.09, 1.2), confidence: 0.9, groupKey: i % 2)
        }
        let draft = CommitDraft(
            id: commitID, sessionID: sessionID, zoneID: zoneID, anchorID: UUID(), pose: matrix_identity_float4x4,
            keyframePath: "keyframes/\(commitID.uuidString.lowercased()).jpg", trigger: .hold, items: items,
            countedZone: NewCountedZone(id: UUID(), transform: matrix_identity_float4x4, halfExtents: SIMD3(0.45, 0.3, 0.2)),
            possibleMisses: [NewPossibleMiss(id: UUID(), cls: .bottle, position: SIMD3(Float(n), 0, 1))])
        let saved = try store.saveCommit(draft)
        FileHandle.standardOutput.write(Data("saved \(saved.commit.seq)\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("CrashProbe failed: \(error)\n".utf8))
    exit(1)
}
