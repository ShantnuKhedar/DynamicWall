// DynamicWall — daily Bing & Windows Spotlight wallpapers for macOS (a Mac take on "Dynamic Theme").
//
// Features: daily Bing picture, daily Windows Spotlight picture, your own folders as a slideshow,
// region and resolution options, gallery of recent pictures, notifications, auto-save, pause,
// optional description overlay, launch at login, and a "Say thank you" window.
//
// Light on battery: one coalesced timer, network at most hourly (slower in Low Power Mode),
// downsampled thumbnails, heavy image work off the main thread.
// Hardened: App Sandbox, HTTPS-only to Microsoft hosts, size-capped downloads verified as real images.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import UserNotifications
import ServiceManagement

// MARK: - Options

enum Source: String, CaseIterable, Identifiable, Codable {
    case bing = "Bing", spotlight = "Spotlight", personal = "My Pictures"
    var id: String { rawValue }
    var fullName: String {
        switch self {
        case .bing: return "Daily Bing picture"
        case .spotlight: return "Daily Windows Spotlight picture"
        case .personal: return "My pictures (slideshow)"
        }
    }
}

enum Resolution: String, CaseIterable, Identifiable {
    case automatic, best, uhd, fhd = "1920x1080", portrait = "1080x1920"
    var id: String { rawValue }
}

struct Region: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Regions {
    /// Markets for which Bing publishes its own daily picture. Spotlight uses the same country.
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

    /// The Mac's own language-region, e.g. "en-IN", built only from validated letters.
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

enum Day {
    /// Local date as yyyyMMdd — the "day" a daily picture belongs to.
    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }

