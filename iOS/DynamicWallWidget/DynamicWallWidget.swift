// DynamicWall widgets:
//  • Picture of the Day — today's wallpaper
//  • Up Next — the Windows Spotlight picture your automation will set tomorrow
//  • Browse — flip through recent Bing and Spotlight pictures with ‹ › buttons
//  • Favorites — rotates through the pictures you've hearted
//  • Lock Screen — the name and place of today's picture
//
// The app shares what it knows through the Keychain (see SharedStore). If that isn't available,
// the widgets fall back to fetching Bing pictures themselves.

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Data

struct PicEntry: TimelineEntry {
    let date: Date
    var pic: WallImage?
    var image: UIImage?
    var caption = ""
    var position = ""
    var message = ""
}

enum WidgetData {
    static func state() -> SharedState { SharedStore.read() }

    static func bing() async -> [WallImage] {
        let s = state()
        if !s.bing.isEmpty { return s.bing }
        return await WallpaperService.shared.bingImages()
    }

    /// A small version of the picture (widgets have tight memory limits).
    static func image(_ img: WallImage, maxPixel: Int = 900) async -> UIImage? {
        Paths.prune(days: 5)                            // keep the widget's own cache small
        let v = Variant(key: "widget", urls: Array(img.thumbURLs.reversed()))
        guard let f = await Fetch.file(img, v) else { return nil }
        return Img.downsample(f, maxPixel: maxPixel)
    }

    /// Tapping a widget opens the app on this picture.
    static func link(_ img: WallImage) -> URL? {
        guard let data = try? JSONEncoder().encode(img) else { return nil }
        var c = URLComponents()
        c.scheme = "dynamicwall"
        c.host = "show"
        c.queryItems = [URLQueryItem(name: "pic", value: data.base64EncodedString())]
        return c.url
    }

    static func entry(_ img: WallImage?, caption: String, position: String = "", message: String = "",
                      date: Date = Date(), withImage: Bool = true) async -> PicEntry {
        var e = PicEntry(date: date, pic: img, caption: caption, position: position, message: message)
        if withImage, let img { e.image = await image(img) }
        return e
    }

    // Loaders for each widget

    static func today() async -> [PicEntry] {
        var pic = state().today
        if pic == nil { pic = await bing().first }
        return [await entry(pic, caption: "Today", message: "No connection")]
    }

    static func upNext() async -> [PicEntry] {
        guard let pic = state().upNext else {
            return [PicEntry(date: Date(), caption: "Up next", message: "Shows tomorrow's picture when DynamicWall is set to Windows Spotlight.")]
        }
        return [await entry(pic, caption: "Tomorrow · Spotlight")]
    }

    static func browse() async -> [PicEntry] {
        let s = state()
        let items = await bing() + s.recentSpotlight
        guard !items.isEmpty else { return [PicEntry(date: Date(), message: "No connection")] }
        let raw = UserDefaults.standard.integer(forKey: "browseIndex")
        let i = ((raw % items.count) + items.count) % items.count
        let pic = items[i]
        let caption = pic.source == .bing ? "Bing · \(Day.label(pic.day))" : "Spotlight"
        return [await entry(pic, caption: caption, position: "\(i + 1)/\(items.count)")]
    }

    static func favorites() async -> [PicEntry] {
        let favs = state().favorites
        guard !favs.isEmpty else {
            return [PicEntry(date: Date(), caption: "Favorites", message: "Tap ♥ in DynamicWall to add pictures here.")]
        }
        // A new favorite every 3 hours.
        let slot = Int(Date().timeIntervalSince1970 / 10800)
        var entries: [PicEntry] = []
        for k in 0..<min(4, favs.count) {
            let pic = favs[(slot + k) % favs.count]
            let date = k == 0 ? Date() : Date(timeIntervalSince1970: TimeInterval(slot + k) * 10800)
            entries.append(await entry(pic, caption: "♥ Favorite", date: date))
        }
        return entries
    }

    static func lockScreen() async -> [PicEntry] {
        var pic = state().today
        if pic == nil { pic = await bing().first }
        return [await entry(pic, caption: "Today's wallpaper", withImage: false)]
    }
}

struct PicProvider: TimelineProvider {
    let load: () async -> [PicEntry]
    var refresh: TimeInterval = 3 * 3600

    func placeholder(in context: Context) -> PicEntry {
        PicEntry(date: Date(), caption: "DynamicWall", message: "Picture of the day")
    }

    func getSnapshot(in context: Context, completion: @escaping (PicEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await load().first ?? placeholder(in: context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PicEntry>) -> Void) {
        Task {
            var entries = await load()
            if entries.isEmpty { entries = [placeholder(in: context)] }
            let end = max(entries.last?.date ?? Date(), Date()).addingTimeInterval(refresh)
            completion(Timeline(entries: entries, policy: .after(end)))
        }
    }
}

// MARK: - Browse buttons

struct BrowseStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Browse Pictures"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Step")
    var step: Int

    init() {}
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: "browseIndex") + step, forKey: "browseIndex")
        return .result()
    }
}

// MARK: - Views

struct PictureView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PicEntry
    var browsable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !entry.caption.isEmpty {
                Text(entry.caption)
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.7), radius: 2)
            }
            Spacer(minLength: 0)
            if entry.pic == nil, !entry.message.isEmpty {
                Text(entry.message)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            if let p = entry.pic, family != .systemSmall {
                Text(p.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 3)
            }
            if browsable {
                HStack {
                    // Older pictures are further along the list, so ‹ steps forward in it.
                    Button(intent: BrowseStepIntent(step: 1)) { Image(systemName: "chevron.left.circle.fill") }
                    Spacer()
                    Text(entry.position).font(.caption2.weight(.semibold))
                    Spacer()
                    Button(intent: BrowseStepIntent(step: -1)) { Image(systemName: "chevron.right.circle.fill") }
                }
                .font(.title2)
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.6), radius: 3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .widgetURL(entry.pic.flatMap { WidgetData.link($0) })
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PicEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(entry.pic?.location ?? "DynamicWall", systemImage: "photo")
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Text("TODAY'S WALLPAPER")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.pic?.location ?? "Open DynamicWall")
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(entry.pic.flatMap { WidgetData.link($0) })
    }
}

// MARK: - Widgets

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyPicture", provider: PicProvider(load: WidgetData.today)) { PictureView(entry: $0) }
            .configurationDisplayName("Picture of the Day")
            .description("Today's wallpaper on your Home Screen.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNext", provider: PicProvider(load: WidgetData.upNext)) { PictureView(entry: $0) }
            .configurationDisplayName("Up Next")
            .description("The Windows Spotlight picture your wallpaper changes to tomorrow.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct BrowseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Browse", provider: PicProvider(load: WidgetData.browse)) { PictureView(entry: $0, browsable: true) }
            .configurationDisplayName("Browse Pictures")
            .description("Flip through recent Bing and Spotlight pictures. Tap one to open it in DynamicWall.")
            .supportedFamilies([.systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Favorites", provider: PicProvider(load: WidgetData.favorites)) { PictureView(entry: $0) }
            .configurationDisplayName("Favorites")
            .description("A different favorite picture every few hours.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LockScreen", provider: PicProvider(load: WidgetData.lockScreen)) { LockScreenView(entry: $0) }
            .configurationDisplayName("Today's Place")
            .description("Where today's wallpaper was taken.")
            .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

@main
struct DynamicWallWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        UpNextWidget()
        BrowseWidget()
        FavoritesWidget()
        LockScreenWidget()
    }
}
