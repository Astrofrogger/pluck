import AppKit
import SwiftUI

/// The "ready for review" message (§13.7), in the client page's 10 languages, each editable in Settings › Review.
/// A password is never in it, only a note that it follows; a line whose placeholders all came out empty goes.
enum DeliverMessage {
    static let languages = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"]
    static let names = ["en": "English", "de": "Deutsch", "es": "Español", "fr": "Français", "it": "Italiano", "ja": "日本語",
                        "ko": "한국어", "nl": "Nederlands", "pt-BR": "Português (Brasil)", "zh-Hans": "简体中文"]

    struct Language { var template: String; var hello: String; var password: String; var deadline: String; var expires: String }

    static let defaults: [String: Language] = [
        "en": .init(template: "Hi {recipient},\nHere is \"{title}\" for review: {link}\n{passwordNote}\n{deadlineNote}\nYou can watch and comment in your browser. No account needed.",
                    hello: "Hi,", password: "The password follows in a separate message.", deadline: "Please send your feedback by {date}.", expires: "The link works until {date}."),
        "de": .init(template: "Guten Tag {recipient},\nhier ist „{title}“ zur Abnahme: {link}\n{passwordNote}\n{deadlineNote}\nSie können es im Browser ansehen und kommentieren. Ein Konto ist nicht nötig.",
                    hello: "Guten Tag,", password: "Das Passwort folgt in einer separaten Nachricht.", deadline: "Bitte senden Sie Ihr Feedback bis {date}.", expires: "Der Link funktioniert bis {date}."),
        "es": .init(template: "Hola, {recipient}:\nAquí tiene «{title}» para revisar: {link}\n{passwordNote}\n{deadlineNote}\nPuede verlo y comentarlo en su navegador. No necesita cuenta.",
                    hello: "Hola:", password: "La contraseña llegará en un mensaje aparte.", deadline: "Le rogamos que envíe sus comentarios antes del {date}.", expires: "El enlace funciona hasta el {date}."),
        "fr": .init(template: "Bonjour {recipient},\nVoici « {title} » pour validation : {link}\n{passwordNote}\n{deadlineNote}\nVous pouvez regarder et commenter dans votre navigateur, sans créer de compte.",
                    hello: "Bonjour,", password: "Le mot de passe suivra dans un message séparé.", deadline: "Merci de nous faire part de vos retours avant le {date}.", expires: "Le lien fonctionne jusqu’au {date}."),
        "it": .init(template: "Buongiorno {recipient},\necco «{title}» da revisionare: {link}\n{passwordNote}\n{deadlineNote}\nPuò guardare e commentare dal browser. Non serve alcun account.",
                    hello: "Buongiorno,", password: "La password arriverà in un messaggio separato.", deadline: "La preghiamo di inviare il suo feedback entro il {date}.", expires: "Il link funziona fino al {date}."),
        "ja": .init(template: "{recipient} 様\n「{title}」のご確認をお願いいたします：{link}\n{passwordNote}\n{deadlineNote}\nブラウザで視聴・コメントいただけます。アカウントは不要です。",
                    hello: "お世話になっております。", password: "パスワードは別のメッセージでお送りします。", deadline: "{date}までにフィードバックをお送りください。", expires: "このリンクは{date}まで有効です。"),
        "ko": .init(template: "{recipient}님, 안녕하세요.\n검토하실 「{title}」입니다: {link}\n{passwordNote}\n{deadlineNote}\n브라우저에서 바로 보고 댓글을 남기실 수 있습니다. 계정이 필요 없습니다.",
                    hello: "안녕하세요.", password: "비밀번호는 별도의 메시지로 보내드리겠습니다.", deadline: "{date}까지 의견을 보내 주시기 바랍니다.", expires: "이 링크는 {date}까지 사용할 수 있습니다."),
        "nl": .init(template: "Beste {recipient},\nHierbij „{title}” ter beoordeling: {link}\n{passwordNote}\n{deadlineNote}\nU kunt in uw browser kijken en reageren. Een account is niet nodig.",
                    hello: "Goedendag,", password: "Het wachtwoord volgt in een apart bericht.", deadline: "Wilt u uw feedback uiterlijk {date} sturen?", expires: "De link werkt tot {date}."),
        "pt-BR": .init(template: "Olá, {recipient},\nsegue “{title}” para revisão: {link}\n{passwordNote}\n{deadlineNote}\nVocê pode assistir e comentar no navegador. Não é preciso criar conta.",
                       hello: "Olá,", password: "A senha será enviada em uma mensagem separada.", deadline: "Por favor, envie seu feedback até {date}.", expires: "O link funciona até {date}."),
        "zh-Hans": .init(template: "{recipient}，您好：\n这是待审阅的“{title}”：{link}\n{passwordNote}\n{deadlineNote}\n您可以在浏览器中观看并评论，无需注册账号。",
                         hello: "您好：", password: "密码将通过另一条消息发送。", deadline: "请在{date}之前发送您的反馈。", expires: "该链接有效期至{date}。"),
    ]

    static let key = "reviewMessage."