    /// "Today", "Yesterday" or a short date ("Oct 20") for a yyyyMMdd day.
    static func label(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        guard let d = f.date(from: day) else { return "" }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Screens

enum Screens {
    /// Pixel size macOS renders this display at.
    @MainActor static func pixels(_ s: NSScreen) -> CGSize {
        CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
    }
    @MainActor static var mainPixels: CGSize {
        NSScreen.screens.first.map(pixels) ?? CGSize(width: 1920, height: 1080)
    }
    /// Display size capped at 3840 px on the long side (the largest Bing original).
    static func fit(_ px: CGSize) -> (w: Int, h: Int) {
        var w = max(px.width, 1), h = max(px.height, 1)
        let long = max(w, h)
        if long > 3840 { w = w * 3840 / long; h = h * 3840 / long }
        return (Int(w.rounded()), Int(h.rounded()))
    }
    @MainActor static func label(_ r: Resolution) -> String {
        switch r {
        case .automatic:
            let f = fit(mainPixels)
            return "Automatic (\(f.w) x \(f.h))"
        case .best: return "Best resolution"
        case .uhd: return "UHD (4K or like)"
        case .fhd: return "1920 x 1080"
        case .portrait: return "1080 x 1920"
        }
    }
}

// MARK: - Paths & helpers

enum Paths {
    static let fm = FileManager.default

    /// ~/Pictures/DynamicWall (inside the sandbox this resolves through the Pictures entitlement).
    static var saveFolder: URL {
        let u = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicWall")
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// App-owned storage for wallpapers currently in use.
    static var store: URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicWall", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Small (≤ 480 px) gallery thumbnails.
    static var thumbs: URL {
        let u = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicWallThumbs")
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Only letters, digits, - and _ survive, so names from the network can't escape our folders.
    static func safe(_ s: String, max: Int = 80) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(s.unicodeScalars.map { ok.contains($0) ? Character($0) : "_" })
        return String(cleaned.prefix(max))
    }
    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func touch(_ u: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
    }
    /// Any already-downloaded wallpaper file for this picture (reused for thumbnails).
    static func anyCached(_ id: String) -> URL? {
        let files = (try? fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(id + "-") }
    }
    /// Deletes stored files older than `days`, except those in use. Keeps disk use bounded.
    static func prune(days: Double = 10, keep: Set<URL>) {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let keepPaths = Set(keep.map { $0.standardizedFileURL.path })
        for dir in [store, thumbs] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where !keepPaths.contains(f.standardizedFileURL.path) {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if d < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}

/// Temporarily opens sandbox access to a picture inside one of the user's chosen folders.
enum Scoped {
    static func access<T>(_ file: URL, folders: [URL], _ body: () throws -> T) rethrows -> T {
        let parent = folders.first { file.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
        let started = parent?.startAccessingSecurityScopedResource() ?? false
        defer { if started { parent?.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

// MARK: - Networking (hardened)

enum Net {
    static let maxBytes = 40 * 1024 * 1024    // refuse anything bigger than 40 MB
    static let maxPixels = 12_000             // refuse absurd image dimensions
    /// Hosts Microsoft serves Bing and Spotlight from. ".microsoft" is a brand domain only Microsoft can register.
    static let allowedHosts = ["bing.com", "bing.net", "microsoft.com", "microsoft", "msn.com",
                               "img-prod-cms-rt-microsoft-com.akamaized.net", "img-s-msn-com.akamaized.net"]
    /// The Spotlight service answers "No ad available" to some non-browser user agents.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        c.urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 10_000_000)   // we cache files ourselves
        c.httpCookieStorage = nil                                                       // no cookies, no tracking
        c.httpShouldSetCookies = false
        c.allowsConstrainedNetworkAccess = false                                        // respect Low Data Mode
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
              let finalURL = http.url, isAllowed(finalURL) else { return false }   // also blocks redirects elsewhere
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

/// Refuses any redirect that leaves the allowed Microsoft hosts (checked before it's followed).
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let u = request.url, Net.isAllowed(u) else { return nil }
        return request
    }
}

// MARK: - Pictures

struct WallImage: Identifiable, Hashable, Codable {
    var id: String                 // sanitized, stable key used in file names
    var title: String
    var copyright: String
    var source: Source
    var day: String                // yyyyMMdd
    var bingBase: String? = nil    // Bing: "/th?id=OHR.Name_EN-US123"
    var landscape: URL? = nil      // Spotlight 4K landscape
    var portrait: URL? = nil       // Spotlight portrait
    var file: URL? = nil           // My pictures

    var thumbURLs: [URL] {
        switch source {
        case .bing:
            guard let b = bingBase else { return [] }
            return ["1366x768.jpg", "1920x1080.jpg"].compactMap { URL(string: "https://www.bing.com\(b)_\($0)") }
        case .spotlight:
            return [landscape ?? portrait].compactMap { $0 }
        case .personal:
            return []
        }
    }

    /// Which file to fetch for a resolution setting and a display of `px` pixels.
    func variant(_ res: Resolution, screen px: CGSize) -> Variant? {
        switch source {
        case .bing:
            guard let base = bingBase else { return nil }
            func u(_ s: String) -> URL? { URL(string: "https://www.bing.com\(base)_\(s)") }
            let uhd = u("UHD.jpg")
            switch res {
            case .best:
                return Variant(key: "best", urls: [uhd].compactMap { $0 }, maxPixel: nil)
            case .uhd:
                return Variant(key: "uhd", urls: [u("UHD.jpg&w=3840&h=2160&rs=1&c=4"), uhd].compactMap { $0 }, maxPixel: nil)
            case .fhd:
                return Variant(key: "1920x1080", urls: [u("1920x1080.jpg"), uhd].compactMap { $0 }, maxPixel: 1920)
            case .portrait:
                return Variant(key: "1080x1920", urls: [u("1080x1920.jpg"), u("UHD.jpg&w=1080&h=1920&rs=1&c=4")].compactMap { $0 }, maxPixel: nil)
            case .automatic:
                // Ask Bing for exactly this display's size; fall back to the nearest standard size.
                let f = Screens.fit(px)
                let standard = f.h > f.w ? u("1080x1920.jpg") : (f.w <= 1920 ? u("1920x1080.jpg") : uhd)
                return Variant(key: "fit\(f.w)x\(f.h)", urls: [u("UHD.jpg&w=\(f.w)&h=\(f.h)&rs=1&c=4"), standard].compactMap { $0 }, maxPixel: nil)
            }
        case .spotlight:
            guard let land = landscape ?? portrait, let port = portrait ?? landscape else { return nil }
            switch res {
            case .best, .uhd: return Variant(key: "land", urls: [land], maxPixel: nil)
            case .fhd:        return Variant(key: "land1920", urls: [land], maxPixel: 1920)
            case .portrait:   return Variant(key: "port1920", urls: [port], maxPixel: 1920)
            case .automatic:
                return px.height > px.width ? Variant(key: "port", urls: [port], maxPixel: nil)
                                            : Variant(key: "land", urls: [land], maxPixel: nil)
            }
        case .personal:
            guard let f = file else { return nil }
            return Variant(key: "orig", urls: [f], maxPixel: nil)
        }
    }
}

struct Variant {
    let key: String       // part of the cached file name
    let urls: [URL]       // tried in order
    let maxPixel: Int?    // optional local downscale (long side)
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
            let desc = (ad["description"] as? String) ?? ""
            let copy = (ad["copyright"] as? String) ?? ""
            let caption = [desc, copy].filter { !$0.isEmpty }.joined(separator: " — ")
            return WallImage(id: "spot-" + Paths.hash(key.absoluteString), title: String(title.prefix(200)),
                             copyright: String(caption.prefix(300)), source: .spotlight, day: today,
                             landscape: land, portrait: port)
        }
    }

    /// Lists pictures in the user's chosen folders (through security-scoped bookmarks).
    static func personal(_ folders: [URL], limit: Int = 5000) -> [WallImage] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]
        var out: [WallImage] = []
        for dir in folders {
            let started = dir.startAccessingSecurityScopedResource()
            defer { if started { dir.stopAccessingSecurityScopedResource() } }
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in en where exts.contains(u.pathExtension.lowercased()) {
                out.append(WallImage(id: "local-" + Paths.hash(u.path), title: u.deletingPathExtension().lastPathComponent,
                                     copyright: u.path, source: .personal, day: "", file: u))
                if out.count >= limit { return out }   // cap work on huge photo libraries
            }
        }
        return out
    }

    /// Returns an app-owned local file for this picture and variant, downloading or copying it once.
    static func file(_ img: WallImage, _ v: Variant, folders: [URL]) async -> URL? {
        let fm = FileManager.default
        if img.source == .personal {
            guard let src = img.file else { return nil }
            let ext = Paths.safe(src.pathExtension.lowercased(), max: 5)
            let dest = Paths.store.appendingPathComponent("\(img.id)-\(v.key).\(ext.isEmpty ? "jpg" : ext)")
            if fm.fileExists(atPath: dest.path) { Paths.touch(dest); return dest }
            // Your own photos: just confirm it's an image (no size cap, so panoramas work).
            let copied: Bool = Scoped.access(src, folders: folders) {
                guard let s = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(s) > 0 else { return false }
                return (try? fm.copyItem(at: src, to: dest)) != nil
            }
            return copied ? dest : nil
        }
        let dest = Paths.store.appendingPathComponent("\(img.id)-\(v.key).jpg")
        if fm.fileExists(atPath: dest.path) { Paths.touch(dest); return dest }
        let tmp = Paths.store.appendingPathComponent("dl-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        var got = false
        for u in v.urls {
            if await Net.image(u, to: tmp) { got = true; break }
        }
        guard got else { return nil }
        if let mp = v.maxPixel {
            let ok = await Task.detached(priority: .utility) { Img.downscale(tmp, to: dest, maxPixel: mp) }.value
            return ok ? dest : nil
        }
        return (try? fm.moveItem(at: tmp, to: dest)) != nil ? dest : nil
    }
}

// MARK: - Image utilities

enum Img {
    /// Memory-cheap thumbnail via ImageIO (never decodes the full 4K image into memory).
    static func thumbnail(_ file: URL, maxPixel: Int = 480) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Writes a JPEG copy of `src` whose long side is at most `maxPixel`.
    static func downscale(_ src: URL, to dest: URL, maxPixel: Int) -> Bool {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts),
              let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    /// Draws the title and description onto a copy of the wallpaper. Runs off the main thread.
    static func overlay(_ file: URL, title: String, caption: String) -> URL? {
        autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let size = NSSize(width: cg.width, height: cg.height)
            guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: bmp) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.draw(cg, in: CGRect(origin: .zero, size: size))
            let scale = max(size.width, size.height) / 1920
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 6 * scale
            shadow.shadowColor = .black.withAlphaComponent(0.8)
            let tA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30 * scale, weight: .semibold),
                                                     .foregroundColor: NSColor.white, .shadow: shadow]
            let cA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18 * scale),
                                                     .foregroundColor: NSColor.white.withAlphaComponent(0.9), .shadow: shadow]
            let margin = 60 * scale
            let maxW = size.width > size.height ? size.width * 0.45 : size.width - 2 * margin
            let x = size.width - maxW - margin
            let cs = NSAttributedString(string: caption, attributes: cA)
            let ch = cs.boundingRect(with: NSSize(width: maxW, height: 400 * scale), options: .usesLineFragmentOrigin).height
            cs.draw(with: NSRect(x: x, y: margin * 1.6, width: maxW, height: ch), options: .usesLineFragmentOrigin)
            NSAttributedString(string: title, attributes: tA)
                .draw(with: NSRect(x: x, y: margin * 1.6 + ch + 8 * scale, width: maxW, height: 60 * scale),
                      options: .usesLineFragmentOrigin)
            NSGraphicsContext.restoreGraphicsState()
            guard let jpg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
            // Unique name, because macOS caches wallpapers by file URL.
            let stem = file.deletingPathExtension().lastPathComponent
            let out = Paths.store.appendingPathComponent("overlay-\(stem)-\(Int(Date().timeIntervalSince1970)).jpg")
            return (try? jpg.write(to: out)) != nil ? out : nil
        }
    }
}

