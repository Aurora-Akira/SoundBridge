import Foundation

/// 多语言：简体中文和英文写在代码里 T("中文", "English")，其他语言按英文原文去 strings.json 里查，查不到退回英文。
/// 语言默认跟系统（也支持 iOS「设置 → 声桥 → 语言」），用户也可以在 App 里手动选。
enum Lang {
    struct Language: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    private static let loaded: (languages: [Language], table: [String: [String: String]]) = {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([Language(code: "en", name: "English"), Language(code: "zh-Hans", name: "简体中文")], [:])
        }
        let langs = (root["languages"] as? [[String: String]] ?? []).compactMap { d -> Language? in
            guard let c = d["code"], let n = d["name"] else { return nil }
            return Language(code: c, name: n)
        }
        let table = root["strings"] as? [String: [String: String]] ?? [:]
        return (langs, table)
    }()

    static var languages: [Language] { loaded.languages }

    /// 用户在 App 里手动选的语言；空 = 跟系统
    private(set) static var override: String = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
    private(set) static var code: String = resolve(override)

    static var isChinese: Bool { code == "zh-Hans" || code == "zh-Hant" }

    static func set(_ newCode: String) {
        override = newCode
        code = resolve(newCode)
        UserDefaults.standard.set(newCode, forKey: "appLanguage")
    }

    private static func resolve(_ over: String) -> String {
        if languages.contains(where: { $0.code == over }) { return over }
        return detect()
    }

    private static func detect() -> String {
        let p = (Locale.preferredLanguages.first ?? "en").lowercased()
        if p.hasPrefix("zh") {
            return (p.contains("hant") || p.contains("-tw") || p.contains("-hk") || p.contains("-mo")) ? "zh-Hant" : "zh-Hans"
        }
        let two = String(p.prefix(2))
        return languages.contains(where: { $0.code == two }) ? two : "en"
    }

    static func lookup(zh: String, en: String) -> String {
        switch code {
        case "zh-Hans": return zh
        case "en": return en
        default:
            if let v = loaded.table[en]?[code], !v.isEmpty { return v }
            return en
        }
    }
}

/// 取当前语言的文字；{0} {1} … 依次替换成 args
func T(_ zh: String, _ en: String, _ args: Any...) -> String {
    var s = Lang.lookup(zh: zh, en: en)
    for (i, a) in args.enumerated() {
        s = s.replacingOccurrences(of: "{\(i)}", with: "\(a)")
    }
    return s
}
