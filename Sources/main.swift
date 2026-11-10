import AppKit
import AudioToolbox
import CoreText
import QuartzCore
import Foundation

// WordPop — 菜单栏下拉翻译（DeepSeek）
// 仅点击菜单栏「译」时翻译剪贴板；中英互译；正式释义级输出

private enum C {
    static let name = "WordPop"
    static let bundleID = "app.local.wordpop"
    static let apiKeyDefaults = "openai_api_key"
    static let modelDefaults = "openai_model"
    static let baseURLDefaults = "api_base_url"
    static let defaultModel = "deepseek-chat"
    static let defaultBaseURL = "https://api.deepseek.com/v1"
    static let enabledDefaults = "translate_enabled"
    static let speechAccentDefaults = "speech_english_accent"
    static let queryHistoryDefaults = "query_history"
    static let panelW: CGFloat = 432
    static let panelHMin: CGFloat = 272
    static let panelHMax: CGFloat = 880
    static let panelHDefault: CGFloat = 640
    static let caretH: CGFloat = 9
    static let glassRadius: CGFloat = 20
    static let footerGap: CGFloat = 8
    static let footerHeight: CGFloat = 40
    static let footerBottomInset: CGFloat = 8
}

// MARK: - 菜单栏图标（与 SysBar / FlashFind / 轻量日历同规格：17pt 单环 + Times）

private enum MenuIcon {
    private static let badge: CGFloat = 17.0
    private static let ringWidth: CGFloat = 1.45
    private static let ringOn = NSColor.white
    private static let ringOff = NSColor(calibratedWhite: 0.55, alpha: 1)
    private static let letterOn = NSColor(srgbRed: 0.12, green: 0.32, blue: 0.78, alpha: 1)
    private static let letterOff = NSColor(calibratedWhite: 0.55, alpha: 1)

    static func image(paused: Bool = false) -> NSImage {
        let d = badge
        let ringColor = paused ? ringOff : ringOn
        let letterColor = paused ? letterOff : letterOn
        let image = NSImage(size: NSSize(width: d, height: d))
        for scale in [1, 2, 3] as [CGFloat] {
            let px = Int((d * scale).rounded())
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: px,
                pixelsHigh: px,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = NSSize(width: d, height: d)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.imageInterpolation = .high
                ctx.shouldAntialias = true
                NSColor.clear.setFill()
                NSRect(x: 0, y: 0, width: d, height: d).fill()
                let badgeRect = NSRect(x: 0, y: 0, width: d, height: d)
                drawRing(color: ringColor, badgeRect: badgeRect)
                drawCentered(
                    "W",
                    font: timesBold(9),
                    color: letterColor,
                    center: NSPoint(x: d * 0.5, y: d * 0.5)
                )
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }

    private static func timesBold(_ size: CGFloat) -> NSFont {
        for name in ["TimesNewRomanPS-BoldMT", "Times New Roman Bold", "Times-Bold", "TimesNewRomanPSMT"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: .bold)
    }

    private static func drawRing(color: NSColor, badgeRect: NSRect) {
        let inset = ringWidth * 0.5 + 0.15
        let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: inset, dy: inset))
        ring.lineWidth = ringWidth
        ring.lineCapStyle = .round
        ring.lineJoinStyle = .round
        color.setStroke()
        ring.stroke()
    }

    private static func glyphInk(_ s: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [.font: font])
        )
        return CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    }

    private static func drawCentered(
        _ s: String,
        font: NSFont,
        color: NSColor,
        center: NSPoint
    ) {
        let ink = glyphInk(s, font: font)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

// MARK: - Config

private enum Config {
    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: C.apiKeyDefaults)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: C.apiKeyDefaults) }
    }
    static var model: String {
        get {
            let m = UserDefaults.standard.string(forKey: C.modelDefaults)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if m.isEmpty || m.hasPrefix("gpt-") { return C.defaultModel }
            return m
        }
        set { UserDefaults.standard.set(newValue, forKey: C.modelDefaults) }
    }
    static var baseURL: String {
        get {
            let u = UserDefaults.standard.string(forKey: C.baseURLDefaults)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if u.isEmpty || u.contains("openai.com") { return C.defaultBaseURL }
            return u.hasSuffix("/") ? String(u.dropLast()) : u
        }
        set { UserDefaults.standard.set(newValue, forKey: C.baseURLDefaults) }
    }
    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: C.enabledDefaults) == nil { return true }
            return UserDefaults.standard.bool(forKey: C.enabledDefaults)
        }
        set { UserDefaults.standard.set(newValue, forKey: C.enabledDefaults) }
    }

    static var speechAccent: EnglishAccent {
        get { EnglishAccent(rawValue: UserDefaults.standard.string(forKey: C.speechAccentDefaults) ?? "") ?? .american }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: C.speechAccentDefaults) }
    }
}

// MARK: - Fonts

private enum Fonts {
    static func song(_ size: CGFloat) -> NSFont {
        for n in ["华文中宋", "STZhongsong", "STSong", "Songti SC"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return .systemFont(ofSize: size)
    }
    static func times(_ size: CGFloat) -> NSFont {
        for n in ["Times New Roman", "TimesNewRomanPSMT", "Times"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return .systemFont(ofSize: size)
    }
    static func timesItalic(_ size: CGFloat) -> NSFont {
        for n in ["TimesNewRomanPS-ItalicMT", "Times-Italic", "Times New Roman Italic"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return times(size)
    }
    static func mixed(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        out.addAttributes([.font: song(size), .foregroundColor: color], range: full)
        text.enumerateSubstrings(in: text.startIndex..., options: [.byComposedCharacterSequences]) { sub, range, _, _ in
            guard let sub else { return }
            let onlyASCII = sub.unicodeScalars.allSatisfy { $0.isASCII }
            if onlyASCII {
                let ns = NSRange(range, in: text)
                out.addAttribute(.font, value: times(size), range: ns)
            }
        }
        return out
    }
}

// MARK: - Language

private enum LangDetect {
    enum Kind { case english, chinese, mixed, unknown }

    static func detect(_ s: String) -> Kind {
        var latin = 0, cjk = 0, other = 0
        for u in s.unicodeScalars {
            if CharacterSet.letters.contains(u) {
                if (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) {
                    cjk += 1
                } else if u.isASCII {
                    latin += 1
                } else {
                    other += 1
                }
            }
        }
        let total = latin + cjk
        if total == 0 { return .unknown }
        let cjkRatio = Double(cjk) / Double(total)
        if cjkRatio >= 0.45 { return .chinese }
        if Double(latin) / Double(total) >= 0.55 { return .english }
        if cjk > 0 && latin > 0 { return .mixed }
        return cjk > latin ? .chinese : .english
    }

    static func direction(for s: String, flipped: Bool = false) -> (from: String, to: String, label: String) {
        var latin = 0, cjk = 0
        for u in s.unicodeScalars {
            guard CharacterSet.letters.contains(u) else { continue }
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 }
            else if u.isASCII { latin += 1 }
        }
        // 汉字不少于拉丁字母 → 中译英；否则英译中
        var from = "英文"
        var to = "中文"
        if cjk > 0 && cjk >= latin {
            from = "中文"
            to = "英文"
        }
        if flipped {
            swap(&from, &to)
        }
        return (from, to, "\(from.prefix(1)) → \(to.prefix(1))")
    }

    static func displayName(_ s: String) -> String {
        if s.hasPrefix("中") { return "中文" }
        if s.hasPrefix("英") { return "English" }
        return s
    }
}

// MARK: - Token 估算

private enum TokenEst {
    /// 粗估：英文 ~4 字符/token，中文 ~1.5 字/token（业界常用粗算）
    static func estimate(_ s: String) -> Int {
        var latin = 0, cjk = 0, other = 0
        for u in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 }
            else if u.isASCII && CharacterSet.letters.contains(u) { latin += 1 }
            else if !u.properties.isWhitespace { other += 1 }
        }
        let en = Double(latin + other / 2) / 4.0
        let zh = Double(cjk) / 1.5
        return max(1, Int(en + zh + 0.999))
    }
}

// MARK: - DeepSeek 正式翻译

private struct GlossItem: Codable {
    var term: String
    var reading: String
    var gloss: String
}

private struct ExampleItem: Codable {
    var source: String
    var target: String
}

private struct TranslateResult: Codable {
    var fromLang: String
    var toLang: String
    var direction: String
    var source: String
    var main: String
    var glossary: [GlossItem]
    var examples: [ExampleItem]
    var notes: String
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var elapsed: Double

    var tokenSummary: String {
        "本次 API：prompt \(promptTokens) + completion \(completionTokens) = \(totalTokens) tokens"
    }

    var footerMain: String { "\(totalTokens) tokens" }

    var footerSub: String {
        let sec = String(format: "%.1f s", max(0, elapsed))
        return "\(promptTokens) + \(completionTokens) · \(sec)"
    }