    /// The app's language when it's one of the 10, else English.
    static var appLanguage: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        if languages.contains(preferred) { return preferred }
        if preferred.hasPrefix("zh") { return preferred.contains("Hant") || preferred.hasSuffix("TW") || preferred.hasSuffix("HK") ? "en" : "zh-Hans" }
        if preferred.hasPrefix("pt") { return "pt-BR" }
        let base = String(preferred.prefix { $0 != "-" && $0 != "_" })
        return languages.contains(base) ? base : "en"
    }

    static func template(_ language: String) -> String {
        UserDefaults.standard.string(forKey: key + language).flatMap { $0.isEmpty ? nil : $0 } ?? defaults[language]?.template ?? defaults["en"]!.template
    }

    /// A long date and time with the time-zone abbreviation, in the message's language.
    static func date(_ date: Date, _ language: String, zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: language)
        format.timeZone = zone
        format.dateStyle = .long
        format.timeStyle = .short
        return format.string(from: date) + " " + (zone.abbreviation(for: date) ?? zone.identifier)
    }

    static func render(_ language: String, title: String, link: String, password: Bool, deadline: Date?, expires: Date?, recipient: String?,
                       template custom: String? = nil, zone: TimeZone = .current) -> String {
        let words = defaults[language] ?? defaults["en"]!
        let recipient = recipient?.trimmingCharacters(in: .whitespaces) ?? ""
        let values = ["{title}": title, "{link}": link, "{recipient}": recipient,
                      "{passwordNote}": password ? words.password : "",
                      "{deadlineNote}": deadline.map { words.deadline.replacingOccurrences(of: "{date}", with: date($0, language, zone: zone)) } ?? "",
                      "{expiresNote}": expires.map { words.expires.replacingOccurrences(of: "{date}", with: date($0, language, zone: zone)) } ?? ""]
        var lines: [String] = []
        for line in (custom ?? template(language)).components(separatedBy: "\n") {
            let used = values.keys.filter { line.contains($0) }
            // A greeting without a name is the plain one; a line whose placeholders all came out empty goes.
            if used.contains("{recipient}"), recipient.isEmpty, used.count == 1 { lines.append(words.hello); continue }
            if !used.isEmpty, used.allSatisfy({ values[$0]!.isEmpty }) { continue }
            lines.append(values.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) })
        }
        return lines.joined(separator: "\n")
    }

    @MainActor static func render(_ link: Deliver.ShareLink, url: String, language: String) -> String {
        render(language, title: link.title, link: url, password: link.passwordHash != nil,
               deadline: DeliverDeadlines.effective(link, store: .shared), expires: link.expires, recipient: link.recipient)
    }
}

/// Copy message (in a language), Share… and Copy QR image.
struct DeliverMessageButtons: View {
    let link: Deliver.ShareLink
    let url: String
    @AppStorage("reviewMessageLanguage") private var language = DeliverMessage.appLanguage

    var body: some View {
        HStack(spacing: 8) {
            Button("Copy Message") { DeliverLinkShare.copy(DeliverMessage.render(link, url: url, language: language)) }
                .buttonStyle(StudioFlatButtonStyle())
            Menu {
                Picker("Message language", selection: $language) {
                    ForEach(DeliverMessage.languages, id: \.self) { Text(verbatim: DeliverMessage.names[$0] ?? $0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { StudioMenuLabel(title: DeliverMessage.names[language] ?? language) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Message language")
            Spacer()
            // (The system's share picker: Mail or Messages with the text; Pluck never sends anything itself.)
            ShareLink(item: DeliverMessage.render(link, url: url, language: language)) { Text("Share…") }.buttonStyle(StudioFlatButtonStyle())
            Button { copyQR() } label: { Label("Copy QR Image", systemImage: "qrcode") }.buttonStyle(StudioFlatButtonStyle())
        }
    }

    private func copyQR() {
        guard let image = DeliverLinkShare.qr(url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

/// Settings › Review › Message: the template per language, with its placeholders.
struct DeliverMessageEditor: View {
    @AppStorage("reviewMessageLanguage") private var language = DeliverMessage.appLanguage
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Language", selection: $language) {
                ForEach(DeliverMessage.languages, id: \.self) { Text(verbatim: DeliverMessage.names[$0] ?? $0).tag($0) }
            }
            .fixedSize()
            TextEditor(text: $text).font(Design.Studio.body).frame(height: 120).scrollContentBackground(.hidden)
                .padding(6).background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius))
            HStack {
                Text(verbatim: "{title} {link} {passwordNote} {deadlineNote} {expiresNote} {recipient}").font(Design.Studio.hint.monospaced()).foregroundStyle(Design.Studio.textQuiet)
                Spacer()
                Button("Default") { UserDefaults.standard.removeObject(forKey: DeliverMessage.key + language); text = DeliverMessage.template(language) }.settingButton()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .onAppear { text = DeliverMessage.template(language) }
        .onChange(of: language) { text = DeliverMessage.template(language) }
        .onChange(of: text) {
            if text != DeliverMessage.defaults[language]?.template { UserDefaults.standard.set(text, forKey: DeliverMessage.key + language) }
        }
    }
}
