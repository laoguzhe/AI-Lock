import AppKit
let app = NSApplication.shared
let root = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-search-" + UUID().uuidString)
let term = "未索引目录" + UUID().uuidString
let folder = root.appendingPathComponent(term)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = folder.appendingPathComponent("fixture.txt")
try Data("test".utf8).write(to: file)
precondition(SearchResult.item(at: folder).kind == .directory)
precondition(SearchResult.item(at: file).kind == .file)
precondition(SearchResult.item(at: folder).icon.size.width > 0)
precondition(SearchResult.item(at: file).icon.size.width > 0)
let search = QuickSearch(directoryRoots: [root], diskAccessCheck: { true })
var found = false
search.search(term) { results in
    found = results.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() && $0.kind == .directory }
    precondition(Set(results.map(\.id)).count == results.count)
}
let deadline = Date().addingTimeInterval(15)
while !found && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
precondition(found, "Unindexed folders must be found through directory enumeration")
let hiddenFolder = root.appendingPathComponent(".hidden-" + UUID().uuidString)
try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)
let hiddenFile = hiddenFolder.appendingPathComponent(".secret-fixture.txt")
try Data("hidden".utf8).write(to: hiddenFile)
for url in [hiddenFolder, hiddenFile] {
    var matched = false
    search.search(url.lastPathComponent) { results in matched = results.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() } }
    let hiddenDeadline = Date().addingTimeInterval(5)
    while !matched && Date() < hiddenDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(matched, "Hidden folders and files inside them must be searchable")
    search.cancel()
}
print("PASS: hidden folders and hidden nested files are searchable")
var cancelled = false
search.search(term) { _ in precondition(!cancelled, "Cancelled search must not publish stale results") }
search.cancel()
cancelled = true
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
search.search("") { precondition($0.isEmpty) }
print("PASS: unindexed folder search, result types, icons, deduplication and cancellation")

let project = root.appendingPathComponent("项目/DAOSHI-U", isDirectory: true)
try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
var foundCaseInsensitive = false
search.search("daoshi-u") { results in
    foundCaseInsensitive = results.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == project.resolvingSymlinksInPath() && $0.kind == .directory }
}
let caseDeadline = Date().addingTimeInterval(5)
while !foundCaseInsensitive && Date() < caseDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(foundCaseInsensitive, "Lowercase query must find an uppercase folder nested under 项目")
search.cancel()
let lockedSearch = QuickSearch(directoryRoots: [root], diskAccessCheck: { false })
lockedSearch.search("daoshi-u") { results in precondition(!results.contains { $0.path == project.path }) }
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
precondition(lockedSearch.requiresFullDiskAccess, "Missing FDA must gate filesystem search before touching protected folders")
lockedSearch.cancel()
print("PASS: case-insensitive nested folder search and no filesystem traversal without Full Disk Access")

if let actualPath = ProcessInfo.processInfo.environment["AILOCK_VERIFY_SEARCH_DIRECTORY"] {
    let actual = URL(fileURLWithPath: actualPath)
    let actualSearch = QuickSearch(directoryRoots: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")], diskAccessCheck: { true })
    var actualFound = false
    actualSearch.search(actual.lastPathComponent.lowercased()) { results in
        actualFound = results.contains { $0.path == actual.path && $0.kind == .directory }
    }
    let actualDeadline = Date().addingTimeInterval(15)
    while !actualFound && Date() < actualDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    actualSearch.cancel()
    precondition(actualFound, "Real folder search must match the given path")
    print("PASS: lowercase search finds the actual folder: " + actual.path)
}

precondition(LauncherInput.parse("example.com") == .website(URL(string: "https://example.com")!))
precondition(LauncherInput.parse("https://example.com/a?q=x") == .website(URL(string: "https://example.com/a?q=x")!))
precondition(LauncherInput.parse("README.md") == .search("README.md"))
precondition(LauncherInput.parse("juece") == .search("juece"))
precondition(LauncherInput.parse("localhost:3000") == .website(URL(string: "https://localhost:3000")!))
precondition(LauncherInput.parse("> printf 'hello world'") == .command("printf 'hello world'"))
precondition(LauncherInput.parse("rm -rf fixture") == .search("rm -rf fixture"), "Ordinary search must not execute shell commands")
precondition(LauncherInput.parse("javascript:alert(1)") == .search("javascript:alert(1)"))
let script = try LauncherTerminal.writeCommand("printf '%s' 'quote and $literal'", directory: root)
let scriptText = try String(contentsOf: script)
precondition(scriptText.contains("printf '%s' 'quote and $literal'"))
precondition(scriptText.contains("/bin/rm -f -- "))
let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as! NSNumber
precondition(permissions.intValue == 0o700)
let syntax = Process(); syntax.executableURL = URL(fileURLWithPath: "/bin/zsh"); syntax.arguments = ["-n", script.path]
try syntax.run(); syntax.waitUntilExit(); precondition(syntax.terminationStatus == 0)
print("PASS: URL/command classification, literal shell payload and private self-removing script syntax")
if let actualPath = ProcessInfo.processInfo.environment["AILOCK_VERIFY_SEARCH_DIRECTORY"] {
    let cached = QuickSearch(diskAccessCheck: { true })
    let start = Date(); var foundActual = false
    cached.search(URL(fileURLWithPath: actualPath).lastPathComponent) { results in foundActual = results.contains { $0.path == actualPath } }
    let deadline = Date().addingTimeInterval(20)
    while !foundActual && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(foundActual, "Production cached-name search must find the actual project folder")
    print("PASS: production cached/Spotlight search found actual folder in \(Date().timeIntervalSince(start))s")
    cached.cancel()
    let repeatStart = Date(); var repeatFound = false
    cached.search(URL(fileURLWithPath: actualPath).lastPathComponent.uppercased()) { results in repeatFound = results.contains { $0.path == actualPath } }
    let repeatDeadline = Date().addingTimeInterval(5)
    while !repeatFound && Date() < repeatDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(repeatFound, "Warm search must find the same folder case-insensitively")
    print("PASS: warm repeat search found actual folder in \(Date().timeIntervalSince(repeatStart))s")
    cached.cancel()
}
