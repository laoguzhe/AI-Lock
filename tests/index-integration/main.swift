import Foundation

let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/.index-fixture-" + UUID().uuidString)
let watched = base.appendingPathComponent("watched")
try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: base) }
try Data([1]).write(to: watched.appendingPathComponent("initial.txt"))
let index = DirectoryIndex(directory: base.appendingPathComponent("cache"))
let analysis = DirectoryAnalysisController(delay: 0.05, index: index)
let monitor = DirectoryActivityMonitor()
monitor.onEvents = { analysis.receive($0) }
defer { monitor.stop(); analysis.stop() }
func countIs(_ count: Int) -> Bool {
    if case .ready(let snapshot) = analysis.activity.state { return snapshot.scannedFiles == count }
    return false
}
func check(_ title: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    guard condition() else {
        if case .failed(let error) = analysis.activity.state { fputs(error + "\n", stderr) }
        fputs("FAIL: " + title + "\n", stderr); exit(1)
    }
    print("PASS: " + title)
}
try monitor.start(root: watched)
analysis.start(root: watched)
check("initial indexed scan") { countIs(1) }
let changed = watched.appendingPathComponent("changed.txt")
try Data([2]).write(to: changed)
check("live FSEvents updates the persistent index") { countIs(2) && index.resumeCursor(root: watched) != nil }
let cursor = index.resumeCursor(root: watched)!
monitor.stop(); analysis.stop()
try Data([3]).write(to: watched.appendingPathComponent("offline.txt"))
try monitor.start(root: watched, since: cursor)
analysis.start(root: watched, resume: true)
check("persisted cursor replays changes made while stopped") { countIs(3) }
try FileManager.default.removeItem(at: changed)
check("live deletion removes indexed metadata") { countIs(2) }
monitor.stop(); analysis.stop()
let stoppedCursor = index.resumeCursor(root: watched)
try Data([4]).write(to: watched.appendingPathComponent("after-stop.txt"))
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check("stopped monitor cannot advance the index cursor", timeout: 0) { index.resumeCursor(root: watched) == stoppedCursor }