// MARK: - Engine

@MainActor
final class Engine: ObservableObject {
    // Settings
    @AppStorage("source") var sourceRaw = Source.bing.rawValue {
        didSet {
            scheduleTimer()
            if skipSourceApply { skipSourceApply = false; return }    // a gallery pick sets the picture itself
            Task {
                if source == .bing, Date().timeIntervalSince(lastBingFetch) >= 3600 { await fetchBing() }
                await apply(force: true)
            }
        }
    }
    @AppStorage("region") var region = "auto" { didSet { Task { await regionChanged() } } }
    @AppStorage("resolution") var resolutionRaw = Resolution.automatic.rawValue { didSet { Task { await reapplyCurrent() } } }
    @AppStorage("folderBookmarks") var bookmarksData = Data()
    @AppStorage("slideMinutes") var slideMinutes = 30 { didSet { scheduleTimer() } }
    @AppStorage("shuffle") var shuffle = true
    @AppStorage("autoSave") var autoSave = false
    @AppStorage("notify") var notify = true { didSet { if notify { requestNotifications() } } }
    @AppStorage("overlay") var overlay = false { didSet { Task { await reapplyCurrent() } } }
    @AppStorage("pausedUntil") var pausedUntil: Double = 0
    // Daily state
    @AppStorage("lastBingID") var lastBingID = ""
    @AppStorage("bingPinnedID") var bingPinnedID = ""            // an older Bing day the user went back to
    @AppStorage("bingPinnedLatest") var bingPinnedLatest = ""    // the newest Bing picture at that moment
    @AppStorage("spotDay") var spotDay = ""
    @AppStorage("spotCurrentID") var spotCurrentID = ""
    @AppStorage("spotShown") var spotShown = ""                  // Spotlight pictures in the order shown
    @AppStorage("spotHistory") var spotHistoryData = Data()
    @AppStorage("currentImage") var currentData = Data()         // lets a kept (paused) picture survive a restart

    @Published var bing: [WallImage] = []        // last 8 days, newest first
    @Published var spotlight: [WallImage] = []   // recent Spotlight pictures, newest first
    @Published var current: WallImage?
    @Published var status = "Starting…"
    @Published var folders: [URL] = []

    private var applied: [String: URL] = [:]     // variant key → file on screen now
    private var timer: Timer?
    private var lastBingFetch = Date.distantPast
    private var lastSpotFetch = Date.distantPast
    private var lastSlide = Date.distantPast
    private var lastPrune = Date.distantPast
    private var personalCache: [WallImage] = []
    private var personalCacheDate = Date.distantPast
    private var slideHistory: [WallImage] = []   // slides shown, oldest first (for Previous/Next)
    private var slidePos = -1                    // index of the slide on screen in slideHistory
    private var busy = false
    private var queued: WallImage?
    private var wanted: WallImage?               // newest picture asked for (may still be loading)
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var failedPicks: [String: Int] = [:]
    private var skipSourceApply = false

