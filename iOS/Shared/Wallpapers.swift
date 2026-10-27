// Shared by the DynamicWall iPhone app and its Home Screen widget:
// picture sources, region/resolution options, hardened downloading and caching.

import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Vision
import Security
import WidgetKit

// MARK: - Options

enum Source: String, CaseIterable, Identifiable, Codable {
    case bing = "Bing", spotlight = "Spotlight"
    var id: String { rawValue }
    var fullName: String { self == .bing ? "Daily Bing picture" : "Daily Windows Spotlight picture" }
}

struct Region: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Regions {
    static let all: [Region] = [
        Region(code: "auto", name: "Automatic"),
        Region(code: "en-US", name: "United States"),
        Region(code: "en-GB", name: "United Kingdom"),
        Region(code: "en-CA", name: "Canada (English)"),
        Region(code: "fr-CA", name: "Canada (Français)"),
        Region(code: "en-AU", name: "Australia"),
        Region(code: "en-IN", name: "India"),
        Region(code: "ja-JP", name: "Japan (日本)"),
        Region(code: "zh-CN", name: "China (中国)"),
        Region(code: "de-DE", name: "Germany (Deutschland)"),
        Region(code: "fr-FR", name: "France"),
        Region(code: "es-ES", name: "Spain (España)"),
        Region(code: "it-IT", name: "Italy (Italia)"),
        Region(code: "pt-BR", name: "Brazil (Brasil)"),
    ]

    /// The iPhone's own language-region, e.g. "en-IN", built only from validated letters.
    static var system: String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let reg = Locale.current.region?.identifier ?? "US"
        let valid = { (s: String) -> Bool in (2...3).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isLetter } }
        return valid(lang) && valid(reg) ? "\(lang.lowercased())-\(reg.uppercased())" : "en-US"
    }

    /// Bing market ("en-IN") and Spotlight country ("IN") for a stored region code.
    static func resolve(_ code: String) -> (market: String, country: String) {
        let market = code == "auto" ? system : code
        let country = market.split(separator: "-").last.map { String($0).uppercased() } ?? "US"
        return (market, country)
    }

    static func name(_ code: String) -> String {
        if code == "auto" { return name(system) }
        return all.first { $0.code == code }?.name ?? code
    }
}

enum Keys {
    static let source = "source"
    static let region = "region"
    static let resolution = "resolution"
    static let screenW = "screenW"
    static let screenH = "screenH"
}

/// Settings read outside SwiftUI (by the Shortcuts action and the download code).
enum Prefs {
    static var source: Source { Source(rawValue: UserDefaults.standard.string(forKey: Keys.source) ?? "") ?? .bing }
    static var region: String { UserDefaults.standard.string(forKey: Keys.region) ?? "auto" }
    /// The iPhone's screen in pixels (portrait), saved when the app opens.
    static var screen: CGSize {
        let w = UserDefaults.standard.double(forKey: Keys.screenW)
        let h = UserDefaults.standard.double(forKey: Keys.screenH)
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : CGSize(width: 1206, height: 2622)
    }
    /// Width ÷ height of the screen (about 0.46 on current iPhones).
    static var aspect: CGFloat { screen.width / screen.height }
}