    /// 原文计数：中文按字，英文按词
    var sourceCountLabel: String {
        let cjk = source.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        if cjk * 2 >= source.count {
            let n = source.filter { !$0.isWhitespace }.count
            return "\(n) 字"
        }
        let words = source.split { $0.isWhitespace || $0.isNewline }.count
        return "\(max(words, 1)) 词"
    }
}

// MARK: - 本地查询记录

private struct QueryRecord: Codable {
    let id: UUID
    let queriedAt: Date
    let result: TranslateResult
}

private final class QueryHistory {
    static let limit = 100
    private let defaults: UserDefaults
    private(set) var records: [QueryRecord] = []
    private(set) var loadError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: C.queryHistoryDefaults) else { return }
        do {
            records = try JSONDecoder().decode([QueryRecord].self, from: data)
        } catch {
            loadError = "查询记录读取失败：\(error.localizedDescription)"
        }
    }

    func record(_ result: TranslateResult) throws {
        if let loadError {
            throw NSError(domain: C.bundleID, code: 20, userInfo: [NSLocalizedDescriptionKey: loadError])
        }
        var updated = records
        let id: UUID
        if let index = updated.firstIndex(where: {
            $0.result.source == result.source && $0.result.fromLang == result.fromLang && $0.result.toLang == result.toLang
        }) {
            id = updated.remove(at: index).id
        } else {
            id = UUID()
        }
        updated.insert(QueryRecord(id: id, queriedAt: Date(), result: result), at: 0)
        if updated.count > Self.limit { updated.removeLast(updated.count - Self.limit) }
        // 编码成功后再替换，保存失败不覆盖原来的记录。
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: C.queryHistoryDefaults)
        records = updated
    }

    func clear() {
        defaults.removeObject(forKey: C.queryHistoryDefaults)
        records.removeAll()
        loadError = nil
    }
}