    static let wallOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]

    var source: Source { sourceRaw == "Windows Spotlight" ? .spotlight : (Source(rawValue: sourceRaw) ?? .bing) }
    var resolution: Resolution { Resolution(rawValue: resolutionRaw) ?? .automatic }
    var isPaused: Bool { Date().timeIntervalSince1970 < pausedUntil }
    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Seconds between slides, and a timer step that splits it into equal parts of at most an hour.
    private var slideSeconds: TimeInterval { Double(lowPower ? max(slideMinutes, 60) : max(slideMinutes, 5)) * 60 }
    private var slideStep: TimeInterval { slideSeconds / (slideSeconds / 3600).rounded(.up) }

    init() {
        if sourceRaw == "Windows Spotlight" { sourceRaw = Source.spotlight.rawValue }   // settings from v1.0
        folders = resolveBookmarks()
        spotlight = (try? JSONDecoder().decode([WallImage].self, from: spotHistoryData)) ?? []
        if notify { requestNotifications() }
        scheduleTimer()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))      // give Wi-Fi time to reconnect
                await self?.tick()
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reapply() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reapply() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        }
        Task {
            await fetchBing()
            if source == .spotlight || spotlight.isEmpty { await fetchSpotlight() }
            if isPaused, let kept = try? JSONDecoder().decode(WallImage.self, from: currentData) {
                await set(kept)                              // the user asked to keep this picture
            } else {
                await apply(force: true)
            }
        }
    }

    // MARK: Scheduling — one timer, woken rarely, with tolerance so macOS can batch it.

    func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = source == .personal ? slideStep : (lowPower ? 3600 : 15 * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() async {
        let now = Date()
        if source == .bing, now.timeIntervalSince(lastBingFetch) >= TimeInterval(lowPower ? 3 : 1) * 3600 {
            await fetchBing()
        }
        if source == .spotlight, now.timeIntervalSince(lastSpotFetch) >= TimeInterval(lowPower ? 48 : 24) * 3600 {
            await fetchSpotlight()
        }
        if now.timeIntervalSince(lastPrune) > 86400 { Paths.prune(keep: Set(applied.values)); lastPrune = now }
        if isPaused { return }
        if source == .personal {
            if now.timeIntervalSince(lastSlide) >= slideSeconds - slideStep / 2 { await slideForward() }
        } else {
            await apply(force: false)
        }
    }

    // MARK: Fetching

    func fetchBing() async {
        lastBingFetch = Date()                       // set first so overlapping ticks don't fetch twice
        let list = await Fetch.bing(market: Regions.resolve(region).market)
        if !list.isEmpty { bing = list; return }
        lastBingFetch = .distantPast                 // failed: try again on the next tick
        if bing.isEmpty { status = "Can't reach Bing — will retry" }
    }

    func fetchSpotlight() async {
        lastSpotFetch = Date()
        let r = Regions.resolve(region)
        var items = await Fetch.spotlight(country: r.country, locale: r.market)
        if items.isEmpty && r.country != "US" {          // "No ad available" for some regions → try US
            items = await Fetch.spotlight(country: "US", locale: "en-US")
        }
        guard !items.isEmpty else {
            lastSpotFetch = .distantPast
            if spotlight.isEmpty { status = "Can't reach Windows Spotlight — will retry" }
            return
        }
        var merged = items
        for old in spotlight where !merged.contains(where: { $0.id == old.id }) { merged.append(old) }
        var kept = Array(merged.prefix(16))
        if !kept.contains(where: { $0.id == spotCurrentID }), let cur = merged.first(where: { $0.id == spotCurrentID }) {
            kept[kept.count - 1] = cur                   // never drop today's picture from the history
        }
        spotlight = kept
        spotHistoryData = (try? JSONEncoder().encode(kept)) ?? Data()
    }

    func prepareGallery() async {
        if bing.isEmpty || Date().timeIntervalSince(lastBingFetch) > 3600 { await fetchBing() }
        if spotlight.isEmpty || Date().timeIntervalSince(lastSpotFetch) > 24 * 3600 { await fetchSpotlight() }
    }

    func refreshNow() async {
        personalCacheDate = .distantPast             // re-read your folders too
        await fetchBing()
        await fetchSpotlight()
        await apply(force: true)
    }
    private func regionChanged() async {
        spotlight = []                    // forget pictures from the old region
        spotHistoryData = Data()
        bingPinnedID = ""
        bingPinnedLatest = ""
        bing = []
        await fetchBing()
        await fetchSpotlight()
        switch source {
        case .bing: await apply(force: true)
        case .spotlight: await nextSpotlightNow()
        case .personal: break
        }
    }

    // MARK: Choosing the picture

    func apply(force: Bool) async {
        if isPaused && !force { return }
        switch source {
        case .bing:
            guard let latest = bing.first else { return }
            // An older day the user went back to stays until Bing publishes a newer picture.
            if !bingPinnedID.isEmpty {
                if latest.id == bingPinnedLatest, let pinned = bing.first(where: { $0.id == bingPinnedID }) {
                    if force || current?.id != pinned.id { await set(pinned) }
                    return
                }
                bingPinnedID = ""
                bingPinnedLatest = ""
            }
            guard force || current?.id != latest.id else { return }
            let isNew = latest.id != lastBingID
            let firstEver = lastBingID.isEmpty
            if await set(latest), isNew {
                lastBingID = latest.id
                if autoSave { await save(latest, silent: true) }
                if notify && !force && !firstEver { notifyNew(latest) }
            }

        case .spotlight:
            // Spotlight returns different pictures on every request, so we pick one per day ourselves.
            let today = Day.today
            if spotDay != today || !spotlight.contains(where: { $0.id == spotCurrentID }) {
                if spotlight.allSatisfy({ shownIDs.contains($0.id) }) { await fetchSpotlight() }
                guard let pick = nextSpotlightCandidate() else { return }
                let firstEver = spotDay.isEmpty
                if await set(pick) {
                    acceptSpotlight(pick)
                    if autoSave { await save(pick, silent: true) }
                    if notify && !force && !firstEver { notifyNew(pick) }
                } else {
                    noteFailure(pick)
                }
            } else if force || current?.id != spotCurrentID, let img = spotlight.first(where: { $0.id == spotCurrentID }) {
                await set(img)
            }

        case .personal:
            await slideForward()
        }
    }

    // MARK: Previous / Next

    /// Where the picture on screen sits in the Bing list (0 = today).
    private var bingIndex: Int? {
        // Count from the picture being loaded, so quick repeated clicks step one day each.
        guard let c = busy ? (wanted ?? current) : current, c.source == .bing else { return nil }
        return bing.firstIndex { $0.id == c.id }
    }

    var canGoBack: Bool {
        switch source {
        case .bing: return (bingIndex ?? 0) + 1 < bing.count
        case .spotlight: return previousSpotlightID() != nil
        case .personal: return slidePos > 0 || (!shuffle && personalCache.count > 1)
        }
    }

    var canGoForward: Bool {
        switch source {
        case .bing: return (bingIndex ?? 0) > 0
        case .spotlight: return true                 // at the newest end, Next fetches a new picture
        case .personal: return !folders.isEmpty
        }
    }

    /// "Today", "Yesterday" or a date for the Bing picture on screen.
    var positionLabel: String {
        guard source == .bing, let c = current, c.source == .bing else { return "" }
        return Day.label(c.day)
    }

    func previous() async {
        switch source {
        case .bing:
            let i = (bingIndex ?? 0) + 1
            guard i < bing.count else { return }
            await showBing(bing[i])
        case .spotlight:
            guard let id = previousSpotlightID(), let img = spotlight.first(where: { $0.id == id }) else { return }
            await showSpotlight(img)
        case .personal:
            await slideBack()
        }
    }

    func next() async {
        switch source {
        case .bing:
            let i = (bingIndex ?? 0) - 1
            guard i >= 0 else { return }
            await showBing(bing[i])
        case .spotlight:
            if let id = laterSpotlightID(), let img = spotlight.first(where: { $0.id == id }) {
                await showSpotlight(img)
            } else {
                await nextSpotlightNow()
            }
        case .personal:
            await slideForward()
        }
    }

    private func showBing(_ img: WallImage) async {
        guard img.id != bing.first?.id else {
            bingPinnedID = ""                        // back on today's picture: daily changes resume
            bingPinnedLatest = ""
            await apply(force: true)                 // records and auto-saves it like a daily change
            return
        }
        bingPinnedID = img.id
        bingPinnedLatest = bing.first?.id ?? ""
        await set(img)
    }

    private func showSpotlight(_ img: WallImage) async {
        let oldID = spotCurrentID
        let oldDay = spotDay
        spotCurrentID = img.id                       // stays until tomorrow's pick
        spotDay = Day.today
        if await set(img) {
            if !shownIDs.contains(img.id) { markShown(img.id) }
        } else if wanted?.id == img.id, spotCurrentID == img.id {   // really failed, not replaced
            spotCurrentID = oldID
            spotDay = oldDay
            noteFailure(img)
        }
    }

    /// A gallery pick: switches to that picture's source if needed and keeps it like Previous/Next do.
    func useFromGallery(_ img: WallImage) async {
        if img.source != source {
            skipSourceApply = true
            sourceRaw = img.source.rawValue
        }
        switch img.source {
        case .bing: await showBing(img)
        case .spotlight: await showSpotlight(img)
        case .personal: await set(img)
        }
    }

    // MARK: Spotlight helpers

    private var shownOrder: [String] { spotShown.split(separator: ",").map(String.init) }
    private var shownIDs: Set<String> { Set(shownOrder) }

    /// Spotlight pictures we can show: still in the history, and not broken.
    private var usableSpotlightIDs: Set<String> {
        Set(spotlight.map { $0.id }).subtracting(failedPicks.filter { $0.value >= 2 }.keys)
    }

    private func previousSpotlightID() -> String? {
        let order = shownOrder
        let have = usableSpotlightIDs
        guard let p = order.lastIndex(of: spotCurrentID) else { return nil }
        return order[..<p].last { have.contains($0) }
    }

    private func laterSpotlightID() -> String? {
        let order = shownOrder
        let have = usableSpotlightIDs
        guard let p = order.lastIndex(of: spotCurrentID), p + 1 < order.count else { return nil }
        return order[(p + 1)...].first { have.contains($0) }
    }

    func nextSpotlightNow() async {
        if spotlight.allSatisfy({ shownIDs.contains($0.id) }) { await fetchSpotlight() }
        guard let pick = nextSpotlightCandidate() else { return }
        if await set(pick) { acceptSpotlight(pick) } else { noteFailure(pick) }
    }

    private func nextSpotlightCandidate() -> WallImage? {
        let shown = shownIDs
        return spotlight.first { !shown.contains($0.id) }
            ?? spotlight.first { $0.id != spotCurrentID }
            ?? spotlight.first
    }

    private func acceptSpotlight(_ pick: WallImage) {
        spotDay = Day.today
        spotCurrentID = pick.id
        markShown(pick.id)
        failedPicks[pick.id] = nil
    }

    /// A Spotlight picture that fails to download twice (e.g. removed by Microsoft) is skipped.
    private func noteFailure(_ pick: WallImage) {
        guard wanted?.id == pick.id else { return }  // replaced by a newer choice, not a failure
        failedPicks[pick.id, default: 0] += 1
        if failedPicks[pick.id, default: 0] >= 2 { markShown(pick.id) }
    }

    private func markShown(_ id: String) {
        var list = shownOrder.filter { $0 != id }
        list.append(id)
        spotShown = list.suffix(60).joined(separator: ",")
    }

    // MARK: My pictures slideshow

    private func loadPersonal() async {
        if personalCache.isEmpty || Date().timeIntervalSince(personalCacheDate) > 3600 {
            let f = folders
            personalCache = await Task.detached(priority: .utility) { Fetch.personal(f) }.value
            personalCacheDate = Date()
        }
    }

    /// Next slide: forward through history if you went back, otherwise a new one.
    func slideForward() async {
        if slidePos + 1 < slideHistory.count {
            slidePos += 1
            await showSlide(slideHistory[slidePos])
            return
        }
        await loadPersonal()
        guard !personalCache.isEmpty else { status = "Add a folder in Settings"; return }
        let img: WallImage
        if shuffle {
            let recent = Set(slideHistory.suffix(20).map { $0.id })
            let fresh = personalCache.filter { !recent.contains($0.id) }
            img = (fresh.isEmpty ? personalCache : fresh).randomElement()!
        } else {
            let i = slideHistory.last.flatMap { last in personalCache.firstIndex { $0.id == last.id } }
            img = personalCache[((i ?? -1) + 1) % personalCache.count]
        }
        slideHistory.append(img)
        if slideHistory.count > 50 { slideHistory.removeFirst(slideHistory.count - 50) }
        slidePos = slideHistory.count - 1
        await showSlide(img)
    }

    /// Previous slide: back through history; in order mode it can keep going past the start.
    func slideBack() async {
        if slidePos > 0 {
            slidePos -= 1
            await showSlide(slideHistory[slidePos])
            return
        }
        guard !shuffle else { return }
        await loadPersonal()
        guard personalCache.count > 1, let first = slideHistory.first,
              let i = personalCache.firstIndex(where: { $0.id == first.id }) else { return }
        let img = personalCache[(i - 1 + personalCache.count) % personalCache.count]
        slideHistory.insert(img, at: 0)
        if slideHistory.count > 50 { slideHistory.removeLast(slideHistory.count - 50) }
        slidePos = 0
        await showSlide(img)
    }

    private func showSlide(_ img: WallImage) async {
        lastSlide = Date()
        scheduleTimer()                              // the next slide counts from this one
        await set(img)
    }

    /// Re-applies after a resolution or overlay change, without reverting a picture still loading.
    func reapplyCurrent() async {
        if let c = busy ? (wanted ?? current) : current { await set(c) }
    }

    // MARK: Applying

    /// Sets a picture on every display, each in the size that suits it. Requests made while busy
    /// wait their turn and the newest one wins. Returns true only if this picture ends up on screen.
    @discardableResult
    func set(_ img: WallImage) async -> Bool {
        wanted = img
        if busy {
            queued = img
            await withCheckedContinuation { waiters.append($0) }
            return current?.id == img.id
        }
        busy = true
        _ = await perform(img)
        while let q = queued {
            queued = nil
            _ = await perform(q)
        }
        busy = false
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
        return current?.id == img.id
    }

    private func perform(_ img: WallImage) async -> Bool {
        status = "Loading \(img.title)…"
        var files: [String: URL] = [:]
        var plan: [(NSScreen, URL)] = []
        let screens = NSScreen.screens               // read once: downloads below can take a while
        for screen in screens {
            guard let v = img.variant(resolution, screen: Screens.pixels(screen)) else { continue }
            if let f = files[v.key] { plan.append((screen, f)); continue }
            guard var f = await Fetch.file(img, v, folders: folders) else { continue }
            if overlay && img.source != .personal {
                let (src, t, c) = (f, img.title, img.copyright)
                if let o = await Task.detached(priority: .utility, operation: { Img.overlay(src, title: t, caption: c) }).value { f = o }
            }
            files[v.key] = f
            plan.append((screen, f))
        }
        guard let fallback = files.values.first else {
            status = "Couldn't load this picture — will retry"
            return false
        }
        // A display whose own size failed still gets the picture, in another size.
        for screen in screens where !plan.contains(where: { $0.0 == screen }) { plan.append((screen, fallback)) }
        for (screen, f) in plan {
            try? NSWorkspace.shared.setDesktopImageURL(f, for: screen, options: Self.wallOptions)
        }
        cleanUp(keeping: Set(files.values))
        applied = files
        current = img
        currentData = (try? JSONEncoder().encode(img)) ?? Data()
        status = img.title
        return true
    }

    /// Deletes caption overlays and slideshow copies that are no longer on screen.
    private func cleanUp(keeping keep: Set<URL>) {
        let names = Set(keep.map { $0.lastPathComponent })
        let stored = (try? FileManager.default.contentsOfDirectory(at: Paths.store, includingPropertiesForKeys: nil)) ?? []
        for f in stored {
            let n = f.lastPathComponent
            if (n.hasPrefix("overlay-") || n.hasPrefix("local-")) && !names.contains(n) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// Re-applies after a Space switch or display change; fetches a new size if a display needs one.
    func reapply() {
        guard let c = current else { return }
        var missing = false
        for screen in NSScreen.screens {
            guard let v = c.variant(resolution, screen: Screens.pixels(screen)) else { continue }
            guard let f = applied[v.key] else { missing = true; continue }
            if NSWorkspace.shared.desktopImageURL(for: screen) != f {
                try? NSWorkspace.shared.setDesktopImageURL(f, for: screen, options: Self.wallOptions)
            }
        }
        if missing { Task { await reapplyCurrent() } }
    }

    func save(_ img: WallImage, silent: Bool = false) async {
        guard img.source != .personal,
              let v = img.variant(resolution, screen: Screens.mainPixels),
              let f = await Fetch.file(img, v, folders: folders) else { return }
        let dest = Paths.saveFolder.appendingPathComponent("\(img.day) \(Paths.safe(img.title, max: 60)).jpg")
        if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: f, to: dest) }
        if !silent { status = "Saved to Pictures › DynamicWall" }
    }

    func pause(hours: Double) {
        pausedUntil = hours == 0 ? 0 : Date().addingTimeInterval(hours * 3600).timeIntervalSince1970
        objectWillChange.send()
        if hours == 0 { Task { await tick() } }      // resume right away
    }

    // MARK: Folder bookmarks (sandbox-safe access to user-chosen folders)

    func addFolders(_ urls: [URL]) {
        var all = folders
        for u in urls where !all.contains(u) { all.append(u) }
        storeBookmarks(all)
        if source == .personal && current?.source != .personal { Task { await slideForward() } }
    }
    func removeFolder(_ url: URL) { storeBookmarks(folders.filter { $0 != url }) }

    private func storeBookmarks(_ urls: [URL]) {
        let datas = urls.compactMap { u -> Data? in
            let started = u.startAccessingSecurityScopedResource()
            defer { if started { u.stopAccessingSecurityScopedResource() } }
            return try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        bookmarksData = (try? PropertyListEncoder().encode(datas)) ?? Data()
        folders = resolveBookmarks()
        personalCache = []
        slideHistory = []                            // may point into a folder that was removed
        slidePos = -1
    }
    private func resolveBookmarks() -> [URL] {
        guard let datas = try? PropertyListDecoder().decode([Data].self, from: bookmarksData) else { return [] }
        return datas.compactMap { d in
            var stale = false
            return try? URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    private func notifyNew(_ img: WallImage) {
        let c = UNMutableNotificationContent()
        c.title = img.source == .bing ? "New daily Bing picture" : "New Windows Spotlight picture"
        c.body = img.title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: img.id, content: c, trigger: nil))
    }
}

// MARK: - Windows

/// Makes the app's windows behave like a normal app's: they open in front of other apps and on
/// the Space you're on (even over a full-screen app). The Dock icon shows only while one is open.
@MainActor
final class WindowCenter {
    static let shared = WindowCenter()

    private struct Ref { weak var window: NSWindow? }
    private var windows: [String: Ref] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    /// Called by WindowHook when SwiftUI creates one of our windows.
    func register(_ id: String, _ w: NSWindow) {
        guard windows[id]?.window !== w else { return }
        windows[id] = Ref(window: w)
        configure(w)
        if let old = closeObservers[id] { NotificationCenter.default.removeObserver(old) }
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                WindowCenter.shared.hideDockIconIfIdle()
            }
        }
    }

    /// Call from the button the user clicked, just before openWindow / openSettings.
    func show(_ id: String) {
        _ = NSApp.setActivationPolicy(.regular)             // a normal app while a window is open
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            for _ in 0..<30 {                                // the window may take a moment to exist
                try? await Task.sleep(for: .milliseconds(50))
                if let w = windows[id]?.window, w.isVisible || w.isMiniaturized {
                    bringToFront(w)
                    return
                }
            }
            hideDockIconIfIdle()
        }
    }

    /// Open on the current Space (never jump Spaces) and allow showing over full-screen apps.
    /// Only one full-screen flag may be set, so SwiftUI's own one is replaced.
    private func configure(_ w: NSWindow) {
        var b = w.collectionBehavior
        b.subtract([.canJoinAllSpaces, .fullScreenPrimary, .fullScreenNone])
        b.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
        if b != w.collectionBehavior { w.collectionBehavior = b }
    }

    private func bringToFront(_ w: NSWindow) {
        _ = NSApp.setActivationPolicy(.regular)             // a delayed hide may have run meanwhile
        configure(w)                                         // in case SwiftUI reset the flags
        NSApp.activate(ignoringOtherApps: true)
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func hideDockIconIfIdle() {
        let anyOpen = windows.values.contains { ($0.window?.isVisible ?? false) || ($0.window?.isMiniaturized ?? false) }
        if !anyOpen { _ = NSApp.setActivationPolicy(.accessory) }
    }
}

