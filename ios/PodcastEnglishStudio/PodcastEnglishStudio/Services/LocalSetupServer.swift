import Foundation
import Darwin
import Network
import PodcastEnglishStudioCore
import CloudSyncKit

struct MobileSetupSubmission: Sendable {
    var settings: [AppConfigurationKey: String]
    var podcastURL: String
    var podcastName: String
    var youtubeURL: String
    var youtubeName: String
    var localMediaForm: [String: String]

    var hasLocalMediaChanges: Bool {
        YTLocalMediaServiceConfig.mobileSetupPatch(from: localMediaForm).hasChanges
    }

    static func parse(form: [String: String]) -> MobileSetupSubmission {
        var settings: [AppConfigurationKey: String] = [:]
        for key in AppConfigurationKey.allCases {
            if let value = form[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                settings[key] = value
            }
        }

        let localMediaKeys = [
            "localMediaEnabled",
            "localMediaBaseURL",
            "localMediaToken",
            "localMediaMode",
            "localMediaPreferredHeight"
        ]
        var localMediaForm: [String: String] = [:]
        for key in localMediaKeys {
            if let value = form[key] {
                localMediaForm[key] = value
            }
        }

        return MobileSetupSubmission(
            settings: settings,
            podcastURL: form["podcastURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            podcastName: form["podcastName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            youtubeURL: form["youtubeURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            youtubeName: form["youtubeName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            localMediaForm: localMediaForm
        )
    }
}

@MainActor
@Observable
final class LocalSetupServer {
    var setupURL: URL?
    var lastError: String?
    var lastMessage = ""
    var isRunning = false

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var token = UUID().uuidString
    @ObservationIgnored private var submitHandler: ((MobileSetupSubmission) async throws -> String)?

    func start(submitHandler: @escaping (MobileSetupSubmission) async throws -> String) {
        self.submitHandler = submitHandler
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: 0)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(state: state)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        setupURL = nil
        isRunning = false
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, let host = LocalNetworkAddress.preferredIPv4Address() else {
                lastError = L10n.string("error.local_network_unavailable", fallback: "The Apple TV local network address is unavailable.")
                return
            }
            setupURL = URL(string: "http://\(host):\(port)/?token=\(token)")
            isRunning = true
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.send(response: .plain("Request failed: \(error.localizedDescription)", status: "400 Bad Request"), on: connection)
                    return
                }
                var nextBuffer = buffer
                if let data { nextBuffer.append(data) }
                if self.isCompleteHTTPRequest(nextBuffer) || isComplete {
                    await self.respond(to: nextBuffer, on: connection)
                } else {
                    self.receiveRequest(from: connection, buffer: nextBuffer)
                }
            }
        }
    }

    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else {
            return false
        }
        let headers = String(text[..<headerRange.lowerBound])
        let bodyStart = text.distance(from: text.startIndex, to: headerRange.upperBound)
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }?
            .split(separator: ":", maxSplits: 1)
            .last
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count >= bodyStart + contentLength
    }

    private func respond(to data: Data, on connection: NWConnection) async {
        guard let request = HTTPRequest(data: data) else {
            send(response: .plain("Invalid request.", status: "400 Bad Request"), on: connection)
            return
        }
        let language = InterfaceLanguagePolicy.bestSupportedLanguage(
            acceptLanguageHeader: request.headers["accept-language"]
        )
        let copy = SetupPageCopy(language: language)

        switch (request.method, request.path) {
        case ("GET", "/"):
            guard request.query["token"] == token else {
                send(response: .plain(copy.expired, status: "403 Forbidden"), on: connection)
                return
            }
            send(response: .html(Self.formHTML(token: token, copy: copy)), on: connection)
        case ("POST", "/submit"):
            guard request.form["token"] == token else {
                send(response: .plain(copy.expired, status: "403 Forbidden"), on: connection)
                return
            }
            do {
                _ = try await submitHandler?(Self.submission(from: request.form))
                let message = copy.submitted
                lastMessage = message
                send(response: .html(Self.successHTML(message: message, copy: copy)), on: connection)
            } catch {
                lastError = error.localizedDescription
                send(response: .html(Self.errorHTML(message: error.localizedDescription, copy: copy), status: "500 Internal Server Error"), on: connection)
            }
        default:
            send(response: .plain("Not found", status: "404 Not Found"), on: connection)
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                connection.cancel()
            }
        })
    }

    private static func submission(from form: [String: String]) -> MobileSetupSubmission {
        MobileSetupSubmission.parse(form: form)
    }

    private static func formHTML(token: String, copy: SetupPageCopy) -> String {
        """
        <!doctype html>
        <html lang="\(copy.language)" dir="\(copy.direction)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>LinguaCast</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #f6f7f9; color: #101418; }
            main { max-width: 720px; margin: 0 auto; padding: 24px 18px 44px; }
            h1 { font-size: 26px; margin: 0 0 6px; }
            h2 { font-size: 18px; margin: 26px 0 12px; }
            p { color: #5d6673; line-height: 1.45; }
            label { display: block; font-size: 13px; font-weight: 600; margin: 14px 0 6px; color: #303946; }
            input, select { width: 100%; box-sizing: border-box; font-size: 17px; padding: 12px; border: 1px solid #cad0d8; border-radius: 10px; background: white; }
            button { width: 100%; margin-top: 26px; padding: 14px 18px; border: 0; border-radius: 12px; background: #1769ff; color: white; font-size: 17px; font-weight: 700; }
            .hint { font-size: 13px; }
          </style>
        </head>
        <body>
          <main>
            <h1>\(htmlEscape(copy.heading))</h1>
            <p>\(htmlEscape(copy.intro))</p>
            <form method="post" action="/submit">
              <input type="hidden" name="token" value="\(htmlEscape(token))">
              <h2>\(htmlEscape(copy.apiSettings))</h2>
              <label>YouTube Data API Key</label>
              <input name="youtubeAPIKey" autocomplete="off">

              <h2>Cloud / Local Media Backend</h2>
              <p class="hint">yt-dlp HD playback. Leave blank to keep current values.</p>
              <label>Use media service</label>
              <select name="localMediaEnabled">
                <option value="">\(htmlEscape(copy.noChange))</option>
                <option value="1">On</option>
                <option value="0">Off</option>
              </select>
              <label>Base URL</label>
              <input name="localMediaBaseURL" placeholder="http://179.253.242.16:3210" inputmode="url" autocomplete="off">
              <label>Bearer Token</label>
              <input name="localMediaToken" autocomplete="off">
              <label>Mode</label>
              <select name="localMediaMode">
                <option value="">\(htmlEscape(copy.noChange))</option>
                <option value="mp4">MP4</option>
                <option value="hls">HLS</option>
              </select>
              <label>Preferred height</label>
              <select name="localMediaPreferredHeight">
                <option value="">\(htmlEscape(copy.noChange))</option>
                <option value="720">720p</option>
                <option value="1080">1080p</option>
              </select>

              <h2>\(htmlEscape(copy.subscriptions))</h2>
              <label>\(htmlEscape(copy.podcastURL))</label>
              <input name="podcastURL" inputmode="url" autocomplete="off">
              <label>\(htmlEscape(copy.podcastName))</label>
              <input name="podcastName" autocomplete="off">
              <label>\(htmlEscape(copy.youtubeURL))</label>
              <input name="youtubeURL" inputmode="url" autocomplete="off">
              <label>\(htmlEscape(copy.youtubeName))</label>
              <input name="youtubeName" autocomplete="off">
              <p class="hint">\(htmlEscape(copy.hint))</p>
              <button type="submit">\(htmlEscape(copy.send))</button>
            </form>
          </main>
        </body>
        </html>
        """
    }

    private static func successHTML(message: String, copy: SetupPageCopy) -> String {
        resultHTML(title: copy.sent, message: message, copy: copy)
    }

    private static func errorHTML(message: String, copy: SetupPageCopy) -> String {
        resultHTML(title: copy.sendFailed, message: message, copy: copy)
    }

    private static func resultHTML(title: String, message: String, copy: SetupPageCopy) -> String {
        """
        <!doctype html>
        <html lang="\(copy.language)" dir="\(copy.direction)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscape(title))</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #f6f7f9; color: #101418; }
            main { max-width: 560px; margin: 0 auto; padding: 48px 20px; }
            h1 { font-size: 28px; }
            p { color: #4d5663; line-height: 1.5; font-size: 17px; }
          </style>
        </head>
        <body><main><h1>\(htmlEscape(title))</h1><p>\(htmlEscape(message))</p></main></body>
        </html>
        """
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct SetupPageCopy {
    let language: String
    let heading: String
    let intro: String
    let apiSettings: String
    let noChange: String
    let subscriptions: String
    let podcastURL: String
    let podcastName: String
    let youtubeURL: String
    let youtubeName: String
    let hint: String
    let send: String
    let sent: String
    let sendFailed: String
    let expired: String
    let submitted: String

    var direction: String { language == "ar" ? "rtl" : "ltr" }

    init(language: String) {
        self.language = language
        switch language {
        case "zh-Hans":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Apple TV 设置", "填写后会直接发送到 Apple TV。留空的设置不会覆盖现有值。", "API 设置", "不修改", "订阅", "播客或 RSS URL", "播客显示名称", "YouTube 频道 URL / RSS / channel id / @handle", "YouTube 显示名称", "iPhone 和 Apple TV 需要在同一个局域网内。提交后请回到 Apple TV 查看结果。", "发送到 Apple TV", "已发送", "发送失败", "二维码已失效，请在 Apple TV 上重新打开扫码页面。", "已提交。")
        case "zh-Hant":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Apple TV 設定", "填寫後會直接傳送到 Apple TV。留白的設定不會覆寫現有值。", "API 設定", "不變更", "訂閱", "Podcast 或 RSS URL", "Podcast 顯示名稱", "YouTube 頻道 URL / RSS / channel id / @handle", "YouTube 顯示名稱", "iPhone 和 Apple TV 必須位於同一個區域網路。提交後請回到 Apple TV 查看結果。", "傳送到 Apple TV", "已傳送", "傳送失敗", "QR Code 已過期，請在 Apple TV 上重新開啟掃描頁面。", "已提交。")
        case "es":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Configuración de Apple TV", "Los datos se enviarán directamente al Apple TV. Los campos vacíos no reemplazarán los valores actuales.", "Ajustes de API", "Sin cambios", "Suscripciones", "URL de podcast o RSS", "Nombre del podcast", "URL / RSS / channel id / @handle de YouTube", "Nombre de YouTube", "El iPhone y el Apple TV deben estar en la misma red local. Vuelve al Apple TV después de enviar.", "Enviar al Apple TV", "Enviado", "Error al enviar", "El código QR ha caducado. Abre de nuevo la página de escaneo en el Apple TV.", "Enviado.")
        case "pt-BR":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Configuração da Apple TV", "Os dados serão enviados diretamente à Apple TV. Campos vazios não substituirão os valores atuais.", "Ajustes da API", "Não alterar", "Assinaturas", "URL de podcast ou RSS", "Nome do podcast", "URL / RSS / channel id / @handle do YouTube", "Nome do YouTube", "O iPhone e a Apple TV precisam estar na mesma rede local. Volte à Apple TV depois de enviar.", "Enviar para a Apple TV", "Enviado", "Falha ao enviar", "O código QR expirou. Abra novamente a página de leitura na Apple TV.", "Enviado.")
        case "ja":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Apple TV の設定", "入力内容は Apple TV に直接送信されます。空欄は現在の値を上書きしません。", "API 設定", "変更しない", "購読", "Podcast または RSS URL", "Podcast の表示名", "YouTube URL / RSS / channel id / @handle", "YouTube の表示名", "iPhone と Apple TV を同じローカルネットワークに接続してください。送信後は Apple TV に戻って結果を確認します。", "Apple TV に送信", "送信済み", "送信できませんでした", "QR コードの有効期限が切れました。Apple TV で読み取りページを開き直してください。", "送信しました。")
        case "ko":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Apple TV 설정", "입력한 내용은 Apple TV로 바로 전송됩니다. 빈 필드는 현재 값을 덮어쓰지 않습니다.", "API 설정", "변경 안 함", "구독", "팟캐스트 또는 RSS URL", "팟캐스트 표시 이름", "YouTube URL / RSS / channel id / @handle", "YouTube 표시 이름", "iPhone과 Apple TV가 같은 로컬 네트워크에 있어야 합니다. 전송 후 Apple TV로 돌아가 결과를 확인하세요.", "Apple TV로 전송", "전송됨", "전송 실패", "QR 코드가 만료되었습니다. Apple TV에서 스캔 페이지를 다시 여세요.", "전송했습니다.")
        case "fr":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Configuration de l’Apple TV", "Les données seront envoyées directement à l’Apple TV. Les champs vides ne remplaceront pas les valeurs existantes.", "Réglages de l’API", "Ne pas modifier", "Abonnements", "URL du podcast ou du flux RSS", "Nom du podcast", "URL / RSS / channel id / @handle YouTube", "Nom YouTube", "L’iPhone et l’Apple TV doivent se trouver sur le même réseau local. Revenez sur l’Apple TV après l’envoi.", "Envoyer à l’Apple TV", "Envoyé", "Échec de l’envoi", "Le code QR a expiré. Rouvrez la page de lecture sur l’Apple TV.", "Envoyé.")
        case "de":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Apple TV einrichten", "Die Angaben werden direkt an das Apple TV gesendet. Leere Felder überschreiben keine vorhandenen Werte.", "API-Einstellungen", "Nicht ändern", "Abonnements", "Podcast- oder RSS-URL", "Podcast-Anzeigename", "YouTube-URL / RSS / channel id / @handle", "YouTube-Anzeigename", "iPhone und Apple TV müssen sich im selben lokalen Netzwerk befinden. Kehre nach dem Senden zum Apple TV zurück.", "An Apple TV senden", "Gesendet", "Senden fehlgeschlagen", "Der QR-Code ist abgelaufen. Öffne die Scan-Seite auf dem Apple TV erneut.", "Gesendet.")
        case "ar":
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("إعداد Apple TV", "ستُرسل البيانات مباشرةً إلى Apple TV. لن تستبدل الحقول الفارغة القيم الحالية.", "إعدادات API", "بدون تغيير", "الاشتراكات", "رابط البودكاست أو RSS", "اسم البودكاست", "رابط YouTube / RSS / channel id / @handle", "اسم YouTube", "يجب أن يكون iPhone وApple TV على الشبكة المحلية نفسها. ارجع إلى Apple TV بعد الإرسال.", "إرسال إلى Apple TV", "تم الإرسال", "فشل الإرسال", "انتهت صلاحية رمز QR. أعد فتح صفحة المسح على Apple TV.", "تم الإرسال.")
        default:
            (heading, intro, apiSettings, noChange, subscriptions, podcastURL, podcastName, youtubeURL, youtubeName, hint, send, sent, sendFailed, expired, submitted) =
                ("Set Up Apple TV", "Your entries are sent directly to Apple TV. Empty fields do not replace existing values.", "API Settings", "No Change", "Subscriptions", "Podcast or RSS URL", "Podcast Display Name", "YouTube URL / RSS / channel id / @handle", "YouTube Display Name", "iPhone and Apple TV must be on the same local network. Return to Apple TV after submitting.", "Send to Apple TV", "Sent", "Send Failed", "The QR code has expired. Reopen the scan page on Apple TV.", "Submitted.")
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let form: [String: String]
    let headers: [String: String]

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let headerRange = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let headerText = String(text[..<headerRange.lowerBound])
        let body = String(text[headerRange.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        method = parts[0]
        let urlParts = parts[1].split(separator: "?", maxSplits: 1).map(String.init)
        path = urlParts.first ?? "/"
        query = urlParts.count > 1 ? Self.parseForm(urlParts[1]) : [:]
        form = Self.parseForm(body)
        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            parsedHeaders[name] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        headers = parsedHeaders
    }

    private static func parseForm(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = parts.first else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            result[decode(String(rawKey))] = decode(rawValue)
        }
        return result
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}

private struct HTTPResponse {
    var data: Data

    static func html(_ body: String, status: String = "200 OK") -> HTTPResponse {
        response(body: body, status: status, contentType: "text/html; charset=utf-8")
    }

    static func plain(_ body: String, status: String = "200 OK") -> HTTPResponse {
        response(body: body, status: status, contentType: "text/plain; charset=utf-8")
    }

    private static func response(body: String, status: String, contentType: String) -> HTTPResponse {
        HTTPResponse(
            data: LocalSetupHTTPResponseBuilder.response(
                body: body,
                status: status,
                contentType: contentType
            )
        )
    }
}

private enum LocalNetworkAddress {
    static func preferredIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidates: [LocalNetworkInterface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            candidates.append(
                LocalNetworkInterface(
                    name: String(cString: interface.ifa_name),
                    address: String(cString: hostname),
                    isUp: flags & IFF_UP != 0,
                    isLoopback: flags & IFF_LOOPBACK != 0
                )
            )
        }

        return LocalNetworkAddressPolicy.preferredIPv4Address(from: candidates)
    }
}