enum Day {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }

    /// Local date as yyyyMMdd — the "day" a daily picture belongs to.
    static var today: String { formatter().string(from: Date()) }

    /// "Today", "Yesterday" or a short date ("Oct 20").
    static func label(_ day: String) -> String {
        guard let d = formatter().date(from: day) else { return "" }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Files

enum Paths {
    static let fm = FileManager.default

    static var cache: URL {
        let u = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicWall", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var thumbs: URL {
        let u = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicWallThumbs", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Only letters, digits, - and _ survive, so names from the network can't escape our folders.
    static func safe(_ s: String, max: Int = 80) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(String(s.unicodeScalars.map { ok.contains($0) ? Character($0) : "_" }).prefix(max))
    }
    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes downloaded pictures older than `days`, so the cache stays small.
    static func prune(days: Double = 10) {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        for dir in [cache, thumbs] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if d < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}

// MARK: - Networking (hardened)

enum Net {
    static let maxBytes = 40 * 1024 * 1024
    static let maxPixels = 12_000
    /// Hosts Microsoft serves Bing and Spotlight from. ".microsoft" is a domain only Microsoft can register.
    static let allowedHosts = ["bing.com", "bing.net", "microsoft.com", "microsoft", "msn.com",
                               "img-prod-cms-rt-microsoft-com.akamaized.net", "img-s-msn-com.akamaized.net"]
    /// The Spotlight service answers "No ad available" to some non-browser user agents.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        c.urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 10_000_000)
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.allowsConstrainedNetworkAccess = false            // respect Low Data Mode
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    static func json(_ url: URL) async -> Data? {
        guard isAllowed(url),
              let (data, resp) = try? await session.data(for: request(url)),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, isAllowed(finalURL),
              data.count < 2_000_000 else { return nil }
        return data
    }

    /// Downloads an image to `dest`, keeping it only if it really is a reasonably sized image.
    static func image(_ url: URL, to dest: URL) async -> Bool {
        guard isAllowed(url),
              let (tmp, resp) = try? await session.download(for: request(url)) else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, isAllowed(finalURL) else { return false }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 1024, size <= maxBytes, isValidImage(tmp) else { return false }
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
    }

    static func isValidImage(_ file: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return w > 0 && h > 0 && w <= maxPixels && h <= maxPixels
    }
}

/// Refuses any redirect that leaves the allowed Microsoft hosts.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let u = request.url, Net.isAllowed(u) else { return nil }
        return request
    }
}

// MARK: - Pictures

struct WallImage: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var copyright: String
    var source: Source
    var day: String                 // yyyyMMdd
    var bingBase: String? = nil     // Bing: "/th?id=OHR.Name_EN-US123"
    var landscape: URL? = nil       // Spotlight 4K landscape
    var portrait: URL? = nil        // Spotlight portrait

    /// Small versions for the gallery and widget, smallest first.
    var thumbURLs: [URL] {
        switch source {
        case .bing:
            guard let b = bingBase else { return [] }
            return ["640x360.jpg", "1366x768.jpg"].compactMap { URL(string: "https://www.bing.com\(b)_\($0)") }
        case .spotlight:
            return [landscape ?? portrait].compactMap { $0 }
        }
    }

    /// The full 4K original. Bing: 3840 x 2160. Spotlight: the 4K portrait version when there is one.
    var original: Variant? {
        switch source {
        case .bing:
            guard let base = bingBase else { return nil }
            return Variant(key: "4k", urls: ["UHD.jpg", "1920x1080.jpg"].compactMap { URL(string: "https://www.bing.com\(base)_\($0)") })
        case .spotlight:
            guard let u = portrait ?? landscape else { return nil }
            return Variant(key: "4k", urls: [u])
        }
    }

    /// "Lake Bled, Slovenia" from "Lake Bled, Slovenia (© Photographer/Getty Images)".
    var location: String {
        if source == .bing, let r = copyright.range(of: "(©") {
            let place = copyright[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            if !place.isEmpty { return place }
        }
        return title
    }

    /// A copy that is safe to use even if it came from outside the app (e.g. a widget link).
    func sanitized() -> WallImage? {
        var c = self
        c.id = Paths.safe(id, max: 60)
        c.day = Paths.safe(day, max: 8)
        c.title = String(title.prefix(200))
        c.copyright = String(copyright.prefix(300))
        if let b = bingBase, !b.hasPrefix("/") || b.contains("..") { return nil }
        if let u = landscape, !Net.isAllowed(u) { return nil }
        if let u = portrait, !Net.isAllowed(u) { return nil }
        return c.id.isEmpty ? nil : c
    }
}