/// Invisible view that tells WindowCenter which NSWindow SwiftUI created for a scene.
struct WindowHook: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> HookView { HookView(id: id) }
    func updateNSView(_ nsView: HookView, context: Context) {}

    final class HookView: NSView {
        let id: String
        init(id: String) {
            self.id = id
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Register right away, before the window is shown, so it opens on the current Space.
            if let w = window { WindowCenter.shared.register(id, w) }
        }
    }
}

// MARK: - Feedback

enum Feedback {
    static let address = "shanu.khedar.7@gmail.com"
    /// Your GitHub repository, once it exists, e.g. URL(string: "https://github.com/yourname/DynamicWall").
    static let repoURL: URL? = nil

    enum Kind: String, CaseIterable, Identifiable {
        case idea = "Suggestion", bug = "Bug report", question = "Question", other = "Other"
        var id: String { rawValue }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    static func mailURL(_ kind: Kind) -> URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [
            URLQueryItem(name: "subject", value: "DynamicWall – \(kind.rawValue)"),
            URLQueryItem(name: "body", value: "\n\n\n—\nDynamicWall \(version), macOS \(os)"),
        ]
        return c.url
    }

    /// Opens a new message in the user's email app. Returns false if there's no email app.
    @MainActor static func compose(_ kind: Kind) -> Bool {
        guard let u = mailURL(kind) else { return false }
        return NSWorkspace.shared.open(u)
    }