private final class Translator {
    private var task: URLSessionDataTask?
    private var session: URLSession?

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 22
        c.timeoutIntervalForResource = 28
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func translate(_ text: String, flipped: Bool = false, completion: @escaping (Result<TranslateResult, Error>) -> Void) {
        cancel()
        let key = Config.apiKey
        guard !key.isEmpty else {
            completion(.failure(err(1, "未设置 DeepSeek API Key（右键「译」→ 设置）")))
            return
        }
        let src = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else {
            completion(.failure(err(2, "剪贴板为空，请先复制要翻译的内容")))
            return
        }
        // 输入越短越快：限制长度并动态 max_tokens
        let clipped = src.count > 600 ? String(src.prefix(600)) : src
        let dir = LangDetect.direction(for: clipped, flipped: flipped)
        let short = clipped.count <= 24
        let maxTok = short ? 720 : (clipped.count <= 120 ? 960 : 1200)

        let system = """
        专业中英词典翻译。只输出一个 JSON 对象，不要 Markdown，不要代码围栏，不要解释，不要星号。
        键：
        translation：字符串，地道译文。
        glossary：数组，1 到 5 条，取自原文里的词或短语。每条含 term、reading、gloss。reading 必填：中文词用带声调的拼音（如 zuòjiā），英文词用音标。gloss 用译文语言，宜短；补充语气时写成「释义 — 说明」。
        examples：数组，1 到 3 条。每条含 source（原文语言的例句）和 target（译文语言的例句）。
        notes：字符串，近义或搭配一句，没有则空字符串。
        不要编造原文里没有的专名。
        """

        let user = "方向：\(dir.from)→\(dir.to)\n原文：\(clipped)"

        guard let url = URL(string: Config.baseURL + "/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 22
        let body: [String: Any] = [
            "model": Config.model,
            "temperature": 0.15,
            "max_tokens": maxTok,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let estIn = TokenEst.estimate(system + user)
        let started = Date()

        let session = Self.makeSession()
        self.session = session
        task = session.dataTask(with: req) { [weak self] data, _, error in
            defer {
                session.finishTasksAndInvalidate()
                DispatchQueue.main.async {
                    guard let self, self.session === session else { return }
                    self.task = nil
                    self.session = nil
                }
            }
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(self?.err(3, "空响应") ?? NSError())) }
                return
            }
            struct API: Decodable {
                struct Choice: Decodable {
                    struct Msg: Decodable { let content: String? }
                    let message: Msg?
                }
                struct Usage: Decodable {
                    let prompt_tokens: Int?
                    let completion_tokens: Int?
                    let total_tokens: Int?
                }
                struct Err: Decodable { let message: String? }
                let choices: [Choice]?
                let usage: Usage?
                let error: Err?
            }
            do {
                let api = try JSONDecoder().decode(API.self, from: data)
                if let m = api.error?.message {
                    throw self?.err(4, m) ?? NSError()
                }
                let content = api.choices?.first?.message?.content?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if content.isEmpty { throw self?.err(5, "译文为空") ?? NSError() }

                let parsed = Self.parseModel(content, fallbackMain: content)
                let promptTokens = api.usage?.prompt_tokens ?? estIn
                let completionTokens = api.usage?.completion_tokens ?? TokenEst.estimate(content)
                var total = api.usage?.total_tokens ?? 0
                if total == 0 { total = promptTokens + completionTokens }
                let result = TranslateResult(
                    fromLang: dir.from,
                    toLang: dir.to,
                    direction: dir.label,
                    source: clipped,
                    main: parsed.main,
                    glossary: parsed.glossary,
                    examples: parsed.pairs,
                    notes: parsed.notes,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: total,
                    elapsed: Date().timeIntervalSince(started)
                )
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                let raw = String(data: data, encoding: .utf8) ?? error.localizedDescription
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: C.bundleID, code: 6, userInfo: [
                        NSLocalizedDescriptionKey: String(raw.prefix(240))
                    ])))
                }
            }
        }
        task?.resume()
    }

    private static func stripStars(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "＊", with: "")
    }

    private struct ParsedModel {
        var main: String
        var notes: String
        var glossary: [GlossItem]
        var pairs: [ExampleItem]
    }

    private static func parseModel(_ raw: String, fallbackMain: String) -> ParsedModel {
        let cleaned = stripStars(raw)
        if let json = jsonObject(in: cleaned) {
            let main = stringField(json, ["translation", "译文", "main"])
            let notes = stringField(json, ["notes", "补充"])
            var glossary: [GlossItem] = []
            if let rows = json["glossary"] as? [[String: Any]] {
                for row in rows.prefix(5) {
                    let term = stringField(row, ["term", "word", "词"])
                    let reading = stringField(row, ["reading", "pinyin", "phonetic", "读音"])
                    let gloss = stringField(row, ["gloss", "meaning", "def", "释义"])
                    if term.isEmpty && gloss.isEmpty { continue }
                    glossary.append(GlossItem(term: term, reading: reading, gloss: gloss))
                }
            }
            var pairs: [ExampleItem] = []
            if let rows = json["examples"] as? [[String: Any]] {
                for row in rows.prefix(3) {
                    let source = stringField(row, ["source", "original", "原文"])
                    let target = stringField(row, ["target", "translation", "译文"])
                    if source.isEmpty && target.isEmpty { continue }
                    pairs.append(ExampleItem(source: source, target: target))
                }
            }
            if !main.isEmpty {
                return ParsedModel(main: main, notes: notes, glossary: glossary, pairs: pairs)
            }
        }
        return parseMarkdown(cleaned, fallbackMain: stripStars(fallbackMain))
    }

    private static func jsonObject(in content: String) -> [String: Any]? {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let start = s.firstIndex(of: "\n") { s = String(s[s.index(after: start)...]) }
            if let end = s.range(of: "```", options: .backwards) { s = String(s[..<end.lowerBound]) }
        }
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") else { return nil }
        let slice = String(s[a...b])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func stringField(_ obj: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let v = obj[key] as? String {
                let t = stripStars(v).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    private static func parseMarkdown(_ md: String, fallbackMain: String) -> ParsedModel {
        func section(_ title: String) -> String {
            let pattern = "##\\s*\(NSRegularExpression.escapedPattern(for: title))\\s*\\n([\\s\\S]*?)(?=\\n##\\s|\\z)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
            let range = NSRange(md.startIndex..., in: md)
            guard let m = re.firstMatch(in: md, range: range), m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: md) else { return "" }
            return stripStars(String(md[r]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let main = section("译文")
        let phonetic = section("读音")
        let detail = section("释义")
        let examples = section("例句")
        let notes = section("补充")
        var glossary: [GlossItem] = []
        let lines = detail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.prefix(5) {
            var text = line
            for prefix in ["- ", "• ", "* "] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            let parts = text.split(separator: "：", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                glossary.append(GlossItem(term: parts[0], reading: "", gloss: parts[1]))
            } else if !text.isEmpty {
                glossary.append(GlossItem(term: text, reading: phonetic == "—" ? "" : phonetic, gloss: ""))
            }
        }
        var pairs: [ExampleItem] = []
        let elines = examples.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var i = 0
        while i < elines.count && pairs.count < 3 {
            let a = elines[i]
            let b = (i + 1 < elines.count) ? elines[i + 1] : ""
            pairs.append(ExampleItem(source: a, target: b))
            i += b.isEmpty ? 1 : 2
        }
        let resolved = main.isEmpty ? fallbackMain : main
        return ParsedModel(main: resolved.isEmpty ? "—" : resolved, notes: notes, glossary: glossary, pairs: pairs)
    }

    private func err(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: C.bundleID, code: code, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - 微软在线神经语音（通过已安装的 edge-tts 客户端）

private enum EnglishAccent: String, CaseIterable {
    case american
    case british

    var title: String { self == .american ? "美式" : "英式" }
    var voice: String { self == .american ? "en-US-JennyNeural" : "en-GB-SoniaNeural" }
}

/// 三个复用缓冲承接 MP3 音频包；无需等整段下载完即可开始播放。
private final class StreamingSpeechPlayer: @unchecked Sendable {
    var onFinish: (() -> Void)?
    private let parserLock = NSRecursiveLock()
    private let condition = NSCondition()
    private var parser: AudioFileStreamID?
    private var queue: AudioQueueRef?
    private var freeBuffers: [AudioQueueBufferRef] = []
    private var filling: AudioQueueBufferRef?
    private var cancelled = false
    private var started = false
    private var inputFinished = false
    private var finished = false
    private var failure: OSStatus = noErr

    init() throws {
        freeBuffers.reserveCapacity(3)
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            { context, stream, property, _ in
                let player = Unmanaged<StreamingSpeechPlayer>.fromOpaque(context).takeUnretainedValue()
                if property == kAudioFileStreamProperty_ReadyToProducePackets {
                    player.prepareQueue(stream)
                }
            },
            { context, bytes, packets, data, descriptions in
                Unmanaged<StreamingSpeechPlayer>.fromOpaque(context).takeUnretainedValue()
                    .receivePackets(bytes: bytes, count: packets, data: data, descriptions: descriptions)
            },
            kAudioFileMP3Type, &parser
        )
        try Self.check(status)
    }

    deinit { stop() }

    var isPlaying: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started && !cancelled && !finished
    }

    private var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    func append(_ data: Data) throws {
        parserLock.lock()
        defer { parserLock.unlock() }
        guard !isCancelled, let parser else { throw CocoaError(.userCancelled) }
        let status = data.withUnsafeBytes {
            AudioFileStreamParseBytes(parser, UInt32($0.count), $0.baseAddress, [])
        }
        try Self.check(status)
        try Self.check(failure)
    }

    func finishInput() throws {
        parserLock.lock()
        defer { parserLock.unlock() }
        guard !isCancelled, let parser else { throw CocoaError(.userCancelled) }
        try Self.check(AudioFileStreamParseBytes(parser, 0, nil, []))
        flushBuffer()
        try Self.check(failure)
        guard let queue, isPlaying else {
            throw NSError(domain: C.bundleID, code: -1, userInfo: [NSLocalizedDescriptionKey: "未收到可播放的语音音频。"])
        }
        condition.lock()
        inputFinished = true
        condition.unlock()
        try Self.check(AudioQueueStop(queue, false))
    }

    func stop() {
        condition.lock()
        let wasCancelled = cancelled
        cancelled = true
        condition.broadcast()
        condition.unlock()
        guard !wasCancelled else { return }
        parserLock.lock()
        defer { parserLock.unlock() }
        // 先唤醒可能在等待空缓冲的解码线程，再同步释放队列。
        if let queue {
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        if let parser {
            AudioFileStreamClose(parser)
            self.parser = nil
        }
        condition.lock()
        freeBuffers.removeAll()
        condition.unlock()
        filling = nil
    }

    private func prepareQueue(_ stream: AudioFileStreamID) {
        guard queue == nil, failure == noErr else { return }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        failure = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &format)
        guard failure == noErr else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        failure = AudioQueueNewOutput(&format, { context, _, buffer in
            guard let context else { return }
            let player = Unmanaged<StreamingSpeechPlayer>.fromOpaque(context).takeUnretainedValue()
            player.condition.lock()
            if !player.cancelled {
                player.freeBuffers.append(buffer)
                player.condition.signal()
            }
            player.condition.unlock()
        }, context, nil, nil, 0, &queue)
        guard failure == noErr, let queue else { return }
        failure = AudioQueueAddPropertyListener(queue, kAudioQueueProperty_IsRunning, { context, queue, property in
            guard let context else { return }
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioQueueGetProperty(queue, property, &running, &size) == noErr, running == 0 else { return }
            let player = Unmanaged<StreamingSpeechPlayer>.fromOpaque(context).takeUnretainedValue()
            player.condition.lock()
            let completed = player.inputFinished && !player.cancelled && !player.finished
            if completed { player.finished = true }
            player.condition.unlock()
            if completed { player.onFinish?() }
        }, context)
        guard failure == noErr else { return }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            failure = AudioQueueAllocateBufferWithPacketDescriptions(queue, 8192, 64, &buffer)
            guard failure == noErr, let buffer else { return }
            condition.lock()
            freeBuffers.append(buffer)
            condition.unlock()
        }
    }

    private func takeBuffer() -> AudioQueueBufferRef? {
        condition.lock()
        defer { condition.unlock() }
        while freeBuffers.isEmpty && !cancelled { condition.wait() }
        guard !cancelled, let buffer = freeBuffers.popLast() else { return nil }
        buffer.pointee.mAudioDataByteSize = 0
        buffer.pointee.mPacketDescriptionCount = 0
        return buffer
    }

    private func receivePackets(bytes: UInt32, count: UInt32, data: UnsafeRawPointer,
                                descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard count > 0, failure == noErr, !isCancelled else { return }
        for index in 0..<Int(count) {
            var packet = descriptions?[index] ?? AudioStreamPacketDescription(
                mStartOffset: Int64(index) * Int64(bytes / count),
                mVariableFramesInPacket: 0, mDataByteSize: bytes / count
            )
            guard packet.mStartOffset >= 0,
                  packet.mStartOffset + Int64(packet.mDataByteSize) <= Int64(bytes),
                  packet.mDataByteSize <= 8192 else {
                failure = kAudioFileInvalidPacketOffsetError
                return
            }
            if filling == nil { filling = takeBuffer() }
            guard let buffer = filling else { return }
            if buffer.pointee.mAudioDataByteSize + packet.mDataByteSize > buffer.pointee.mAudioDataBytesCapacity
                || buffer.pointee.mPacketDescriptionCount == buffer.pointee.mPacketDescriptionCapacity {
                flushBuffer()
                guard failure == noErr else { return }
                filling = takeBuffer()
            }
            guard let current = filling else { return }
            let offset = current.pointee.mAudioDataByteSize
            memcpy(current.pointee.mAudioData.advanced(by: Int(offset)),
                   data.advanced(by: Int(packet.mStartOffset)), Int(packet.mDataByteSize))
            packet.mStartOffset = Int64(offset)
            current.pointee.mPacketDescriptions![Int(current.pointee.mPacketDescriptionCount)] = packet
            current.pointee.mPacketDescriptionCount += 1
            current.pointee.mAudioDataByteSize += packet.mDataByteSize
            // 约 240ms 的 48kbps 音频即可起播，不积攒整段译文。
            if current.pointee.mAudioDataByteSize >= 1440 {
                flushBuffer()
                guard failure == noErr else { return }
            }
        }
    }

    private func flushBuffer() {
        guard failure == noErr, !isCancelled, let queue, let buffer = filling,
              buffer.pointee.mAudioDataByteSize > 0 else { return }
        failure = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard failure == noErr else { return }
        filling = nil
        condition.lock()
        let needsStart = !started
        condition.unlock()
        if needsStart {
            failure = AudioQueueStart(queue, nil)
            if failure == noErr {
                condition.lock()
                started = true
                condition.unlock()
            }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "语音流播放失败（\(status)）。"])
        }
    }
}

