import SwiftUI

/// Pick one or more languages to translate into: a pop-up menu with a checkmark per chosen
/// language, in the order they were chosen.
struct TranslationTargetsMenu: View {
    let title: LocalizedStringKey
    @Binding var selection: [Locale.Language]
    let languages: [Locale.Language]
    /// The language translated from; it can't also be a target.
    var source: Locale.Language?
    /// Languages this Mac can't translate the source into.
    var unavailable: Set<String> = []
    /// Whether "no translation" is a choice (otherwise at least one language stays chosen).
    var allowsNone = true

    var body: some View {
        LabeledContent(title) {
            Menu(summary) {
                if allowsNone {
                    Button("Don’t translate") { selection = [] }
                    Divider()
                }
                ForEach(languages, id: \.minimalIdentifier) { language in
                    Toggle(Self.name(of: language), isOn: binding(for: language))
                        .disabled(isExcluded(language))
                }
            }
            .fixedSize()
        }
    }

    private var summary: String {
        let names = selection.map(Self.name(of:))
        if names.isEmpty { return String(localized: "Don’t translate") }
        return names.count <= 3 ? names.formatted(.list(type: .and)) : String(localized: "\(names.count) languages")
    }

    private func isExcluded(_ language: Locale.Language) -> Bool {
        language.languageCode == source?.languageCode || unavailable.contains(language.minimalIdentifier)
    }

    private func binding(for language: Locale.Language) -> Binding<Bool> {
        Binding {
            selection.contains { $0.minimalIdentifier == language.minimalIdentifier }
        } set: { on in
            if on {
                selection.append(language)
            } else if allowsNone || selection.count > 1 {
                selection.removeAll { $0.minimalIdentifier == language.minimalIdentifier }
            }
        }
    }

    static func name(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// Chosen languages, remembered between uses ("nl,fr,de").
    static func load(_ key: String) -> [Locale.Language] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map { Locale.Language(identifier: String($0)) }
    }

    static func save(_ languages: [Locale.Language], _ key: String) {
        UserDefaults.standard.set(languages.map(\.minimalIdentifier).joined(separator: ","), forKey: key)
    }
}