struct Variant {
    let key: String       // part of the cached file name
    let urls: [URL]       // tried in order

}

// MARK: - Sources

enum Fetch {
    struct BingResp: Decodable {
        struct I: Decodable { let urlbase: String; let title: String?; let copyright: String?; let startdate: String }
        let images: [I]
    }

    static func bing(market: String) async -> [WallImage] {
        guard let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=\(market)"),
              let data = await Net.json(url),
              let r = try? JSONDecoder().decode(BingResp.self, from: data) else { return [] }
        return r.images.compactMap { i in
            guard i.urlbase.hasPrefix("/"), !i.urlbase.contains("..") else { return nil }   // a path on bing.com only
            let copyright = String((i.copyright ?? "").prefix(300))
            let title = (i.title ?? "").isEmpty ? copyright : (i.title ?? "")
            let day = Paths.safe(i.startdate, max: 8)
            return WallImage(id: "bing-\(day)-\(Paths.hash(i.urlbase))", title: String(title.prefix(200)),
                             copyright: copyright, source: .bing, day: day, bingBase: i.urlbase)
        }
    }

    /// Windows Spotlight (the same unofficial service Windows 11 uses).
    static func spotlight(country: String, locale: String) async -> [WallImage] {
        guard let url = URL(string: "https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&bcnt=4&country=\(country)&locale=\(locale)&fmt=json"),
              let data = await Net.json(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["batchrsp"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        let today = Day.today
        return items.compactMap { entry -> WallImage? in
            guard let str = entry["item"] as? String,
                  let inner = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any],
                  let ad = inner["ad"] as? [String: Any] else { return nil }
            func asset(_ key: String) -> URL? {
                guard let s = (ad[key] as? [String: Any])?["asset"] as? String,
                      let u = URL(string: s), Net.isAllowed(u) else { return nil }
                return u
            }
            let land = asset("landscapeImage"), port = asset("portraitImage")
            guard let key = land ?? port else { return nil }
            let hover = (ad["iconHoverText"] as? String)?.components(separatedBy: .newlines).first
            let title = [hover, ad["title"] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "Windows Spotlight"
            let caption = [(ad["description"] as? String) ?? "", (ad["copyright"] as? String) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " — ")
            return WallImage(id: "spot-" + Paths.hash(key.absoluteString), title: String(title.prefix(200)),
                             copyright: String(caption.prefix(300)), source: .spotlight, day: today,
                             landscape: land, portrait: port)
        }
    }

    /// Returns a cached local file for this picture and variant, downloading it once.
    static func file(_ img: WallImage, _ v: Variant) async -> URL? {
        let dest = Paths.cache.appendingPathComponent("\(img.id)-\(Paths.safe(v.key, max: 20)).jpg")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        for u in v.urls {
            if await Net.image(u, to: dest) { return dest }
        }
        return nil
    }
}

// MARK: - Images

enum Img {
    /// Memory-cheap decode via ImageIO: never loads the full 4K picture into memory.
    static func downsample(_ file: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Writes a JPEG copy of `src` whose long side is at most `maxPixel`.
    static func downscale(_ src: URL, to dest: URL, maxPixel: Int) -> Bool {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts),
              let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }
}

// MARK: - Cropping to the phone screen

enum Crop {
    /// The largest phone-shaped rectangle (normalized, top-left origin) centred on `center`.
    static func fit(width W: CGFloat, height H: CGFloat, aspect a: CGFloat, center c: CGPoint) -> CGRect {
        guard W > 0, H > 0, a > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var h = H, w = H * a
        if w > W { w = W; h = W / a }
        let x = min(max(0, c.x * W - w / 2), W - w)
        let y = min(max(0, c.y * H - h / 2), H - h)
        return CGRect(x: x / W, y: y / H, width: w / W, height: h / H)
    }

    /// Finds the most interesting part of the picture (Apple's Vision saliency) and frames it.
    static func smart(_ file: URL, aspect: CGFloat) -> CGRect {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let W = props[kCGImagePropertyPixelWidth] as? Int, let H = props[kCGImagePropertyPixelHeight] as? Int else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var focus = CGPoint(x: 0.5, y: 0.5)
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary
        if let small = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) {
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            try? VNImageRequestHandler(cgImage: small, options: [:]).perform([request])
            if let boxes = request.results?.first?.salientObjects?.map({ $0.boundingBox }), let first = boxes.first {
                let all = boxes.dropFirst().reduce(first) { $0.union($1) }
                focus = CGPoint(x: all.midX, y: 1 - all.midY)       // Vision measures from the bottom
            }
        }
        return fit(width: CGFloat(W), height: CGFloat(H), aspect: aspect, center: focus)
    }

    /// Writes the cropped part of `src` (full resolution) as a JPEG.
    static func render(_ src: URL, crop r: CGRect, to dest: URL) -> Bool {
        autoreleasepool {
            guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return false }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let rect = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
                .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !rect.isEmpty, let cut = cg.cropping(to: rect),
                  let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(d, cut, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            return CGImageDestinationFinalize(d)
        }
    }
}

// MARK: - Data shared with the widgets

/// What the widgets show. The app writes it; the widgets read it.
struct SharedState: Codable {
    var region = "auto"
    var today: WallImage?
    var upNext: WallImage?
    var favorites: [WallImage] = []
    var recentSpotlight: [WallImage] = []
    var bing: [WallImage] = []
}

/// Shared through the Keychain (works with a free Apple ID, unlike App Groups).
/// Without Keychain Sharing the widgets simply fetch their own pictures.
enum SharedStore {
    private static var group: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "DWSharedKeychainGroup") as? String,
              !g.isEmpty, !g.hasPrefix("$") else { return nil }
        return g
    }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "DynamicWall",
                                kSecAttrAccount as String: "widget-state"]
        if let g = group { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    static func read() -> SharedState {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = try? JSONDecoder().decode(SharedState.self, from: data) else { return SharedState() }
        return s
    }

    static func write(_ state: SharedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let q = query()
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            for (k, v) in attrs { add[k] = v }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Daily pictures

/// Decides which picture is "today's", remembers what you've seen, crops and hands out files.
/// Used by the app, the Shortcuts action and the widgets.
actor WallpaperService {
    static let shared = WallpaperService()

    private let d = UserDefaults.standard
    private var bingFetched = Date.distantPast

    private func load(_ key: String) -> [WallImage] {
        guard let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WallImage].self, from: data)) ?? []
    }
    private func save(_ list: [WallImage], _ key: String) {
        d.set(try? JSONEncoder().encode(list), forKey: key)
    }

    // MARK: Bing

    /// The last 8 days of Bing pictures, newest first. Fetched at most hourly; works offline from the last list.
    func bingImages(force: Bool = false) async -> [WallImage] {
        let market = Regions.resolve(Prefs.region).market
        let cached = load("bingList")
        let sameMarket = d.string(forKey: "bingMarket") == market
        if !force, sameMarket, !cached.isEmpty, Date().timeIntervalSince(bingFetched) < 3600 { return cached }
        let fresh = await Fetch.bing(market: market)
        guard !fresh.isEmpty else { return cached }
        bingFetched = Date()
        save(fresh, "bingList")
        d.set(market, forKey: "bingMarket")
        return fresh
    }

    // MARK: Windows Spotlight (different pictures on every request, so we choose one per day)

    /// Pictures fetched from Spotlight, newest first.
    func spotlightPool(force: Bool = false) async -> [WallImage] {
        if force || load("spotPool").isEmpty { _ = await refillPool() }
        return load("spotPool")
    }

    /// Spotlight pictures you've had, oldest first.
    func spotlightShown() -> [WallImage] { load("spotShown") }

    private func refillPool() async -> Bool {
        let r = Regions.resolve(Prefs.region)
        var items = await Fetch.spotlight(country: r.country, locale: r.market)
        if items.isEmpty && r.country != "US" {          // "No ad available" for some regions → try US
            items = await Fetch.spotlight(country: "US", locale: "en-US")
        }
        guard !items.isEmpty else { return false }
        var merged = items
        for old in load("spotPool") where !merged.contains(where: { $0.id == old.id }) { merged.append(old) }
        save(Array(merged.prefix(24)), "spotPool")
        return true
    }

    /// Today's Spotlight picture: the same all day, a new one each day.
    func todaySpotlight() async -> WallImage? {
        if d.string(forKey: "spotDay") == Day.today, let id = d.string(forKey: "spotTodayID"),
           let img = spotlightShown().first(where: { $0.id == id }) { return img }
        guard let img = await newSpotlight() else { return nil }
        d.set(Day.today, forKey: "spotDay")
        d.set(img.id, forKey: "spotTodayID")
        return img
    }

    /// The picture the next new Spotlight day will use (shown by the Up Next widget). No network.
    func upNext() -> WallImage? {
        let seen = Set(spotlightShown().map { $0.id })
        let pool = load("spotPool")
        if let id = d.string(forKey: "spotUpNextID"), let img = pool.first(where: { $0.id == id && !seen.contains(id) }) {
            return img
        }
        let next = pool.first { !seen.contains($0.id) }
        d.set(next?.id, forKey: "spotUpNextID")       // keep it stable even when more pictures arrive
        return next
    }

    /// Makes sure there's an unseen Spotlight picture ready for tomorrow.
    func prepareUpNext() async {
        if upNext() == nil, await refillPool() { _ = upNext() }
    }

    /// A Spotlight picture you haven't had yet (fetches more when needed).
    func newSpotlight() async -> WallImage? {
        var next = upNext()
        if next == nil {
            _ = await refillPool()
            next = upNext()
        }
        if next == nil {
            let pool = load("spotPool")
            let last = spotlightShown().last?.id
            next = pool.filter { $0.id != last }.randomElement() ?? pool.first
        }
        guard let img = next else { return nil }
        addShown(img)
        d.removeObject(forKey: "spotUpNextID")
        return img
    }

    /// Adds a picture to the end of your Spotlight history.
    func addShown(_ img: WallImage) {
        var shown = spotlightShown().filter { $0.id != img.id }
        shown.append(img)
        save(Array(shown.suffix(30)), "spotShown")
    }

    // MARK: Favorites

    func favorites() -> [WallImage] { load("favorites") }

    func isFavorite(_ id: String) -> Bool { favorites().contains { $0.id == id } }

    /// Adds or removes a favorite. Returns true if it's now a favorite.
    @discardableResult
    func toggleFavorite(_ img: WallImage) -> Bool {
        var list = favorites()
        if let i = list.firstIndex(where: { $0.id == img.id }) {
            list.remove(at: i)
            save(list, "favorites")
            return false
        }
        list.insert(img, at: 0)
        save(Array(list.prefix(50)), "favorites")
        return true
    }

    // MARK: Cropping

    private func cropKey(_ id: String) -> String {
        "\(id)@\(Int(Prefs.screen.width))x\(Int(Prefs.screen.height))"
    }
    private func rect(_ v: [Double]?) -> CGRect? {
        guard let v, v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    private func store(_ r: CGRect, in key: String, for id: String) {
        var all = d.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[cropKey(id)] = [r.minX, r.minY, r.width, r.height]
        if all.count > 200 { all.removeValue(forKey: all.keys.first ?? "") }
        d.set(all, forKey: key)
    }

    /// The crop you chose with Zoom & Select, if any.
    func userCrop(_ id: String) -> CGRect? {
        rect((d.dictionary(forKey: "userCrops") as? [String: [Double]])?[cropKey(id)])
    }
    func setCrop(_ r: CGRect, for id: String) { store(r, in: "userCrops", for: id) }
    func clearCrop(for id: String) {
        var all = d.dictionary(forKey: "userCrops") as? [String: [Double]] ?? [:]
        all.removeValue(forKey: cropKey(id))
        d.set(all, forKey: "userCrops")
    }

    /// The automatic crop around the most interesting part of the picture.
    func smartCrop(for img: WallImage) async -> CGRect? {
        if let r = rect((d.dictionary(forKey: "autoCrops") as? [String: [Double]])?[cropKey(img.id)]) { return r }
        guard let file = await file(for: img) else { return nil }
        let aspect = Prefs.aspect
        let r = await Task.detached(priority: .userInitiated) { Crop.smart(file, aspect: aspect) }.value
        store(r, in: "autoCrops", for: img.id)
        return r
    }

    func crop(for img: WallImage) async -> CGRect? {
        if let r = userCrop(img.id) { return r }
        return await smartCrop(for: img)
    }

    // MARK: Files

    /// The 4K original.
    func file(for img: WallImage) async -> URL? {
        guard let v = img.original else { return nil }
        return await Fetch.file(img, v)
    }

    /// The wallpaper: the 4K original cropped to your screen's shape at full resolution.
    func wallpaper(for img: WallImage) async -> URL? {
        guard let src = await file(for: img) else { return nil }
        guard let r = await crop(for: img) else { return src }
        let tag = Paths.hash(String(format: "%.4f,%.4f,%.4f,%.4f", r.minX, r.minY, r.width, r.height))
        let dest = Paths.cache.appendingPathComponent("\(img.id)-wall-\(tag).jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let ok = await Task.detached(priority: .userInitiated) { Crop.render(src, crop: r, to: dest) }.value
        return ok ? dest : src
    }

    // MARK: The picture the Shortcut uses

    /// Remembers the picture you chose in the app; the Shortcut uses it for the rest of today.
    func setPicked(_ img: WallImage) {
        save([img], "picked")
        d.set(Day.today, forKey: "pickedDay")
    }

    /// Today's picture for the Shortcut: your pick from today if any, otherwise the daily picture.
    func wallpaperImage(source: Source?) async -> WallImage? {
        if d.string(forKey: "pickedDay") == Day.today, let picked = load("picked").first,
           source == nil || picked.source == source {
            return picked
        }
        switch source ?? Prefs.source {
        case .bing: return await bingImages().first
        case .spotlight: return await todaySpotlight()
        }
    }

    /// Used by the Shortcuts action: the wallpaper file, and the widgets learn what's on screen.
    func wallpaperFile(source: Source?) async -> URL? {
        guard let img = await wallpaperImage(source: source), let url = await wallpaper(for: img) else { return nil }
        save([img], "lastSet")
        await prepareUpNext()
        publish()
        return url
    }

    // MARK: Widgets

    /// Sends the current state to the widgets and asks them to refresh.
    func publish() {
        var s = SharedState()
        s.region = Prefs.region
        s.bing = load("bingList")
        s.recentSpotlight = Array(spotlightShown().suffix(8).reversed())
        s.favorites = Array(favorites().prefix(20))
        s.today = load("lastSet").first ?? (Prefs.source == .bing ? s.bing.first : spotlightShown().last)
        s.upNext = Prefs.source == .spotlight ? upNext() : nil
        SharedStore.write(s)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Forget everything tied to the old region, so pictures (and their language) match the new one.
    func resetForRegion() {
        for key in ["bingList", "bingMarket", "spotPool", "spotShown", "spotDay", "spotTodayID", "spotUpNextID", "picked", "pickedDay"] {
            d.removeObject(forKey: key)
        }
        bingFetched = .distantPast
    }
}