private final class Speaker {
    static let shared = Speaker()
    var onError: ((String) -> Void)?
    private var requestID: UUID?
    private var process: Process?
    private var player: StreamingSpeechPlayer?
    private static let executable = findExecutable()
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 16
        cache.totalCostLimit = 1_048_576
        return cache
    }()

    private final class Diagnostics: @unchecked Sendable {
        var data = Data()
    }

    func speak(source: String, language: String) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        let id = UUID()
        requestID = id
        let voice = language.hasPrefix("中") ? "zh-CN-XiaoxiaoNeural" : Config.speechAccent.voice
        let key = "\(voice)\u{0}\(text)" as NSString
        let cached = cache.object(forKey: key)
        guard cached != nil || Self.executable != nil else {
            failed("未找到 edge-tts。请运行 python3 -m pip install --upgrade edge-tts，安装后重新打开 WordPop。", request: id)
            return
        }
        let playback: StreamingSpeechPlayer
        do {
            playback = try StreamingSpeechPlayer()
        } catch {
            failed(error.localizedDescription, request: id)
            return
        }
        player = playback
        playback.onFinish = { [weak self, weak playback] in
            DispatchQueue.main.async {
                guard let self, self.requestID == id, self.player === playback else { return }
                self.stop()
            }
        }
        if let cached {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try playback.append(cached as Data)
                    try playback.finishInput()
                } catch {
                    DispatchQueue.main.async { self?.failed(error.localizedDescription, request: id) }
                }
            }
            return
        }

        let task = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        task.executableURL = Self.executable
        task.arguments = ["--voice", voice, "--file", "-", "--write-media", "-", "--no-progress"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment
        task.standardInput = input
        task.standardOutput = output
        task.standardError = errors
        do {
            try task.run()
        } catch {
            failed("无法启动在线语音客户端：\(error.localizedDescription)", request: id)
            return
        }
        process = task
        let inputData = Data(text.utf8)
        let cache = self.cache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diagnostics = Diagnostics()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                diagnostics.data = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            var audio = Data()
            audio.reserveCapacity(16_384)
            var streamError: String?
            do {
                try input.fileHandleForWriting.write(contentsOf: inputData)
                try input.fileHandleForWriting.close()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    try playback.append(chunk)
                    audio.append(chunk)
                }
            } catch {
                streamError = error.localizedDescription
                try? input.fileHandleForWriting.close()
                if task.isRunning { task.terminate() }
            }
            task.waitUntilExit()
            group.wait()
            if task.terminationStatus == 0, streamError == nil, !audio.isEmpty {
                do {
                    try playback.finishInput()
                    cache.setObject(audio as NSData, forKey: key, cost: audio.count)
                    DispatchQueue.main.async {
                        guard let self, self.requestID == id else { return }
                        self.process = nil
                    }
                    return
                } catch {
                    streamError = error.localizedDescription
                }
            }
            let failure = streamError ?? String(data: diagnostics.data, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "未收到语音音频。"
            DispatchQueue.main.async {
                self?.failed("在线朗读失败，请检查网络后重试。\n\(failure.prefix(240))", request: id)
            }
        }
    }

    func stop() {
        requestID = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        player?.stop()
        player = nil
    }

    private func failed(_ message: String, request: UUID) {
        guard requestID == request else { return }
        stop()
        onError?(message)
    }

    private static func findExecutable() -> URL? {
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let versions = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions", isDirectory: true)
        if let runtimes = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            paths += runtimes.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                .map { $0.appendingPathComponent("bin").path }
        }
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("edge-tts") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}


// MARK: - 翻译卡片

private enum Chrome {
    static var glass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

private enum Ink {
    static func dark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static func text(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: 1)
    }
    static func secondary(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.78, green: 0.74, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.40, green: 0.38, blue: 0.34, alpha: 1)
    }
    static func tertiary(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.64, green: 0.60, blue: 0.54, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.52, blue: 0.47, alpha: 1)
    }
    static func rust(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.88, green: 0.56, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.34, blue: 0.26, alpha: 1)
    }
    static func card(_ dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.72)
    }
    static func line(_ dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor(srgbRed: 0.12, green: 0.10, blue: 0.08, alpha: 0.14)
    }
    static func chip(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)
    }
    static func onChip(_ dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
    }
}

private final class LangSwitch: NSView {
    var from = "中文"
    var to = "英文"
    var onSwap: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 196, height: 36) }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = Ink.dark(self)
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), xRadius: 18, yRadius: 18)
        NSColor.white.withAlphaComponent(dark ? 0.08 : 0.58).setFill()
        capsule.fill()
        Ink.line(dark).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let fromTitle = LangDetect.displayName(from)
        let toTitle = LangDetect.displayName(to)
        let fromFont = fromTitle == "English" ? Fonts.times(13) : Fonts.song(13)
        let toFont = toTitle == "English" ? Fonts.times(13) : Fonts.song(13)
        let fromW = ceil((fromTitle as NSString).size(withAttributes: [.font: fromFont]).width) + 26
        let chipRect = NSRect(x: 3, y: 3, width: fromW, height: bounds.height - 6)
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: chipRect.height / 2, yRadius: chipRect.height / 2)
        Ink.chip(dark).setFill()
        chip.fill()

        drawCentered(fromTitle, font: fromFont, color: Ink.onChip(dark), in: chipRect)
        let arrow = "⇄" as NSString
        let arrowFont = Fonts.times(13)
        let arrowW = arrow.size(withAttributes: [.font: arrowFont]).width
        let arrowRect = NSRect(x: chipRect.maxX + 8, y: 0, width: arrowW + 4, height: bounds.height)
        drawCentered("⇄", font: arrowFont, color: Ink.tertiary(dark), in: arrowRect)

        let toW = ceil((toTitle as NSString).size(withAttributes: [.font: toFont]).width)
        let toRect = NSRect(x: bounds.width - 14 - toW, y: 0, width: toW + 2, height: bounds.height)
        drawCentered(toTitle, font: toFont, color: Ink.secondary(dark), in: toRect)
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        let size = attr.size()
        let box = NSRect(
            x: rect.minX,
            y: rect.midY - size.height / 2,
            width: rect.width,
            height: size.height
        )
        attr.draw(in: box)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        onSwap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class ClickControl: NSView {
    var onClick: (() -> Void)?
    var fill: NSColor = .clear
    var stroke: NSColor?
    var radius: CGFloat = 20
    var image: NSImage?
    var title: NSAttributedString?
    var box = NSSize(width: 40, height: 40)

    override var intrinsicContentSize: NSSize { box }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1.15
            path.stroke()
        }
        let titleSize = title?.size() ?? .zero
        let imgSide: CGFloat = image == nil ? 0 : 15
        let gap: CGFloat = (image != nil && title != nil) ? 6 : 0
        let total = imgSide + gap + titleSize.width
        var x = (bounds.width - total) / 2
        if let image {
            let r = NSRect(x: x, y: (bounds.height - imgSide) / 2, width: imgSide, height: imgSide)
            image.draw(in: r)
            x += imgSide + gap
        }
        if let title {
            let rect = NSRect(
                x: x,
                y: (bounds.height - titleSize.height) / 2,
                width: ceil(titleSize.width) + 1,
                height: ceil(titleSize.height)
            )
            title.draw(in: rect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 宋体字身比单行文本框高，NSTextField 会把中文底部裁掉。这里按字身矩形来画。
private final class GlyphLabel: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 16) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var color = NSColor.black { didSet { needsDisplay = true } }
    var columnWidth: CGFloat = 128 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: columnWidth, height: textHeight)
    }

    private var textHeight: CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = attributed().boundingRect(
            with: NSSize(width: max(1, columnWidth - 2), height: 600),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height) + 4
    }

    private func attributed() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let box = NSRect(x: 0, y: 1, width: max(0, bounds.width - 1), height: max(0, bounds.height - 2))
        attributed().draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

private final class DropPanel: NSView {
    var onCopyResult: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSwap: (() -> Void)?
    var onPreferHeight: ((CGFloat) -> Void)?
    var onHistory: ((NSView) -> Void)?

    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let footerHost = NSView()
    private var mode: Mode = .message("复制中文或英文后，点击菜单栏图标。")
    private var exampleIndex = 0
    private var fromShown = "中文"
    private var toShown = "英文"
    private var lastMain = ""
    private var speakText = ""
    private var speakDirection = ""
    private var showingHistoryRecord = false
    private let wash = CAGradientLayer()

    private enum Mode {
        case message(String)
        case loading(source: String, from: String, to: String)
        case ready(TranslateResult)
    }

