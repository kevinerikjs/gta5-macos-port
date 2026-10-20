import Foundation

/// Player-selectable languages for the app's own text: Rockstar's 13 official GTA V languages, which
/// also set the game's language, plus community translations (docs/TRANSLATING.md). A community
/// language is any other language in Localizable.xcstrings; it shows up here by itself and the game's
/// own text stays English. Untranslated lines fall back to English.
/// The WebAssembly game may ignore the locale even when its resource archive contains it.
struct AppLanguage: Equatable {
    /// What Settings saves and the engine reads (PGSelectedGameLanguage): a game locale like "fr-FR",
    /// or a community language's catalog code like "tr", which the engine treats as English.
    let rawValue: String
    let name: String
    /// Use Apple's compiled String Catalog for every selected language ("fr" → fr.lproj).
    /// App language selection is independent of the phone's system locale.
    private let catalogIdentifier: String

    static let english = AppLanguage(rawValue: "en-US", name: "English", catalogIdentifier: "en")
    static let gameLanguages = [
        english,
        AppLanguage(rawValue: "fr-FR", name: "Français", catalogIdentifier: "fr"),
        AppLanguage(rawValue: "it-IT", name: "Italiano", catalogIdentifier: "it"),
        AppLanguage(rawValue: "de-DE", name: "Deutsch", catalogIdentifier: "de"),
        AppLanguage(rawValue: "es-ES", name: "Español (España)", catalogIdentifier: "es"),
        AppLanguage(rawValue: "ja-JP", name: "日本語", catalogIdentifier: "ja"),
        AppLanguage(rawValue: "ko-KR", name: "한국어", catalogIdentifier: "ko"),
        AppLanguage(rawValue: "pl-PL", name: "Polski", catalogIdentifier: "pl"),
        AppLanguage(rawValue: "pt-BR", name: "Português (Brasil)", catalogIdentifier: "pt-BR"),
        AppLanguage(rawValue: "ru-RU", name: "Русский", catalogIdentifier: "ru"),
        AppLanguage(rawValue: "zh-CN", name: "简体中文", catalogIdentifier: "zh-Hans"),
        AppLanguage(rawValue: "es-MX", name: "Español (Latinoamérica)", catalogIdentifier: "es-419"),
        AppLanguage(rawValue: "zh-TW", name: "繁體中文", catalogIdentifier: "zh-Hant"),
    ]

    /// The catalog's other languages, each named in its own language.
    static let community: [AppLanguage] = {
        let taken = Set(gameLanguages.map(\.catalogIdentifier) + ["Base"])
        return Bundle.main.localizations.filter { !taken.contains($0) }.map { code in
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code) ?? code
            return AppLanguage(rawValue: code, name: name.prefix(1).uppercased(with: locale) + name.dropFirst(), catalogIdentifier: code)
        }.sorted { $0.name < $1.name }
    }()

    static var allCases: [AppLanguage] { gameLanguages + community }

    static let changed = Notification.Name("GTA5PortLanguageChanged")
    private static let storageKey = "gtaPortAppLanguage"

    static var current: AppLanguage {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? english.rawValue
        return allCases.first { $0.rawValue == saved } ?? .english
    }

    static func select(_ language: AppLanguage) {
        guard current != language else { return }
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func bundle(for identifier: String) -> Bundle? {
        guard let url = Bundle.main.url(forResource: identifier, withExtension: "lproj") else { return nil }
        return Bundle(url: url)
    }

    /// Localize by a single stable English key, falling back to English.
    static func choose(_ text: String) -> String {
        #if targetEnvironment(macCatalyst)
        let key = MacText.replacements[text] ?? text
        #else
        let key = text
        #endif
        guard current != .english else { return key }
        let localized = bundle(for: current.catalogIdentifier)?
            .localizedString(forKey: key, value: nil, table: "Localizable")
        if let localized, localized != key { return localized }
        return key
    }

    /// Replace numbered arguments in catalog values without locale-sensitive
    /// percent-formatting; dynamic values are not part of translation keys.
    static func interpolate(_ format: String, _ arguments: [String]) -> String {
        var text = format
        for (index, value) in arguments.enumerated().reversed() {
            text = text.replacingOccurrences(of: "{arg\(index)}", with: value)
        }
        return text
    }
}
