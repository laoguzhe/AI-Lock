import Foundation

let suite = "ailock.localization-tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
precondition(L10n.usesEnglish(defaults: defaults, preferredLanguages: ["en-US"]))
precondition(!L10n.usesEnglish(defaults: defaults, preferredLanguages: ["zh-Hans-CN"]))
precondition(L10n.usesEnglish(defaults: defaults, preferredLanguages: ["fr-FR"]))
defaults.set(false, forKey: "overview.followSystemLanguage")
defaults.set(true, forKey: "overview.language")
precondition(L10n.usesEnglish(defaults: defaults, preferredLanguages: ["zh-Hans"]))
defaults.set(false, forKey: "overview.language")
precondition(!L10n.usesEnglish(defaults: defaults, preferredLanguages: ["en"]))

let slot = try! NSRegularExpression(pattern: #"%\{([0-9]+)\}"#)
for (key, english) in L10n.catalog {
    let source = NSMutableString(string: key)
    let target = NSMutableString(string: english)
    for value in [source, target] {
        for match in slot.matches(in: value as String, range: NSRange(location: 0, length: value.length)).reversed() {
            let number = value.substring(with: match.range(at: 1))
            value.replaceCharacters(in: match.range, with: "argument_" + number)
        }
    }
    precondition(L10n.translate(source as String, english: false) == source as String)
    let actual = L10n.translate(source as String, english: true)
    precondition(actual == target as String, "Bad template: \(key) → \(actual); expected \(target)")
}
// Exact templates preserve interpolation values, including Chinese user data and literal slot syntax.
let userName = "我的中文应用 %{0}"
precondition(L10n.translate("查看 \(userName) 详情", english: true) == "View Details for \(userName)")
let path = "/Users/测试/文件/设置.txt"
precondition(L10n.translate("位置：\(path)", english: true) == "Location: \(path)")
precondition(L10n.translate("用户粘贴的 文件、网络 和 设置", english: true) == "用户粘贴的 文件、网络 和 设置")
precondition(L10n.translate("12:34:56  采样发现连接结束", english: true) == "12:34:56  Connection ended at sample time")
precondition(AppSettings.moduleNames["files"] == "文件活动")
precondition(AppSettings.stableModuleCSV("文件活动,网络活动") == "files,network")
print("PASS: language resolution, \(L10n.catalog.count) catalog templates, user content and stable module identifiers")

for (source, target) in [
    ("已选择 1 / 3 块显示器", "1 of 3 displays selected"),
    ("已向 1 块显示器发送命令，2 块失败。请检查 DDC/CI、连接方式及显示器支持情况。", "Commands sent to 1 display(s); 2 failed. Check DDC/CI, the connection, and display compatibility."),
    ("已用 40 GB / 共 100 GB · 可用 60 GB", "Used 40 GB / Total 100 GB · Available 60 GB"),
    ("已备份并清理 3 项异常启动配置。失败 1 项：fixture", "Backed up and removed 3 abnormal startup configuration(s). Failed: 1. Details: fixture"),
    ("录制未能启动：fixture 请在系统设置的“隐私与安全性 → 屏幕与系统录音”中允许 AI Lock 后重试。", "Recording could not start: fixture Allow AI Lock in System Settings > Privacy & Security > Screen & System Audio Recording, then try again.")
] {
    precondition(L10n.translate(source, english: true) == target, "New feature status was not translated: " + source)
    precondition(L10n.translate(source, english: false) == source)
}
print("PASS: new disk, display, startup cleanup and recording statuses in both languages")