    var mainTranslation: String { lastMain }
    private var dark: Bool { Ink.dark(self) }
    private var innerW: CGFloat { C.panelW - 40 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        if Chrome.glass {
            layer?.backgroundColor = NSColor.clear.cgColor
            wash.colors = [
                NSColor(srgbRed: 0.99, green: 0.97, blue: 0.94, alpha: 0.42).cgColor,
                NSColor(srgbRed: 0.97, green: 0.86, blue: 0.76, alpha: 0.28).cgColor,
                NSColor(srgbRed: 0.86, green: 0.90, blue: 0.86, alpha: 0.22).cgColor,
            ]
            wash.locations = [0, 0.62, 1]
            wash.startPoint = CGPoint(x: 0.5, y: 1)
            wash.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.insertSublayer(wash, at: 0)
        } else {
            layer?.backgroundColor = NSColor(srgbRed: 0.972, green: 0.957, blue: 0.938, alpha: 1).cgColor
            layer?.cornerRadius = C.glassRadius
        }

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        footerHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerHost)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 8, right: 20)
        column.setContentCompressionResistancePriority(.required, for: .vertical)
        column.setContentHuggingPriority(.defaultHigh, for: .vertical)
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = column

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerHost.topAnchor, constant: -C.footerGap),
            footerHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footerHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            footerHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -C.footerBottomInset),
            footerHost.heightAnchor.constraint(equalToConstant: C.footerHeight),
            column.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // 低优先级底边：内容更高时文档可以高出视口，从顶部往下排，而不是把标题裁掉。
        let grow = column.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor)
        grow.priority = NSLayoutConstraint.Priority(200)
        grow.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { !Chrome.glass ? true : false }

    override func layout() {
        super.layout()
        if Chrome.glass {
            wash.frame = bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    func showPlaceholder(_ s: String) {
        showingHistoryRecord = false
        lastMain = ""
        speakText = ""
        mode = .message(s)
        render()
    }

    func showLoading(_ source: String, from: String, to: String) {
        showingHistoryRecord = false
        fromShown = from
        toShown = to
        lastMain = ""
        speakText = ""
        Speaker.shared.stop()
        mode = .loading(source: source, from: from, to: to)
        render()
    }

    func showError(_ msg: String) {
        showingHistoryRecord = false
        lastMain = ""
        speakText = ""
        mode = .message(msg)
        render()
    }

    func show(result: TranslateResult, fromHistory: Bool = false) {
        showingHistoryRecord = fromHistory
        exampleIndex = 0
        fromShown = result.fromLang
        toShown = result.toLang
        lastMain = result.main
        speakText = result.main
        speakDirection = result.toLang
        mode = .ready(result)
        render()
    }

    private func render() {
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        add(header())
        switch mode {
        case .message(let text):
            let body = wrap(text, font: Fonts.song(16), color: Ink.secondary(dark), spacing: 4, width: textW)
            add(softCard(body))
        case .loading(let source, _, _):
            add(sourceCard(source, count: countLabel(source)))
            add(translationCard("正在翻译…", glossary: [], loading: true))
        case .ready(let result):
            add(sourceCard(result.source, count: result.sourceCountLabel))
            add(translationCard(result.main, glossary: result.glossary, loading: false))
            if !result.glossary.isEmpty {
                add(glossaryBlock(result.glossary))
            }
            if !result.examples.isEmpty {
                let i = min(exampleIndex, result.examples.count - 1)
                exampleIndex = i
                add(exampleBlock(result.examples, index: i))
            }
            if !result.notes.isEmpty {
                add(wrap(result.notes, font: Fonts.song(13), color: Ink.tertiary(dark), spacing: 3, width: innerW))
            }
        }
        installFooter()
        publishHeight()
    }

    private func installFooter() {
        footerHost.subviews.forEach { $0.removeFromSuperview() }
        let bar = footer()
        bar.translatesAutoresizingMaskIntoConstraints = false
        footerHost.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: footerHost.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: footerHost.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: footerHost.centerYAnchor),
        ])
    }

    private func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: innerW).isActive = true
    }

    private var textW: CGFloat { innerW - 32 }

    private func publishHeight() {
        onPreferHeight?(measuredHeight())
        scrollToTop()
    }

    private func scrollToTop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.column.layoutSubtreeIfNeeded()
            let clip = self.scroll.contentView
            clip.scroll(to: .zero)
            self.scroll.reflectScrolledClipView(clip)
        }
    }

    private func measuredHeight() -> CGFloat {
        column.layoutSubtreeIfNeeded()
        let footerSpace = C.footerGap + C.footerHeight + C.footerBottomInset
        let fit = column.fittingSize.height + footerSpace
        if fit > 120 { return fit }
        let gaps = CGFloat(max(0, column.arrangedSubviews.count - 1)) * column.spacing
        let sum = column.arrangedSubviews.reduce(CGFloat(0)) { partial, view in
            partial + max(view.fittingSize.height, view.intrinsicContentSize.height)
        }
        return sum + gaps + footerSpace
    }

    // MARK: Header

    private func header() -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let title = NSTextField(labelWithString: showingHistoryRecord ? "历史结果" : "翻译结果")
        title.font = Fonts.song(30)
        title.textColor = Ink.text(dark)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lang = LangSwitch()
        lang.from = fromShown
        lang.to = toShown
        lang.onSwap = { [weak self] in self?.onSwap?() }
        lang.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(title)
        row.addArrangedSubview(lang)
        row.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.addArrangedSubview(kicker(showingHistoryRecord ? "HISTORY" : "TRANSLATE",
                                       showingHistoryRecord ? "查询记录" : "翻译", color: Ink.rust(dark), size: 11))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tools.addArrangedSubview(spacer)
        let history = ClickControl()
        history.box = NSSize(width: 82, height: 24)
        history.image = symbol("clock.arrow.circlepath", point: 13, color: Ink.secondary(dark))
        history.title = NSAttributedString(string: "查询记录", attributes: [
            .font: Fonts.song(12), .foregroundColor: Ink.secondary(dark)
        ])
        history.toolTip = "查看查询记录（仅保存在本机）"
        history.onClick = { [weak self, weak history] in
            guard let history else { return }
            self?.onHistory?(history)
        }
        tools.addArrangedSubview(history)
        block.addArrangedSubview(tools)
        tools.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        block.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    // MARK: Cards

    private func sourceCard(_ text: String, count: String) -> NSView {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.addArrangedSubview(headRow(en: "SOURCE", zh: "原文", trailing: count, italic: false))
        inner.addArrangedSubview(wrap(text, font: Fonts.song(15.5), color: Ink.text(dark), spacing: 4, width: textW))
        pin(inner, width: textW)
        return softCard(inner)
    }

    private func translationCard(_ text: String, glossary: [GlossItem], loading: Bool) -> NSView {
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        let trailing = LangDetect.displayName(toShown)
        inner.addArrangedSubview(headRow(en: "TRANSLATION", zh: "译文", trailing: trailing, italic: true))
        if loading {
            inner.addArrangedSubview(wrap(text, font: Fonts.song(18), color: Ink.tertiary(dark), spacing: 4, width: textW))
        } else {
            let zh = cjkHeavy(text)
            let attr = translationText(text, glossary: glossary, chinese: zh)
            inner.addArrangedSubview(wrapAttr(attr, width: textW))
        }
        pin(inner, width: textW)
        return softCard(inner)
    }

    private func softCard(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 18
        box.layer?.backgroundColor = Ink.card(dark).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
        ])
        return box
    }

    private func glossaryBlock(_ items: [GlossItem]) -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 0
        block.addArrangedSubview(headRow(en: "GLOSSARY", zh: "释义", trailing: "\(items.count) 条", italic: false))
        block.addArrangedSubview(rule())
        for (i, item) in items.enumerated() {
            block.addArrangedSubview(glossRow(i + 1, item, last: i == items.count - 1))
        }
        return block
    }

    private func glossRow(_ index: Int, _ item: GlossItem, last: Bool) -> NSView {
        let wrap = NSStackView()
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 0

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        let num = GlyphLabel()
        num.text = String(format: "%02d", index)
        num.font = Fonts.times(13)
        num.color = Ink.tertiary(dark)
        num.columnWidth = 26

        let termCol = NSStackView()
        termCol.orientation = .vertical
        termCol.alignment = .leading
        termCol.spacing = 1
        let term = GlyphLabel()
        term.text = item.term.isEmpty ? "—" : item.term
        term.font = Fonts.song(16)
        term.color = Ink.text(dark)
        term.columnWidth = 128
        termCol.addArrangedSubview(term)
        if !item.reading.isEmpty {
            let reading = GlyphLabel()
            reading.text = item.reading
            reading.font = Fonts.timesItalic(12)
            reading.color = Ink.rust(dark)
            reading.columnWidth = 128
            termCol.addArrangedSubview(reading)
        }

        let language = toShown
        let speak = circle("speaker.wave.2", tip: "朗读释义「\(item.gloss)」") {
            Speaker.shared.speak(source: item.gloss, language: language)
        }
        speak.box = NSSize(width: 24, height: 24)
        speak.radius = 12

        let glossW = innerW - 26 - 8 - 128 - 8 - 24 - 8
        let gloss = wrapAttr(glossText(item.gloss), width: glossW)
        gloss.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gloss.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(num)
        row.addArrangedSubview(termCol)
        row.addArrangedSubview(gloss)
        row.addArrangedSubview(speak)
        gloss.widthAnchor.constraint(equalToConstant: glossW).isActive = true

        wrap.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: wrap.widthAnchor).isActive = true
        if !last {
            let line = rule()
            wrap.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: wrap.widthAnchor).isActive = true
        }
        return wrap
    }

    private func exampleBlock(_ items: [ExampleItem], index: Int) -> NSView {
        let item = items[index]
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        let page = NSButton()
        page.isBordered = false
        page.attributedTitle = NSAttributedString(
            string: "\(index + 1) / \(items.count)",
            attributes: [.font: Fonts.times(12), .foregroundColor: Ink.tertiary(dark)]
        )
        page.target = self
        page.action = #selector(nextExample)
        page.isEnabled = items.count > 1
        page.setContentHuggingPriority(.required, for: .horizontal)
        block.addArrangedSubview(headRow(en: "EXAMPLE", zh: "例句", trailingView: page))
        block.addArrangedSubview(rule())
        if !item.source.isEmpty {
            block.addArrangedSubview(wrap(item.source, font: Fonts.song(16), color: Ink.text(dark), spacing: 3, width: innerW))
        }
        if !item.target.isEmpty {
            block.addArrangedSubview(wrap(item.target, font: Fonts.timesItalic(15), color: Ink.secondary(dark), spacing: 3, width: innerW))
        }
        return block
    }

    private func footer() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let copy = ClickControl()
        copy.box = NSSize(width: 108, height: 40)
        copy.radius = 20
        copy.fill = Ink.chip(dark)
        copy.image = symbol("doc.on.doc", point: 13, color: Ink.onChip(dark))
        copy.title = NSAttributedString(string: "复制译文", attributes: [
            .font: Fonts.song(14),
            .foregroundColor: Ink.onChip(dark),
        ])
        copy.onClick = { [weak self] in self?.onCopyResult?() }

        let speak = circle("speaker.wave.2", tip: "朗读译文") { [weak self] in
            guard let self, !self.speakText.isEmpty else { return }
            Speaker.shared.speak(source: self.speakText, language: self.speakDirection)
        }
        let refresh = circle("arrow.clockwise", tip: "重新翻译") { [weak self] in
            self?.onRefresh?()
        }
        let accent = ClickControl()
        accent.box = NSSize(width: 62, height: 28)
        accent.title = Fonts.mixed("\(Config.speechAccent.title) ▾", size: 12, color: Ink.secondary(dark))
        accent.toolTip = "英文朗读口音（微软在线神经语音）"
        accent.onClick = { [weak self, weak accent] in
            guard let self, let accent else { return }
            let menu = NSMenu()
            menu.font = Fonts.song(12)
            for (index, choice) in EnglishAccent.allCases.enumerated() {
                let item = menu.addItem(withTitle: choice.title, action: #selector(self.speechAccentPicked(_:)), keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: choice.title, attributes: [.font: Fonts.song(12)])
                item.target = self
                item.tag = index
                item.representedObject = accent
                item.state = choice == Config.speechAccent ? .on : .off
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: accent.bounds.maxY + 4), in: accent)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(copy)
        row.addArrangedSubview(speak)
        row.addArrangedSubview(refresh)
        row.addArrangedSubview(accent)
        row.addArrangedSubview(spacer)

        if case .ready(let result) = mode {
            let tokens = NSStackView()
            tokens.orientation = .vertical
            tokens.alignment = .trailing
            tokens.spacing = 1
            let a = NSTextField(labelWithString: result.footerMain)
            a.font = Fonts.times(13)
            a.textColor = Ink.secondary(dark)
            a.alignment = .right
            let b = NSTextField(labelWithString: result.footerSub)
            b.font = Fonts.times(11)
            b.textColor = Ink.tertiary(dark)
            b.alignment = .right
            tokens.addArrangedSubview(a)
            tokens.addArrangedSubview(b)
            tokens.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(tokens)
        }
        return row
    }

    @objc private func speechAccentPicked(_ sender: NSMenuItem) {
        guard EnglishAccent.allCases.indices.contains(sender.tag) else { return }
        Config.speechAccent = EnglishAccent.allCases[sender.tag]
        if let button = sender.representedObject as? ClickControl {
            button.title = Fonts.mixed("\(Config.speechAccent.title) ▾", size: 12, color: Ink.secondary(dark))
            button.needsDisplay = true
        }
        Speaker.shared.stop()
    }

    // MARK: Pieces

    private func headRow(en: String, zh: String, trailing: String, italic: Bool) -> NSView {
        let lab = NSTextField(labelWithString: trailing)
        lab.font = italic ? Fonts.timesItalic(13) : Fonts.times(12)
        lab.textColor = Ink.tertiary(dark)
        lab.alignment = .right
        lab.setContentHuggingPriority(.required, for: .horizontal)
        return headRow(en: en, zh: zh, trailingView: lab)
    }

    private func headRow(en: String, zh: String, trailingView: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let left = kicker(en, zh, color: Ink.tertiary(dark), size: 11)
        left.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(left)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(trailingView)
        return row
    }

    private func kicker(_ en: String, _ zh: String, color: NSColor, size: CGFloat) -> NSTextField {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: en, attributes: [
            .font: Fonts.times(size),
            .foregroundColor: color,
            .kern: 1.25,
        ]))
        s.append(NSAttributedString(string: "  ·  ", attributes: [
            .font: Fonts.song(size),
            .foregroundColor: color,
        ]))
        s.append(NSAttributedString(string: zh, attributes: [
            .font: Fonts.song(size + 0.5),
            .foregroundColor: color,
        ]))
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = s
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    private func wrap(_ text: String, font: NSFont, color: NSColor, spacing: CGFloat, width: CGFloat) -> NSTextField {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        return wrapAttr(attr, width: width)
    }

    private func wrapAttr(_ attr: NSAttributedString, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = attr
        f.isEditable = false
        f.isSelectable = true
        f.isBordered = false
        f.drawsBackground = false
        f.preferredMaxLayoutWidth = width
        f.maximumNumberOfLines = 0
        f.setContentCompressionResistancePriority(.required, for: .vertical)
        return f
    }

    private func pin(_ view: NSView, width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func rule() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Ink.line(dark).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func circle(_ name: String, tip: String, action: @escaping () -> Void) -> ClickControl {
        let b = ClickControl()
        b.box = NSSize(width: 40, height: 40)
        b.radius = 20
        b.fill = NSColor.white.withAlphaComponent(dark ? 0.06 : 0.28)
        b.stroke = Ink.line(dark)
        b.image = symbol(name, point: 15, color: Ink.text(dark))
        b.toolTip = tip
        b.onClick = action
        return b
    }

    private func symbol(_ name: String, point: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: .medium)
        let img = base.withSymbolConfiguration(cfg) ?? base
        let size = img.size == .zero ? NSSize(width: point, height: point) : img.size
        return NSImage(size: size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func translationText(_ text: String, glossary: [GlossItem], chinese: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.lineBreakMode = .byWordWrapping
        let font = chinese ? Fonts.song(19) : Fonts.times(19)
        let m = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: Ink.text(dark),
            .paragraphStyle: style,
        ])
        let rust = Ink.rust(dark)
        let ns = text as NSString
        var used: [NSRange] = []
        var needles: [String] = []
        for item in glossary {
            let head = item.gloss
                .components(separatedBy: "—").first?
                .components(separatedBy: " - ").first ?? ""
            let parts = head.split { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" }
            for part in parts {
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if p.count >= 4 || (cjkHeavy(p) && p.count >= 2) { needles.append(p) }
            }
            if item.term.count >= 2 { needles.append(item.term) }
        }
        needles.sort { $0.count > $1.count }
        for needle in needles {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: needle, options: [.caseInsensitive], range: search)
                if found.location == NSNotFound { break }
                if !used.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    used.append(found)
                    m.addAttributes([
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: rust,
                    ], range: found)
                }
                let next = found.location + max(found.length, 1)
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return m
    }

    private func glossText(_ gloss: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.lineBreakMode = .byWordWrapping
        let chinese = cjkHeavy(gloss)
        let font = chinese ? Fonts.song(14) : Fonts.times(14)
        let m = NSMutableAttributedString(string: gloss, attributes: [
            .font: font,
            .foregroundColor: Ink.secondary(dark),
            .paragraphStyle: style,
        ])
        let markers = ["—", " - "]
        for marker in markers {
            if let r = gloss.range(of: marker) {
                let loc = gloss.distance(from: gloss.startIndex, to: r.lowerBound)
                let ns = NSRange(location: loc, length: (gloss as NSString).length - loc)
                m.addAttributes([
                    .font: chinese ? Fonts.song(13) : Fonts.timesItalic(14),
                    .foregroundColor: Ink.tertiary(dark),
                ], range: ns)
                break
            }
        }
        return m
    }

    private func countLabel(_ source: String) -> String {
        let cjk = source.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        if cjk * 2 >= max(source.count, 1) {
            return "\(source.filter { !$0.isWhitespace }.count) 字"
        }
        let words = source.split { $0.isWhitespace || $0.isNewline }.count
        return "\(max(words, 1)) 词"
    }

    private func cjkHeavy(_ s: String) -> Bool {
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return cjk > 0 && cjk * 2 >= s.count
    }

    @objc private func nextExample() {
        guard case .ready(let result) = mode, result.examples.count > 1 else { return }
        exampleIndex = (exampleIndex + 1) % result.examples.count
        render()
    }
}