    @MainActor static func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }
}

// MARK: - Support ("Say thank you")

enum Support {
    static let paypalUser = "shantanukhedar"
    static let currency = "USD"   // PayPal converts from the donor's own currency

    static let message = """
    DynamicWall is free — no ads, no tracking, no subscriptions — and it will stay that way. \
    It's built by an independent developer, and every update takes real time and care. \
    If a fresh wallpaper each day makes you smile, a small coffee is a lovely way to say thanks \
    and helps fund future versions. Every bit of support means a lot. Thank you!
    """

    struct Tier: Identifiable {
        let id: Int
        let name: String
        let detail: String
        let amount: Int?          // nil = donor chooses the amount
        let iconSize: CGFloat
    }

    static let tiers: [Tier] = [
        Tier(id: 0, name: "Coffee", detail: "small", amount: 1, iconSize: 20),
        Tier(id: 1, name: "Coffee", detail: "medium", amount: 2, iconSize: 26),
        Tier(id: 2, name: "Coffee", detail: "large", amount: 3, iconSize: 32),
        Tier(id: 3, name: "Coffee", detail: "extra large", amount: 5, iconSize: 38),
        Tier(id: 4, name: "Any amount", detail: "you choose", amount: nil, iconSize: 30),
    ]

    /// paypal.me/name/2USD opens PayPal with the amount filled in.
    static func link(_ amount: Int?) -> URL? {
        var s = "https://paypal.me/\(paypalUser)"
        if let a = amount { s += "/\(a)\(currency)" }
        return URL(string: s)
    }

