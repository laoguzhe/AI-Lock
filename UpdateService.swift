import AppKit
import CryptoKit
import Foundation

private struct UpdateManifest: Decodable, Sendable {
    let version: String
    let build: String
    let downloadURL: URL
    let sha256: String
}

private enum UpdateError: LocalizedError, Sendable {
    case downloadFailed, checksumMismatch, mountFailed, appMissing, copyFailed, signatureInvalid
    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "The release download failed."
        case .checksumMismatch: return "The downloaded file failed its SHA-256 check."
        case .mountFailed: return "The update disk image could not be mounted."
        case .appMissing: return "The downloaded disk image does not contain AILock.app."
        case .copyFailed: return "The new app could not be staged for installation."
        case .signatureInvalid: return "The downloaded app is not signed by the expected developer."
        }
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var downloadedFileURL: URL?
    private var downloadResponse: URLResponse?

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("AILockUpdate-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedFileURL = destination
            downloadResponse = downloadTask.response
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let downloadedFileURL, let downloadResponse {
            continuation?.resume(returning: (downloadedFileURL, downloadResponse))
        } else {
            continuation?.resume(throwing: UpdateError.downloadFailed)
        }
        continuation = nil
    }
}

private enum UpdateStage: Sendable {
    case downloading, verifying, mounting, copying, validating, restarting
}