// MARK: - 玻璃面板

@available(macOS 26.0, *)
private final class GlassHost: NSView {
    let glass = NSGlassEffectView()
    private let body = NSView()
    let caret = NSView()
    var caretX: CGFloat

    init(content: NSView, size: NSSize) {
        caretX = size.width / 2
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height + C.caretH)))
        body.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        body.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.layer?.cornerRadius = C.glassRadius
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        glass.frame = body.bounds
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = C.glassRadius
        glass.style = .regular
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        content.frame = glass.bounds
        glass.contentView = content
        body.addSubview(glass)
        addSubview(body)
        caret.wantsLayer = true
        addSubview(caret)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        let ch = C.caretH
        caret.frame = NSRect(x: caretX - 8, y: bounds.height - ch, width: 16, height: ch)
        body.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - ch))
        glass.frame = body.bounds
        glass.contentView?.frame = glass.bounds
        caret.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: caret.bounds.midX, y: caret.bounds.maxY))
        path.addLine(to: CGPoint(x: caret.bounds.maxX, y: caret.bounds.minY))
        path.addLine(to: CGPoint(x: caret.bounds.minX, y: caret.bounds.minY))
        path.closeSubpath()
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = NSColor.white.withAlphaComponent(0.92).cgColor
        caret.layer?.addSublayer(shape)
    }
}