    static func price(_ amount: Int) -> String {
        amount.formatted(.currency(code: currency))
    }
}

struct PriceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(Color(red: 0.45, green: 0.76, blue: 0.98).opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

struct TierCard: View {
    let tier: Support.Tier

    var body: some View {
        VStack(spacing: 0) {
            Text("\(tier.name)\n(\(tier.detail))")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .frame(height: 44)
                .padding(.top, 14)
            Spacer(minLength: 6)
            icon.frame(height: 44)
            Spacer(minLength: 6)
            Button {
                if let u = Support.link(tier.amount) { NSWorkspace.shared.open(u) }
            } label: {
                Text(tier.amount.map(Support.price) ?? "With PayPal")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(PriceButtonStyle())
            .help(tier.amount == nil ? "Open PayPal and choose any amount" : "Open PayPal with this amount")
        }
        .frame(width: 132, height: 178)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var icon: some View {
        if tier.amount == nil {
            Image(systemName: "gift.fill")
                .font(.system(size: tier.iconSize))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.red, Color.orange)
        } else {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: tier.iconSize))
                .foregroundStyle(Color.brown)
        }
    }
}

struct SupportView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enjoying DynamicWall?").font(.title2.weight(.semibold))
                    Text(Support.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                ForEach(Support.tiers) { TierCard(tier: $0) }
            }
            Text("Payments are handled securely by PayPal. DynamicWall never sees your payment details.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 760)
        .background(WindowHook(id: "support"))
    }
}

// MARK: - UI

/// Small, memory-cheap thumbnail, cached in a bounded NSCache and on disk (≤ 480 px).
@MainActor enum ThumbCache {
    static let mem: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 32
        return c
    }()
}

