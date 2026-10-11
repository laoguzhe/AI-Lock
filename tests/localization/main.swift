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