private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PanelMotion {
    private var timer: Timer?
    private var window: NSWindow?
    private var x: CGFloat = 0
    private var restY: CGFloat = 0
    private var fromY: CGFloat = 0
    private var outY: CGFloat = 0
    private var y0: Double = 0
    private var v0: Double = 0
    private let omega: Double = 15.5
    private let zeta: Double = 0.70
    private var animT: Double = 0
    private var lastFrame: CFAbsoluteTime = 0
    private(set) var dismissing = false
    private var onDone: (() -> Void)?

    func cancel() {
        timer?.invalidate()
        timer = nil
        onDone = nil
        window = nil
        dismissing = false
    }

    func springIn(window: NSWindow, rest: NSRect, done: @escaping () -> Void) {
        cancel()
        self.window = window
        x = rest.origin.x
        restY = rest.origin.y
        y0 = Double(window.frame.origin.y - rest.origin.y)
        v0 = 240
        dismissing = false
        onDone = done
        begin()
    }

    func easeOut(window: NSWindow, distance: CGFloat, done: @escaping () -> Void) {
        cancel()
        self.window = window
        x = window.frame.origin.x
        fromY = window.frame.origin.y
        outY = fromY - distance
        dismissing = true
        onDone = done
        begin()
    }

    private func begin() {
        animT = 0
        lastFrame = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let window else { return }
        let now = CFAbsoluteTimeGetCurrent()
        var dt = now - lastFrame
        lastFrame = now
        if dt < 0 { dt = 0 }
        if dt > 0.05 { dt = 0.05 }
        animT += dt
        let t = animT
        if dismissing {
            let p = min(1, t / 0.16)
            let e = p * p * (3 - 2 * p)
            window.setFrameOrigin(NSPoint(x: x, y: fromY + (outY - fromY) * e))
            window.alphaValue = CGFloat(1 - e)
            if p >= 1 { finish() }
            return
        }
        let y = offset(t)
        window.setFrameOrigin(NSPoint(x: x, y: restY + CGFloat(y)))
        let fade = min(1, t / 0.10)
        let s = fade * fade * (3 - 2 * fade)
        window.alphaValue = CGFloat(0.72 + 0.28 * s)
        if t >= 0.48 || (t >= 0.34 && abs(y) < 0.35) { finish() }
    }

    private func offset(_ t: Double) -> Double {
        let wd = omega * sqrt(max(0, 1 - zeta * zeta))
        guard wd > 0 else { return 0 }
        let decay = exp(-zeta * omega * t)
        return decay * (y0 * cos(wd * t) + ((v0 + zeta * omega * y0) / wd) * sin(wd * t))
    }

    private func finish() {
        let window = self.window
        let done = onDone
        let closing = dismissing
        let endY = closing ? outY : restY
        cancel()
        if !closing {
            window?.setFrameOrigin(NSPoint(x: x, y: endY))
            window?.alphaValue = 1
            window?.invalidateShadow()
        }
        done?()
    }
}