struct Thumb: View {
    let img: WallImage
    var folders: [URL] = []
    @State private var image: NSImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(16/9, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: img.id) { image = await load() }
    }

    private func load() async -> NSImage? {
        let key = img.id as NSString
        if let c = ThumbCache.mem.object(forKey: key) { return c }
        let cached = Paths.thumbs.appendingPathComponent("\(img.id).jpg")
        if !FileManager.default.fileExists(atPath: cached.path) {
            if let local = Paths.anyCached(img.id) {
                // Reuse the wallpaper we already downloaded — no extra network.
                _ = await Task.detached(priority: .utility) { Img.downscale(local, to: cached, maxPixel: 480) }.value
            } else if img.source == .personal, let f = img.file {
                let fs = folders
                _ = await Task.detached(priority: .utility) {
                    Scoped.access(f, folders: fs) { Img.downscale(f, to: cached, maxPixel: 480) }
                }.value
            } else {
                let tmp = Paths.thumbs.appendingPathComponent("dl-\(UUID().uuidString).tmp")
                for u in img.thumbURLs {
                    if await Net.image(u, to: tmp) {
                        _ = await Task.detached(priority: .utility) { Img.downscale(tmp, to: cached, maxPixel: 480) }.value
                        break
                    }
                }
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        guard FileManager.default.fileExists(atPath: cached.path) else { return nil }
        let result = await Task.detached(priority: .utility) { Img.thumbnail(cached) }.value
        if let r = result { ThumbCache.mem.setObject(r, forKey: key) }
        return result
    }
}

struct MenuView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let img = e.current {
                Thumb(img: img, folders: e.folders)
                Text(img.title).font(.headline).lineLimit(2)
                if !img.copyright.isEmpty {
                    Text(img.copyright).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Text(e.status).foregroundStyle(.secondary)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)

            Picker("Picture", selection: $e.sourceRaw) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Previous / Next
            HStack(spacing: 8) {
                Button { Task { await e.previous() } } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!e.canGoBack)
                .help(e.source == .bing ? "The day before" : "The previous picture")

                if !e.positionLabel.isEmpty {
                    Text(e.positionLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Button { Task { await e.next() } } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!e.canGoForward)
                .help(nextHelp)
            }

            HStack {
                Button { Task { await e.refreshNow() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if e.source != .personal, let c = e.current {
                    Button { Task { await e.save(c) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                }
                Spacer()
                Menu {
                    Button("Keep for 1 hour") { e.pause(hours: 1) }
                    Button("Keep for 1 day") { e.pause(hours: 24) }
                    Button("Keep for 1 week") { e.pause(hours: 168) }
                    Divider()
                    Button("Resume daily changes") { e.pause(hours: 0) }
                } label: {
                    Image(systemName: e.isPaused ? "pause.circle.fill" : "pause.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Keep this picture")
            }
            .controlSize(.small)

            if e.isPaused {
                Text("Paused until \(Date(timeIntervalSince1970: e.pausedUntil).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Gallery…") { show("gallery") }
                Button("Settings…") {
                    WindowCenter.shared.show("settings")
                    openSettings()
                }
                Spacer()
                Button { show("support") } label: { Image(systemName: "cup.and.saucer.fill") }
                    .help("Say thank you")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var subtitle: String {
        e.source == .personal ? e.source.fullName : "\(e.source.fullName) · \(Regions.name(e.region))"
    }

    private var nextHelp: String {
        switch e.source {
        case .bing: return "The next day"
        case .spotlight: return "The next picture — a new one when you're on the latest"
        case .personal: return "The next picture"
        }
    }

    @MainActor private func show(_ id: String) {
        WindowCenter.shared.show(id)
        openWindow(id: id)
    }
}

struct GalleryView: View {
    @EnvironmentObject var e: Engine
    @State private var tab: Source = .bing
    private let cols = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    private var items: [WallImage] { tab == .bing ? e.bing : e.spotlight }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Bing").tag(Source.bing)
                Text("Windows Spotlight").tag(Source.spotlight)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.top, 14)

            if items.isEmpty {
                Spacer()
                Text("Loading pictures…").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(items) { img in
                            VStack(alignment: .leading, spacing: 4) {
                                Thumb(img: img)
                                    .overlay(alignment: .topTrailing) {
                                        if e.current?.id == img.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title2)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(Color.white, Color.green)
                                                .padding(6)
                                                .help("On your desktop now")
                                        }
                                    }
                                HStack {
                                    Text(img.title).font(.subheadline).lineLimit(1)
                                    Spacer()
                                    if img.source == .bing {
                                        Text(Day.label(img.day)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                HStack {
                                    Button("Set as Wallpaper") { Task { await e.useFromGallery(img) } }
                                    Button("Save") { Task { await e.save(img) } }
                                }
                                .controlSize(.small)
                            }
                            .help(img.copyright)
                        }
                    }
                    .padding()
                }
            }
            Text("Your pick stays on your desktop until the next daily picture.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 540, minHeight: 440)
        .background(WindowHook(id: "gallery"))
        .task { await e.prepareGallery() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var e: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var feedbackKind: Feedback.Kind = .idea
    @State private var feedbackNote = ""

    var body: some View {
        Form {
            Section("Wallpaper") {
                Picker("Picture", selection: $e.sourceRaw) {
                    ForEach(Source.allCases) { s in Text(s.fullName).tag(s.rawValue) }
                }
                Picker("Region", selection: $e.region) {
                    ForEach(Regions.all) { r in
                        Text(r.code == "auto" ? "Automatic (\(Regions.name(Regions.system)))" : r.name).tag(r.code)
                    }
                }
                Picker("Resolution", selection: $e.resolutionRaw) {
                    ForEach(Resolution.allCases) { r in Text(Screens.label(r)).tag(r.rawValue) }
                }
                Text("Automatic fits each display, including displays turned to portrait. Each region gets its own Bing picture; Windows Spotlight pictures come in 4K.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Daily pictures") {
                Toggle("Notify me when a new picture is published", isOn: $e.notify)
                Toggle("Automatically save daily pictures to Pictures › DynamicWall", isOn: $e.autoSave)
                Toggle("Show the picture's description on the wallpaper", isOn: $e.overlay)
            }
            Section("My pictures slideshow") {
                ForEach(e.folders, id: \.self) { f in
                    HStack {
                        Text(f.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { e.removeFolder(f) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.allowsMultipleSelection = true
                    p.prompt = "Use Folder"
                    if p.runModal() == .OK { e.addFolders(p.urls) }
                }
                Stepper("Change every \(e.slideMinutes) min", value: $e.slideMinutes, in: 5...1440, step: 5)
                Toggle("Shuffle", isOn: $e.shuffle)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { loginOn = SMAppService.mainApp.status == .enabled }
                    }
                Button("Open saved pictures folder") { NSWorkspace.shared.open(Paths.saveFolder) }
                LabeledContent("Version", value: Feedback.version)
                Text("Low Power Mode automatically slows checks and slideshows. On macOS Sonoma and later, the lock screen uses your desktop wallpaper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Text("Found a bug, or have an idea to make DynamicWall better? Send it straight to the developer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Topic", selection: $feedbackKind) {
                    ForEach(Feedback.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                LabeledContent("Email") {
                    Text(Feedback.address).textSelection(.enabled)
                }
                HStack {
                    Button("Send Feedback…") {
                        if Feedback.compose(feedbackKind) {
                            feedbackNote = ""
                        } else {
                            Feedback.copyAddress()
                            feedbackNote = "No email app is set up, so the address was copied. Paste it into your email."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Copy Address") {
                        Feedback.copyAddress()
                        feedbackNote = "Copied \(Feedback.address)"
                    }
                    if let repo = Feedback.repoURL {
                        Button("View on GitHub") { NSWorkspace.shared.open(repo) }
                    }
                }
                if !feedbackNote.isEmpty {
                    Text(feedbackNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Support") {
                Button("Say thank you ☕…") {
                    WindowCenter.shared.show("support")
                    openWindow(id: "support")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .background(WindowHook(id: "settings"))
    }
}

@main
struct DynamicWallApp: App {
    @StateObject var engine = Engine()

    var body: some Scene {
        MenuBarExtra("DynamicWall", systemImage: "photo.on.rectangle.angled") {
            MenuView().environmentObject(engine)
        }
        .menuBarExtraStyle(.window)

        Window("Gallery", id: "gallery") {
            GalleryView().environmentObject(engine)
        }
        .defaultSize(width: 760, height: 560)

        Window("Say Thank You", id: "support") {
            SupportView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView().environmentObject(engine)
        }
    }
}