@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let manifestURL = URL(string: "https://github.com/laoguzhe/AI-Lock/releases/latest/download/AILock-update.json")!
    private var checking = false
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressDetail: NSTextField?
    private var progressIndicator: NSProgressIndicator?

    private init() {}

    func checkForUpdate(showUpToDate: Bool = false) {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                var request = URLRequest(url: manifestURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 20
                let (data, _) = try await URLSession.shared.data(for: request)
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                guard isNewer(manifest.version, than: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") else {
                    if showUpToDate { showMessage(title: localized("已是最新版本", "You're up to date"), message: localized("当前版本：\(currentVersion)", "Current version: \(currentVersion)")) }
                    return
                }
                offer(manifest)
            } catch {
                if showUpToDate { showMessage(title: localized("检查更新失败", "Update check failed"), message: error.localizedDescription) }
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func offer(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = localized("发现新版本 AI Lock \(manifest.version)", "AI Lock \(manifest.version) is available")
        alert.informativeText = localized("当前版本：\(currentVersion)。点击“立即更新”将下载并安装新版本。", "Current version: \(currentVersion). Choose Update Now to download and install the new version.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized("立即更新", "Update Now"))
        alert.addButton(withTitle: localized("稍后", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(manifest)
    }

    private func install(_ manifest: UpdateManifest) {
        showUpdateProgress()
        Task.detached(priority: .userInitiated) {
            do {
                try await Self.downloadAndInstall(manifest) { stage, fraction, received, total in
                    Task { @MainActor in
                        UpdateService.shared.updateProgress(stage: stage, fraction: fraction, received: received, total: total)
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    UpdateService.shared.closeUpdateProgress()
                    UpdateService.shared.showMessage(title: UpdateService.shared.localized("更新失败", "Update failed"), message: message)
                }
            }
        }
    }

    nonisolated private static func downloadAndInstall(
        _ manifest: UpdateManifest,
        progress: @escaping @Sendable (UpdateStage, Double?, Int64, Int64) -> Void
    ) async throws {
        var request = URLRequest(url: manifest.downloadURL)
        request.timeoutInterval = 300
        progress(.downloading, nil, 0, 0)
        let downloader = UpdateDownloadDelegate { received, total in
            let fraction = total > 0 ? min(1, Double(received) / Double(total)) : nil
            progress(.downloading, fraction, received, total)
        }
        let (downloadURL, response) = try await downloader.download(request)
        defer { try? FileManager.default.removeItem(at: downloadURL) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }
        progress(.verifying, nil, 0, 0)
        let data = try Data(contentsOf: downloadURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else { throw UpdateError.checksumMismatch }

        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("AILockUpdate-\(UUID().uuidString)", isDirectory: true)
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        let staged = work.appendingPathComponent("AILock.app", isDirectory: true)
        var handedOff = false
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            if !handedOff { try? fileManager.removeItem(at: work) }
        }

        progress(.mounting, nil, 0, 0)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, downloadURL.path]
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else { throw UpdateError.mountFailed }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }

        let sourceApp = mount.appendingPathComponent("AILock.app", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceApp.path) else { throw UpdateError.appMissing }
        progress(.copying, nil, 0, 0)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [sourceApp.path, staged.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else { throw UpdateError.copyFailed }

        progress(.validating, nil, 0, 0)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", staged.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.signatureInvalid }
        let inspect = Process()
        let signatureOutput = Pipe()
        inspect.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        inspect.arguments = ["-dv", "--verbose=4", staged.path]
        inspect.standardError = signatureOutput
        try inspect.run()
        let signature = String(data: signatureOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        inspect.waitUntilExit()
        guard inspect.terminationStatus == 0, signature.contains("TeamIdentifier=TQ74Z4L53F") else {
            throw UpdateError.signatureInvalid
        }

        // The staged copy is independent of the mounted image. Detach before handing off.
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mount.path, "-quiet"]
        try detach.run()
        detach.waitUntilExit()
        guard detach.terminationStatus == 0 else { throw UpdateError.mountFailed }

        let currentApp = Bundle.main.bundleURL
        let uid = getuid()
        let installer = work.appendingPathComponent("install.sh")
        try privilegedInstallScript.write(to: installer, atomically: true, encoding: .utf8)
        let handoff = Process()
        handoff.executableURL = URL(fileURLWithPath: "/bin/bash")
        handoff.arguments = ["-c", Self.handoffScript, "AILockUpdater", String(ProcessInfo.processInfo.processIdentifier), installer.path, staged.path, currentApp.path, String(uid)]
        progress(.restarting, nil, 0, 0)
        try handoff.run()
        handedOff = true
        await MainActor.run { NSApp.terminate(nil) }
    }

    private func showUpdateProgress() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = localized("AI Lock 更新", "AI Lock Update")
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: localized("正在准备更新…", "Preparing update…"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(labelWithString: localized("请保持应用打开。", "Please keep the app open."))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 382, height: 12))
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 150))
        title.frame = NSRect(x: 24, y: 106, width: 382, height: 20)
        detail.frame = NSRect(x: 24, y: 78, width: 382, height: 18)
        indicator.frame = NSRect(x: 24, y: 43, width: 382, height: 12)
        content.addSubview(title)
        content.addSubview(detail)
        content.addSubview(indicator)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        progressWindow = window
        progressLabel = title
        progressDetail = detail
        progressIndicator = indicator
        updateProgress(stage: .downloading, fraction: nil, received: 0, total: 0)
    }

    private func updateProgress(stage: UpdateStage, fraction: Double?, received: Int64, total: Int64) {
        guard let indicator = progressIndicator else { return }
        let title: String
        let detail: String
        switch stage {
        case .downloading:
            title = localized("正在下载更新…", "Downloading update…")
            if total > 0 {
                detail = "\(Self.formatBytes(received)) / \(Self.formatBytes(total))  (\(Int((fraction ?? 0) * 100))%)"
            } else if received > 0 {
                detail = localized("已下载 \(Self.formatBytes(received))", "Downloaded \(Self.formatBytes(received))")
            } else {
                detail = localized("正在连接更新服务器…", "Connecting to update server…")
            }
        case .verifying:
            title = localized("正在校验下载文件…", "Verifying downloaded file…")
            detail = localized("正在检查文件完整性", "Checking file integrity")
        case .mounting:
            title = localized("正在读取安装包…", "Opening installer…")
            detail = localized("准备应用文件", "Preparing app files")
        case .copying:
            title = localized("正在准备新版本…", "Preparing new version…")
            detail = localized("复制应用文件中，请稍候", "Copying app files. Please wait.")
        case .validating:
            title = localized("正在验证应用签名…", "Validating app signature…")
            detail = localized("确认更新来自 AI Lock 开发者", "Confirming the update is from the AI Lock developer")
        case .restarting:
            title = localized("正在安装并重启…", "Installing and restarting…")
            detail = localized("应用即将关闭，安装完成后会自动重新打开", "The app will close and reopen when installation is complete")
        }
        progressLabel?.stringValue = title
        progressDetail?.stringValue = detail
        if let fraction {
            indicator.isIndeterminate = false
            indicator.doubleValue = fraction
        } else {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
    }

    private func closeUpdateProgress() {
        progressWindow?.close()
        progressWindow = nil
        progressLabel = nil
        progressDetail = nil
        progressIndicator = nil
    }

    nonisolated private static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    nonisolated private static let handoffScript = #"""
# Wait for the app to exit, then replace it with the signed release bundle.
set -eu
parent_pid="$1"
installer="$2"
staged="$3"
destination="$4"
user_id="$5"
while /bin/kill -0 "$parent_pid" 2>/dev/null; do /bin/sleep 1; done
if /bin/bash "$installer" "$staged" "$destination" "$user_id"; then
  exit 0
fi
if ! /usr/bin/osascript -e 'on run argv
set helperPath to item 1 of argv
set appPath to item 2 of argv
set destinationPath to item 3 of argv
set uidValue to item 4 of argv
do shell script "/bin/bash " & quoted form of helperPath & " " & quoted form of appPath & " " & quoted form of destinationPath & " " & quoted form of uidValue with administrator privileges
end run' "$installer" "$staged" "$destination" "$user_id"; then
  /usr/bin/open -a "$destination"
fi
"""#

    nonisolated private static let privilegedInstallScript = #"""
set -eu
source_app="$1"
destination="$2"
user_id="$3"
parent="$(/usr/bin/dirname "$destination")"
replacement="${destination}.update.$$"
backup="${destination}.backup.$$"
/bin/mkdir -p "$parent"
/usr/bin/ditto "$source_app" "$replacement"
if [ -e "$destination" ]; then /bin/mv "$destination" "$backup"; fi
if ! /bin/mv "$replacement" "$destination"; then
  [ ! -e "$backup" ] || /bin/mv "$backup" "$destination"
  exit 1
fi
if [ "$(/usr/bin/id -u)" -eq 0 ]; then /usr/sbin/chown -R "$user_id" "$destination"; fi
/bin/rm -rf "$backup"
/bin/rm -rf "$(/usr/bin/dirname "$source_app")"
/usr/bin/open -a "$destination"
"""#

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized("好", "OK"))
        alert.runModal()
    }

    private func localized(_ chinese: String, _ english: String) -> String {
        L10n.isEnglish ? english : chinese
    }

}