// MARK: - App

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var card: DropPanel!
    private var glass: NSPanel?
    private let motion = PanelMotion()
    private let translator = Translator()
    private let history = QueryHistory()
    private var queryGeneration: UInt64 = 0
    private var restoredSource: String?
    private static let historyDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    private var paused = false
    private var lastResult: TranslateResult?
    private var heightConstraint: NSLayoutConstraint?
    private weak var hostVC: NSViewController?
    private var outside: Any?
    private var openedAt: CFAbsoluteTime = 0
    private var springing = false
    private var pendingH: CGFloat?
    private var flipDirection = false
    private var lastSource = ""
    private var closing = false

    private var isOpen: Bool {
        if motion.dismissing { return true }
        if let glass, glass.isVisible { return true }
        return popover.isShown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        paused = !Config.enabled
        Speaker.shared.onError = { message in
            let alert = NSAlert()
            alert.messageText = "在线朗读失败"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = MenuIcon.image(paused: paused)
            btn.imagePosition = .imageOnly
            btn.imageScaling = .scaleNone
            btn.toolTip = "WordPop：复制后点击翻译"
            btn.target = self
            btn.action = #selector(statusClick(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshTitle()

    }

    private func ensurePanel() {
        guard card == nil else { return }
        card = DropPanel(frame: NSRect(x: 0, y: 0, width: C.panelW, height: C.panelHDefault))
        card.onCopyResult = { [weak self] in
            let t = self?.card?.mainTranslation ?? ""
            guard !t.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
        }
        card.onRefresh = { [weak self] in
            guard let self else { return }
            self.runTranslate(source: self.restoredSource)
        }
        card.onSwap = { [weak self] in
            guard let self else { return }
            self.flipDirection.toggle()
            self.runTranslate(source: self.restoredSource)
        }
        card.onPreferHeight = { [weak self] h in self?.applyHeight(h) }
        card.onHistory = { [weak self] anchor in
            self?.makeHistoryMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
        }

        if Chrome.glass {
            if #available(macOS 26.0, *) { ensureGlass() }
        } else {
            let vc = NSViewController()
            hostVC = vc
            card.translatesAutoresizingMaskIntoConstraints = false
            let h0 = C.panelHDefault
            vc.view = NSView(frame: NSRect(x: 0, y: 0, width: C.panelW, height: h0))
            vc.view.addSubview(card)
            let hc = vc.view.heightAnchor.constraint(equalToConstant: h0)
            heightConstraint = hc
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
                card.topAnchor.constraint(equalTo: vc.view.topAnchor),
                card.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
                vc.view.widthAnchor.constraint(equalToConstant: C.panelW),
                hc
            ])
            vc.preferredContentSize = NSSize(width: C.panelW, height: h0)
            popover.contentViewController = vc
            popover.contentSize = NSSize(width: C.panelW, height: h0)
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }
    }

    @available(macOS 26.0, *)
    private func ensureGlass() {
        if glass != nil { return }
        let host = GlassHost(content: card, size: NSSize(width: C.panelW, height: C.panelHDefault))
        let window = GlassPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.sharingType = .readOnly
        window.level = .popUpMenu
        // 不用 .transient：辅助 App 一点开就会被系统当成非活跃，面板会立刻藏掉。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        glass = window
    }

    private func maxCardHeight() -> CGFloat {
        let screen = item.button?.window?.screen ?? NSScreen.main
        let room = (screen?.visibleFrame.height ?? 900) - 24 - C.caretH
        return min(C.panelHMax, max(C.panelHMin, room))
    }

    private func applyHeight(_ h: CGFloat) {
        let cardH = min(max(h, C.panelHMin), maxCardHeight())
        if springing {
            pendingH = cardH
            return
        }
        if Chrome.glass, let window = glass {
            let old = window.frame
            window.setContentSize(NSSize(width: C.panelW, height: cardH + C.caretH))
            if window.isVisible {
                let dy = window.frame.height - old.height
                if abs(dy) > 0.5 {
                    window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: old.origin.y - dy))
                }
            }
        } else {
            resizePopover(to: cardH)
        }
    }

    private func resizePopover(to height: CGFloat) {
        let h = min(max(height, C.panelHMin), C.panelHMax)
        heightConstraint?.constant = h
        hostVC?.preferredContentSize = NSSize(width: C.panelW, height: h)
        if popover.isShown {
            popover.contentSize = NSSize(width: C.panelW, height: h)
        } else {
            popover.contentSize = NSSize(width: C.panelW, height: h)
        }
    }

    private func refreshTitle() {
        item.button?.image = MenuIcon.image(paused: paused)
        item.button?.appearsDisabled = false
    }

    @objc private func statusClick(_ sender: Any?) {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp {
            dismissImmediately()
            showMenu()
            return
        }
        if isOpen {
            if CFAbsoluteTimeGetCurrent() - openedAt < 0.3 { return }
            closePanel()
        } else {
            openedAt = CFAbsoluteTimeGetCurrent()
            showPanel()
        }
    }

    private func showPanel() {
        restoredSource = nil
        presentPanel {
            if paused {
                card.showPlaceholder("已暂停。右键菜单可重新启用。")
            } else {
                runTranslate()
            }
        }
    }

    private func presentPanel(_ content: () -> Void) {
        guard let btn = item.button else { return }
        ensurePanel()
        let wasOpen = (glass?.isVisible == true || popover.isShown) && !motion.dismissing
        content()
        if wasOpen { return }
        if let window = glass {
            place(window, under: btn)
            let end = window.frame
            var start = end
            start.origin.y -= 38
            window.setFrame(start, display: false)
            window.alphaValue = 0.72
            window.orderFrontRegardless()
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            springing = true
            motion.springIn(window: window, rest: end) { [weak self] in
                guard let self else { return }
                self.springing = false
                if let h = self.pendingH {
                    self.pendingH = nil
                    self.applyHeight(h)
                }
            }
            startMonitor()
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func place(_ window: NSPanel, under button: NSStatusBarButton) {
        guard let host = button.window else { return }
        let anchor = host.convertToScreen(button.convert(button.bounds, to: nil))
        var size = window.frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 2)
        let vis = (host.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if vis.width > 1 {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            if origin.y < vis.minY + 8 {
                let room = anchor.minY - 2 - (vis.minY + 8)
                if room > C.panelHMin + C.caretH {
                    window.setContentSize(NSSize(width: C.panelW, height: room))
                    size = window.frame.size
                    origin.y = vis.minY + 8
                }
            }
        }
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        if #available(macOS 26.0, *), let shell = window.contentView as? GlassHost {
            let mid = window.convertPoint(fromScreen: NSPoint(x: anchor.midX, y: anchor.midY))
            shell.caretX = mid.x
            shell.needsLayout = true
        }
    }

    private func closePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let window = glass, window.isVisible, !motion.dismissing else { return }
        motion.easeOut(window: window, distance: 14) { [weak self] in
            self?.finishClose()
        }
    }

    private func dismissImmediately() {
        if popover.isShown {
            popover.performClose(nil)
        } else if glass != nil {
            finishClose()
        }
    }

    private func finishClose() {
        if closing { return }
        closing = true
        defer { closing = false }
        motion.cancel()
        springing = false
        pendingH = nil
        cancelPendingTranslation()
        Speaker.shared.stop()
        if let mon = outside {
            NSEvent.removeMonitor(mon)
            outside = nil
        }
        glass?.orderOut(nil)
        glass?.contentView = nil
        glass = nil
        popover.contentViewController = nil
        heightConstraint = nil
        hostVC = nil
        card = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    private func startMonitor() {
        if let mon = outside { NSEvent.removeMonitor(mon) }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if CFAbsoluteTimeGetCurrent() - self.openedAt < 0.3 { return }
            if self.clickHitsStatusItem() { return }
            self.closePanel()
        }
    }

    private func clickHitsStatusItem() -> Bool {
        guard let button = item.button, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -6, dy: -6)
        return rect.contains(NSEvent.mouseLocation)
    }

    private func cancelPendingTranslation() {
        queryGeneration &+= 1
        translator.cancel()
    }

    private func makeHistoryMenu() -> NSMenu {
        let menu = NSMenu()
        menu.font = Fonts.song(12)
        let count = menu.addItem(withTitle: "\(history.records.count) 条查询记录 · 仅保存在本机", action: nil, keyEquivalent: "")
        count.isEnabled = false
        menu.addItem(.separator())
        if let message = history.loadError {
            let error = menu.addItem(withTitle: "记录读取失败，可清空后重新开始记录", action: nil, keyEquivalent: "")
            error.isEnabled = false
            error.toolTip = message
        } else if history.records.isEmpty {
            let empty = menu.addItem(withTitle: "暂无查询记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for record in history.records {
            let source = record.result.source
            let end = source.index(source.startIndex, offsetBy: 48, limitedBy: source.endIndex) ?? source.endIndex
            var preview = String(source[..<end]).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            if end != source.endIndex { preview += "…" }
            let text = "\(Self.historyDate.string(from: record.queriedAt))  \(record.result.direction)  \(preview)"
            let item = menu.addItem(withTitle: text, action: #selector(openHistoryRecord(_:)), keyEquivalent: "")
            let title = NSMutableAttributedString(attributedString: Fonts.mixed(text, size: 12, color: .labelColor))
            title.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: title.length))
            item.attributedTitle = title
            item.target = self
            item.representedObject = record.id
            item.toolTip = "原文：\(record.result.source)\n译文：\(record.result.main)"
        }
        if !history.records.isEmpty || history.loadError != nil {
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: "清空查询记录…", action: #selector(clearQueryHistory), keyEquivalent: "")
            clear.target = self
        }
        return menu
    }

    @objc private func openHistoryRecord(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let record = history.records.first(where: { $0.id == id }) else { return }
        cancelPendingTranslation()
        Speaker.shared.stop()
        let result = record.result
        restoredSource = result.source
        lastSource = result.source
        flipDirection = LangDetect.direction(for: result.source).from != result.fromLang
        lastResult = result
        openedAt = CFAbsoluteTimeGetCurrent()
        presentPanel { card.show(result: result, fromHistory: true) }
    }

    @objc private func clearQueryHistory() {
        let alert = NSAlert()
        alert.messageText = "清空查询记录？"
        alert.informativeText = "将删除本机保存的所有查询记录，不影响当前显示的译文。此操作无法撤销。"
        alert.addButton(withTitle: "清空记录").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }

    private func runTranslate(source: String? = nil) {
        guard !paused else { return }
        cancelPendingTranslation()
        let generation = queryGeneration
        let raw = (source ?? NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            card.showError("剪贴板为空。\n请先复制要翻译的中文或英文，再点击菜单栏图标。")
            return
        }
        let hasLetter = raw.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        guard hasLetter else {
            card.showError("剪贴板内容不像可翻译文本。")
            return
        }
        if raw != lastSource {
            lastSource = raw
            flipDirection = false
        }
        let shown = raw.count > 600 ? String(raw.prefix(600)) : raw
        let dir = LangDetect.direction(for: shown, flipped: flipDirection)
        card.showLoading(shown, from: dir.from, to: dir.to)
        translator.translate(shown, flipped: flipDirection) { [weak self] result in
            guard let self, self.queryGeneration == generation else { return }
            switch result {
            case .success(let r):
                self.lastResult = r
                self.card.show(result: r)
                do {
                    try self.history.record(r)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "查询记录保存失败"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            case .failure(let e):
                self.card.showError(e.localizedDescription)
            }
        }
    }

    private func showMenu() {
        let m = NSMenu()
        let t = m.addItem(withTitle: "翻译剪贴板", action: #selector(menuTranslate), keyEquivalent: "")
        t.target = self
        let p = m.addItem(withTitle: paused ? "启用" : "暂停", action: #selector(togglePause), keyEquivalent: "")
        p.target = self
        let queries = NSMenuItem(title: "查询记录", action: nil, keyEquivalent: "")
        queries.submenu = makeHistoryMenu()
        m.addItem(queries)
        m.addItem(.separator())
        let k = m.addItem(withTitle: Config.apiKey.isEmpty ? "设置 API Key…" : "更改 API Key…", action: #selector(setKey), keyEquivalent: "")
        k.target = self
        let md = m.addItem(withTitle: "模型: \(Config.model)", action: #selector(setModel), keyEquivalent: "")
        md.target = self
        let speech = NSMenuItem(title: "英文朗读口音", action: nil, keyEquivalent: "")
        let accents = NSMenu()
        accents.font = Fonts.song(12)
        for (index, accent) in EnglishAccent.allCases.enumerated() {
            let option = accents.addItem(withTitle: accent.title, action: #selector(selectSpeechAccent(_:)), keyEquivalent: "")
            option.attributedTitle = NSAttributedString(string: accent.title, attributes: [.font: Fonts.song(12)])
            option.target = self
            option.tag = index
            option.state = Config.speechAccent == accent ? .on : .off
        }
        speech.submenu = accents
        m.addItem(speech)
        m.addItem(.separator())
        if let r = lastResult {
            let info = m.addItem(withTitle: r.tokenSummary, action: nil, keyEquivalent: "")
            info.isEnabled = false
        }
        m.addItem(withTitle: "退出 WordPop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func selectSpeechAccent(_ sender: NSMenuItem) {
        guard EnglishAccent.allCases.indices.contains(sender.tag) else { return }
        Config.speechAccent = EnglishAccent.allCases[sender.tag]
        Speaker.shared.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Speaker.shared.stop()
    }

    @objc private func menuTranslate() {
        openedAt = CFAbsoluteTimeGetCurrent()
        if !isOpen { showPanel() }
        else {
            restoredSource = nil
            runTranslate()
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        Config.enabled = !paused
        refreshTitle()
        if paused { cancelPendingTranslation() }
    }

    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "DeepSeek API Key"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Config.apiKey
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Config.apiKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func setModel() {
        let alert = NSAlert()
        alert.messageText = "模型（如 deepseek-chat）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = Config.model
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { Config.model = v }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        finishClose()
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
