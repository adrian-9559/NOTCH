#if os(macOS)
import AppKit
import Foundation

// MARK: - Avisos hacia fuera: Telegram y WhatsApp
//
// Telegram por la API oficial del bot (token en el Keychain): NOTCH
// envía el aviso a tu chat cuando lo activas. WhatsApp no tiene API
// personal oficial: solo se ABRE wa.me con el mensaje (sin auto-envío),
// y solo si lo activas. Todo es opcional y best-effort.

final class ExternalNotify {
    static let shared = ExternalNotify()

    enum Event {
        case done, waiting, reminder
    }

    private let d = UserDefaults.standard

    // Config (el token NO: va al Keychain).
    var tgEnabled: Bool {
        get { d.object(forKey: "notchTgEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "notchTgEnabled") }
    }
    var tgChatId: String {
        get { d.string(forKey: "notchTgChatId") ?? "" }
        set { d.set(newValue, forKey: "notchTgChatId") }
    }
    var tgEvtDone: Bool {
        get { d.object(forKey: "notchTgEvtDone") as? Bool ?? true }
        set { d.set(newValue, forKey: "notchTgEvtDone") }
    }
    var tgEvtWaiting: Bool {
        get { d.object(forKey: "notchTgEvtWaiting") as? Bool ?? true }
        set { d.set(newValue, forKey: "notchTgEvtWaiting") }
    }
    var tgEvtReminder: Bool {
        get { d.object(forKey: "notchTgEvtReminder") as? Bool ?? true }
        set { d.set(newValue, forKey: "notchTgEvtReminder") }
    }
    /// Abrir wa.me al terminar un agente (sin auto-envío).
    var waOpenDone: Bool {
        get { d.object(forKey: "notchWaOpenDone") as? Bool ?? false }
        set { d.set(newValue, forKey: "notchWaOpenDone") }
    }

    private static let tokenAccount = "telegramToken"

    var token: String? { KeychainStore.get(Self.tokenAccount) }

    func setToken(_ t: String) { KeychainStore.set(t, account: Self.tokenAccount) }

    /// Envío real a Telegram. `force` salta los interruptores por evento
    /// (para la prueba manual).
    func send(_ text: String, event: Event, force: Bool = false,
              completion: ((Bool) -> Void)? = nil) {
        guard tgEnabled || force else { completion?(false); return }
        guard !force else {
            // La prueba solo pide token y chat.
            guard let tok = token, !tok.isEmpty, !tgChatId.isEmpty else {
                completion?(false); return
            }
            post(token: tok, text: text, completion: completion)
            return
        }
        switch event {
        case .done where !tgEvtDone: completion?(false); return
        case .waiting where !tgEvtWaiting: completion?(false); return
        case .reminder where !tgEvtReminder: completion?(false); return
        default: break
        }
        guard let tok = token, !tok.isEmpty, !tgChatId.isEmpty else {
            completion?(false); return
        }
        post(token: tok, text: text, completion: completion)
    }

    private func post(token: String, text: String, completion: ((Bool) -> Void)?) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            completion?(false); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": tgChatId,
            "text": text,
        ])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }

    /// Aviso de evento (best-effort: nunca bloquea ni rompe el panel).
    func notify(_ text: String, event: Event) {
        guard tgEnabled else { return }
        send(text, event: event) { ok in
            if !ok { fputs("NOTCH-TG fail event\n", stderr) }
        }
    }

    /// WhatsApp: abre wa.me con el texto (no auto-envía: no hay API
    /// personal oficial).
    func openWhatsApp(_ text: String) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+")
        let enc = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        if let u = URL(string: "https://wa.me/?text=\(enc)") {
            NSWorkspace.shared.open(u)
        }
    }
}
#endif
