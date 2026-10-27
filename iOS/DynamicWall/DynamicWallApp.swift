// DynamicWall for iPhone — daily Bing & Windows Spotlight wallpapers.
//
// iPhone apps can't change the wallpaper themselves, so DynamicWall gives the Shortcuts app a
// "Get DynamicWall Picture" action. A shortcut ("Get DynamicWall Picture" → "Set Wallpaper Photo"),
// run by a daily automation, changes the wallpaper every morning and keeps your Lock Screen setup.

import SwiftUI
import UIKit
import Photos

@main
struct DynamicWallApp: App {
    @StateObject private var lib = Library()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lib)
                .onOpenURL { lib.handle($0) }
        }
    }
}

// MARK: - State

@MainActor
final class Library: ObservableObject {
    @AppStorage(Keys.source) var sourceRaw = Source.bing.rawValue {
        didSet {
            if skipReload { skipReload = false; return }
            Task { await load() }
        }
    }
    @AppStorage(Keys.region) var region = "auto" { didSet { Task { await regionChanged() } } }
    @AppStorage("shortcutName") var shortcutName = "DynamicWall"
    @AppStorage("setupDone") var setupDone = false

    @Published var tab = 0
    @Published var bing: [WallImage] = []            // last 8 days, newest first
    @Published var spotlight: [WallImage] = []       // Spotlight pictures you've had, newest first
    @Published var spotlightPool: [WallImage] = []   // everything fetched from Spotlight (gallery)
    @Published var favorites: [WallImage] = []
    @Published var index = 0                         // position in the current list (0 = newest)
    @Published var image: UIImage?                   // the wallpaper preview (already cropped)
    @Published var currentFile: URL?                 // the cropped 4K wallpaper file
    @Published var loading = false
    @Published var message: String?

    private var skipReload = false
    private var loadedDay = ""
    private var lastLoad = Date.distantPast
    // The picture you were looking at, remembered even if iOS closes the app.
    @AppStorage("viewImage") private var viewData = Data()
    @AppStorage("viewDay") private var viewDay = ""
    private var pinned: WallImage?                  // picture opened from a widget link

    var source: Source { Source(rawValue: sourceRaw) ?? .bing }
    var list: [WallImage] { source == .bing ? bing : spotlight }
    var current: WallImage? { list.indices.contains(index) ? list[index] : nil }
    var canGoBack: Bool { index + 1 < list.count }
    var canGoForward: Bool { source == .spotlight || index > 0 }   // Spotlight: Next fetches a new one
    var isFavorite: Bool { current.map { c in favorites.contains { $0.id == c.id } } ?? false }

    var positionLabel: String {
        guard let c = current else { return "" }
        if c.source == .bing { return Day.label(c.day) }
        return index == 0 ? "Latest" : "\(index) back"
    }

    /// Saves this iPhone's screen size (in pixels) so pictures are cropped to its exact shape.
    func recordScreen() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let b = scene.screen.nativeBounds.size
        UserDefaults.standard.set(Double(min(b.width, b.height)), forKey: Keys.screenW)
        UserDefaults.standard.set(Double(max(b.width, b.height)), forKey: Keys.screenH)
    }

    func load(force: Bool = false) async {
        // Coming back on the same day keeps the picture you were looking at.
        let remembered = (!force && viewDay == Day.today) ? (try? JSONDecoder().decode(WallImage.self, from: viewData)) : nil
        let keep = remembered.flatMap { $0.source == source ? $0 : nil }
        loading = true
        let service = WallpaperService.shared
        bing = await service.bingImages(force: force)
        if source == .spotlight { _ = await service.todaySpotlight() }
        let shown = await service.spotlightShown()
        spotlight = Array(shown.reversed())
        favorites = await service.favorites()
        if let k = keep {
            // A gallery or favorite pick that isn't in today's list (e.g. an old Bing day) is kept too.
            if k.source == .bing, !bing.contains(where: { $0.id == k.id }) { bing.append(k) }
            if k.source == .spotlight, !spotlight.contains(where: { $0.id == k.id }) { spotlight.insert(k, at: 0) }
        }
        index = keep.flatMap { k in list.firstIndex { $0.id == k.id } } ?? 0
        loadedDay = Day.today
        lastLoad = Date()
        loading = false
        await loadImage()
        await service.prepareUpNext()
        await service.publish()
        if let p = pinned {
            pinned = nil
            await use(p)
        }
    }

    /// Coming back to the app: reload only on a new day, after an hour, or if nothing is loaded.
    func refreshIfNeeded() async {
        guard loadedDay != Day.today || Date().timeIntervalSince(lastLoad) > 3600 || list.isEmpty else { return }
        await load()
    }

    func loadPool(force: Bool) async {
        if !force && !spotlightPool.isEmpty { return }
        spotlightPool = await WallpaperService.shared.spotlightPool(force: force)
    }

    private func regionChanged() async {
        await WallpaperService.shared.resetForRegion()
        spotlightPool = []
        await load(force: true)
    }

    // MARK: Previous / Next

    func previous() async {
        guard canGoBack else { return }
        index += 1
        await loadImage()
    }

    func next() async {
        if index > 0 {
            index -= 1
        } else if source == .spotlight {
            loading = true
            if await WallpaperService.shared.newSpotlight() != nil {
                let shown = await WallpaperService.shared.spotlightShown()
                spotlight = Array(shown.reversed())
                index = 0
                await WallpaperService.shared.prepareUpNext()
                await WallpaperService.shared.publish()
            }
            loading = false
        } else {
            return
        }
        await loadImage()
    }

    /// Shows a picture chosen in the gallery or a widget on the Today tab.
    func use(_ img: WallImage) async {
        if img.source != source {
            skipReload = true
            sourceRaw = img.source.rawValue
        }
        switch img.source {
        case .spotlight:
            await WallpaperService.shared.addShown(img)
            let shown = await WallpaperService.shared.spotlightShown()
            spotlight = Array(shown.reversed())
        case .bing:
            if !bing.contains(where: { $0.id == img.id }) { bing.append(img) }
        }
        index = list.firstIndex { $0.id == img.id } ?? 0
        tab = 0
        await loadImage()
    }

    func loadImage() async {
        guard let img = current else {
            image = nil
            currentFile = nil
            loading = false
            return
        }
        loading = true
        let file = await WallpaperService.shared.wallpaper(for: img)
        let ui: UIImage?
        if let file {
            ui = await Task.detached(priority: .userInitiated) { Img.downsample(file, maxPixel: 2700) }.value
        } else {
            ui = nil
        }
        guard current?.id == img.id else { return }      // you moved on while it loaded
        image = ui
        currentFile = file
        loading = false
        viewData = (try? JSONEncoder().encode(img)) ?? Data()
        viewDay = Day.today
        if file == nil { message = "Couldn't download this picture. Check your connection." }
    }

    // MARK: Favorites & cropping

    func toggleFavorite() async {
        guard let c = current else { return }
        let added = await WallpaperService.shared.toggleFavorite(c)
        favorites = await WallpaperService.shared.favorites()
        message = added ? "Added to Favorites ♥" : "Removed from Favorites"
        await WallpaperService.shared.publish()
    }

    func saveCrop(_ r: CGRect, for img: WallImage) async {
        await WallpaperService.shared.setCrop(r, for: img.id)
        await loadImage()
    }

    func autoCrop(for img: WallImage) async -> CGRect? {
        await WallpaperService.shared.smartCrop(for: img)       // saved only when you tap Done
    }

    // MARK: Actions

    /// Remembers the picture and returns the link that runs your wallpaper shortcut,
    /// coming straight back to DynamicWall when it's done.
    func setAsWallpaper() async -> URL? {
        guard let img = current else { return nil }
        await WallpaperService.shared.setPicked(img)
        let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: name.isEmpty ? "DynamicWall" : name),
            URLQueryItem(name: "x-success", value: "dynamicwall://done"),
            URLQueryItem(name: "x-cancel", value: "dynamicwall://cancel"),
            URLQueryItem(name: "x-error", value: "dynamicwall://error"),
        ]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    /// Links back into the app: from Shortcuts (done/error) and from widgets (show a picture).
    func handle(_ url: URL) {
        guard url.scheme == "dynamicwall" else { return }
        switch url.host {
        case "done":
            message = "Wallpaper set ✓"
        case "error":
            message = "The shortcut couldn't set the wallpaper. Check it in Shortcuts."
        case "show":
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "pic" })?.value,
                  let data = Data(base64Encoded: value),
                  let img = (try? JSONDecoder().decode(WallImage.self, from: data))?.sanitized() else { return }
            pinned = img
            Task { await use(img) }
        default:
            break
        }
    }

    func saveToPhotos() async {
        guard let file = currentFile else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow DynamicWall to add photos in Settings › Privacy & Security › Photos."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
            message = "Saved to Photos"
        } catch {
            message = "Couldn't save to Photos."
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var lib: Library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $lib.tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "photo") }
                .tag(0)
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "square.grid.2x2") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .task {
            lib.recordScreen()
            Paths.prune()
        }
        // Loads at launch and every time you come back, so a new day shows the new picture.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await lib.refreshIfNeeded() } }
        }
    }
}

// MARK: - Today

struct TodayView: View {
    @EnvironmentObject var lib: Library
    @Environment(\.openURL) private var openURL
    @State private var showSetup = false
    @State private var showPanel = true
    @State private var editing: WallImage?

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Group {
                    if let img = lib.image {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showPanel.toggle() } }
            // Swipe left for the next picture, right for the previous one.
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) else { return }
                    Task {
                        if dx < 0 { await lib.next() } else { await lib.previous() }
                    }
                }
            )

            if showPanel {
                VStack {
                    Picker("Picture", selection: $lib.sourceRaw) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    Spacer()
                    panel
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let m = lib.message {
                Text(m)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: lib.message) { _, m in
            guard m != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { lib.message = nil }
            }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(runAfter: true).environmentObject(lib)
        }
        .fullScreenCover(item: $editing) { img in
            CropEditor(img: img).environmentObject(lib)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lib.current?.title ?? (lib.loading ? "Loading…" : "No picture yet"))
                        .font(.headline)
                        .lineLimit(2)
                    if let c = lib.current, !c.copyright.isEmpty {
                        Text(c.copyright).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer()
                if lib.loading { ProgressView() }
            }

            HStack {
                Button { Task { await lib.previous() } } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(!lib.canGoBack)
                Spacer()
                Text(lib.positionLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await lib.next() } } label: {
                    HStack(spacing: 4) { Text("Next"); Image(systemName: "chevron.right") }
                }
                .disabled(!lib.canGoForward)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                Button { editing = lib.current } label: {
                    Label("Zoom & Select", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                .disabled(lib.current == nil)

                Button { setWallpaper() } label: {
                    Label("Set as Wallpaper", systemImage: "iphone.gen3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(lib.current == nil)
            }
            .controlSize(.large)

            HStack {
                Button { Task { await lib.toggleFavorite() } } label: {
                    Label("Favorite", systemImage: lib.isFavorite ? "heart.fill" : "heart")
                }
                .tint(lib.isFavorite ? .pink : .primary)
                .disabled(lib.current == nil)
                Spacer()
                Button { Task { await lib.saveToPhotos() } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(lib.currentFile == nil)
                Spacer()
                if let url = lib.currentFile {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                Spacer()
                Button { Task { await lib.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
        }
    }

    private func setWallpaper() {
        if !lib.setupDone {
            showSetup = true
            return
        }
        Task {
            if let u = await lib.setAsWallpaper() { openURL(u) }
        }
    }
}

// MARK: - Zoom & Select

/// Pinch and drag the 4K picture inside a frame shaped like your screen, with a clock preview.
struct CropEditor: View {
    let img: WallImage
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss

    @State private var picture: UIImage?
    @State private var pixel: CGSize = .zero        // size of `picture` in pixels
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var frameSize: CGSize = .zero
    @State private var showClock = true
    @State private var prepared = false

    private var aspect: CGFloat { Prefs.aspect }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fs = frameFor(geo.size)
                ZStack {
                    Color.black
                    if let picture {
                        let s = scale(fs)
                        Image(uiImage: picture)
                            .resizable()
                            .frame(width: pixel.width * s, height: pixel.height * s)
                            .offset(offset)
                    } else {
                        ProgressView().tint(.white)
                    }
                    HoleShape(hole: CGRect(x: (geo.size.width - fs.width) / 2, y: (geo.size.height - fs.height) / 2,
                                           width: fs.width, height: fs.height))
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: fs.width * 0.12)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                        .frame(width: fs.width, height: fs.height)
                        .allowsHitTesting(false)
                    if showClock {
                        VStack(spacing: 0) {
                            Text(Date(), format: .dateTime.weekday(.wide).month().day())
                                .font(.system(size: fs.width * 0.055, weight: .semibold))
                            Text(Date(), format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                                .font(.system(size: fs.width * 0.24, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(y: -fs.height / 2 + fs.height * 0.17)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                offset = clamp(CGSize(width: baseOffset.width + v.translation.width,
                                                      height: baseOffset.height + v.translation.height), fs)
                            }
                            .onEnded { _ in baseOffset = offset },
                        MagnifyGesture()
                            .onChanged { v in
                                zoom = min(max(baseZoom * v.magnification, 1), 6)
                                offset = clamp(offset, fs)
                            }
                            .onEnded { _ in
                                baseZoom = zoom
                                baseOffset = offset
                            }
                    )
                )
                .task(id: geo.size) {
                    frameSize = fs
                    await prepare()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color.black)
            .navigationTitle("Zoom & Select")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let r = cropRect(frameSize)
                        Task {
                            await lib.saveCrop(r, for: img)
                            dismiss()
                        }
                    }
                    .disabled(picture == nil)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        Task { if let r = await lib.autoCrop(for: img) { apply(r, frameSize) } }
                    } label: { Label("Auto", systemImage: "wand.and.stars") }
                    Spacer()
                    Text("Pinch to zoom, drag to move").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { showClock.toggle() } label: {
                        Label("Clock", systemImage: showClock ? "clock.fill" : "clock")
                    }
                }
            }
        }
    }

    private func prepare() async {
        if !prepared {
            guard let file = await WallpaperService.shared.file(for: img) else { return }
            let ui = await Task.detached(priority: .userInitiated) { Img.downsample(file, maxPixel: 2400) }.value
            guard let ui, let cg = ui.cgImage else { return }
            picture = ui
            pixel = CGSize(width: cg.width, height: cg.height)
            prepared = true
        }
        if let r = await WallpaperService.shared.crop(for: img) { apply(r, frameSize) }
    }

    /// The phone-shaped frame, as large as fits on screen.
    private func frameFor(_ size: CGSize) -> CGSize {
        let maxW = max(size.width - 64, 50), maxH = max(size.height - 120, 50)
        var w = maxW, h = maxW / aspect
        if h > maxH { h = maxH; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    /// Points per picture pixel: the picture always covers the frame, then zoomed.
    private func scale(_ fs: CGSize) -> CGFloat {
        guard pixel.width > 0, pixel.height > 0 else { return 1 }
        return max(fs.width / pixel.width, fs.height / pixel.height) * zoom
    }

    /// Keeps the frame inside the picture.
    private func clamp(_ o: CGSize, _ fs: CGSize) -> CGSize {
        let s = scale(fs)
        let mx = max(0, (pixel.width * s - fs.width) / 2)
        let my = max(0, (pixel.height * s - fs.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    /// The part of the picture inside the frame, normalized (0…1, top-left origin).
    private func cropRect(_ fs: CGSize) -> CGRect {
        guard pixel.width > 0, pixel.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let s = scale(fs)
        let w = fs.width / s, h = fs.height / s
        let cx = pixel.width / 2 - offset.width / s
        let cy = pixel.height / 2 - offset.height / s
        return CGRect(x: (cx - w / 2) / pixel.width, y: (cy - h / 2) / pixel.height,
                      width: w / pixel.width, height: h / pixel.height)
    }

    /// Positions the picture so that `r` fills the frame.
    private func apply(_ r: CGRect, _ fs: CGSize) {
        guard pixel.width > 0, pixel.height > 0, r.width > 0 else { return }
        let base = max(fs.width / pixel.width, fs.height / pixel.height)
        zoom = min(max((fs.width / (r.width * pixel.width)) / base, 1), 6)
        baseZoom = zoom
        let s = scale(fs)
        offset = clamp(CGSize(width: (pixel.width / 2 - r.midX * pixel.width) * s,
                              height: (pixel.height / 2 - r.midY * pixel.height) * s), fs)
        baseOffset = offset
    }
}

/// A full-screen rectangle with a rounded hole (dims everything outside the frame).
struct HoleShape: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: hole.width * 0.12, height: hole.width * 0.12))
        return p
    }
}

// MARK: - Shortcut setup guide

struct SetupView: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var runAfter: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("iPhone apps aren't allowed to change your wallpaper themselves, so DynamicWall works with Apple's **Shortcuts** app. You only need to set this up once — your clock style and Lock Screen widgets are kept.")
                }
                if let link = Feedback.shortcutLink {
                    Section {
                        Button {
                            openURL(link)
                        } label: {
                            Label("Add the DynamicWall Shortcut", systemImage: "plus.circle.fill")
                                .font(.headline)
                        }
                    } footer: {
                        Text("Opens Shortcuts with the shortcut ready — tap **Add Shortcut**. Then set **Wallpaper** in both wallpaper actions to your wallpaper's number (count the cards from the left when you long-press the Lock Screen), and do steps 6–8 below for a new wallpaper every day.")
                    }
                }
                Section(Feedback.shortcutLink == nil ? "Make the shortcut" as String : "Or make it yourself") {
                    step(1, "Open **Shortcuts**, tap **+**, then tap the name at the top and call it **\(lib.shortcutName)**.")
                    step(2, "Tap **Search Actions**, type **DynamicWall** and choose **Get DynamicWall Picture**.")
                    step(3, "Search **Wallpaper** and add **Set Wallpaper Photo**.")
                    step(4, "Tap **Wallpaper** in it and choose your wallpaper's number — long-press the Lock Screen and count the cards from the left. Tap the arrow and turn off **Show Preview** and **Crop to Subject**.")
                    step(5, "Add **Switch Between Wallpapers** and choose the **same number**, so that wallpaper is always the one showing. Tap **Done**.")
                }
                Section {
                    step(6, "In Shortcuts, open the **Automation** tab and tap **+**.")
                    step(7, "Choose **Time of Day**, pick a time such as 8:00 AM, keep **Daily**, and select **Run Immediately**.")
                    step(8, "Tap **Next** and choose your **\(lib.shortcutName)** shortcut.")
                } header: {
                    Text("Change it every day")
                } footer: {
                    Text("Your current wallpaper must be a Photos wallpaper. Pictures you pick in DynamicWall are used for the rest of that day.")
                }
                Section {
                    Button {
                        if let u = URL(string: "shortcuts://") { openURL(u) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                    }
                    Button {
                        lib.setupDone = true
                        dismiss()
                        if runAfter {
                            Task { if let u = await lib.setAsWallpaper() { openURL(u) } }
                        }
                    } label: {
                        Label(runAfter ? "I've Done This — Set My Wallpaper" : "I've Done This", systemImage: "checkmark.circle")
                    }
                }
            }
            .navigationTitle("Set Up Wallpaper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}

// MARK: - Gallery

enum ThumbLoader {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        return c
    }()

    static func load(_ img: WallImage) async -> UIImage? {
        let key = img.id as NSString
        if let c = cache.object(forKey: key) { return c }
        let file = Paths.thumbs.appendingPathComponent("\(img.id).jpg")
        if !FileManager.default.fileExists(atPath: file.path) {
            let tmp = Paths.thumbs.appendingPathComponent("dl-\(UUID().uuidString).tmp")
            for u in img.thumbURLs {
                if await Net.image(u, to: tmp) {
                    _ = await Task.detached(priority: .utility) { Img.downscale(tmp, to: file, maxPixel: 640) }.value
                    break
                }
            }
            try? FileManager.default.removeItem(at: tmp)
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let ui = await Task.detached(priority: .utility) { Img.downsample(file, maxPixel: 640) }.value
        if let ui { cache.setObject(ui, forKey: key) }
        return ui
    }
}

struct Thumb: View {
    let img: WallImage
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: img.id) { image = await ThumbLoader.load(img) }
    }
}

enum GalleryTab: Hashable { case bing, spotlight, favorites }

struct GalleryView: View {
    @EnvironmentObject var lib: Library
    @State private var tab: GalleryTab = .bing
    @State private var selected: WallImage?
    @State private var triedLoading = false
    private let cols = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    private var items: [WallImage] {
        switch tab {
        case .bing: return lib.bing
        case .spotlight: return lib.spotlightPool
        case .favorites: return lib.favorites
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Source", selection: $tab) {
                    Text("Bing").tag(GalleryTab.bing)
                    Text("Spotlight").tag(GalleryTab.spotlight)
                    Label("Favorites", systemImage: "heart.fill").tag(GalleryTab.favorites)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if items.isEmpty {
                    if tab == .favorites {
                        Text("Tap ♥ on the Today tab to keep pictures you love here.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(40)
                    } else if triedLoading && !lib.loading {
                        Text("Couldn't load pictures. Pull down to try again.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                } else {
                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(items) { img in
                            Button { selected = img } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Thumb(img: img)
                                        .overlay(alignment: .topTrailing) {
                                            if lib.current?.id == img.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(Color.white, Color.green)
                                                    .font(.title3)
                                                    .padding(6)
                                            }
                                        }
                                    Text(img.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(img.source == .bing ? Day.label(img.day) : "Windows Spotlight")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Gallery")
            .refreshable {
                await lib.load(force: true)
                await lib.loadPool(force: true)
            }
            .task {
                await lib.loadPool(force: false)
                triedLoading = true
            }
            .sheet(item: $selected) { img in
                PictureSheet(img: img).environmentObject(lib)
            }
        }
    }
}

struct PictureSheet: View {
    let img: WallImage
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Thumb(img: img)
                    Text(img.title).font(.headline)
                    if !img.copyright.isEmpty {
                        Text(img.copyright).font(.callout).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            await lib.use(img)
                            dismiss()
                        }
                    } label: {
                        Label("Use This Picture", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle(img.source == .bing ? Day.label(img.day) : "Windows Spotlight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Settings

enum Feedback {
    static let address = "shanu.khedar.7@gmail.com"
    static let repoURL = URL(string: "https://github.com/ShantnuKhedar/DynamicWall")!
    /// iCloud link to the ready-made shortcut. nil hides the button.
    static let shortcutLink: URL? = URL(string: "https://www.icloud.com/shortcuts/d89c2b64d8f74a1580952969e0a26d3a")

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
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [
            URLQueryItem(name: "subject", value: "DynamicWall for iPhone – \(kind.rawValue)"),
            URLQueryItem(name: "body", value: "\n\n\n—\nDynamicWall \(version), \(ProcessInfo.processInfo.operatingSystemVersionString)"),
        ]
        return c.url
    }
}

struct SettingsView: View {
    @EnvironmentObject var lib: Library
    @Environment(\.openURL) private var openURL
    @State private var kind: Feedback.Kind = .idea
    @State private var note = ""
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Picture", selection: $lib.sourceRaw) {
                        ForEach(Source.allCases) { s in Text(s.fullName).tag(s.rawValue) }
                    }
                    Picker("Region", selection: $lib.region) {
                        ForEach(Regions.all) { r in
                            Text(r.code == "auto" ? "Automatic (\(Regions.name(Regions.system)))" : r.name).tag(r.code)
                        }
                    }
                } header: {
                    Text("Wallpaper")
                } footer: {
                    Text("Every picture is downloaded in 4K and cropped to your screen around its most interesting part. Use Zoom & Select to choose the part yourself.")
                }

                Section {
                    Button("Set Up Automatic Daily Wallpaper") { showSetup = true }
                    LabeledContent("Shortcut name") {
                        TextField("DynamicWall", text: $lib.shortcutName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Daily wallpaper")
                } footer: {
                    Text("iPhone apps can't change the wallpaper directly, so DynamicWall uses a Shortcut. Set it up once and your wallpaper changes every day.")
                }

                Section("Feedback") {
                    Text("Found a bug, or have an idea to make DynamicWall better? Send it straight to the developer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Topic", selection: $kind) {
                        ForEach(Feedback.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    Button("Send Feedback") {
                        guard let u = Feedback.mailURL(kind) else { return }
                        openURL(u) { accepted in
                            if !accepted {
                                UIPasteboard.general.string = Feedback.address
                                note = "No email app is set up, so the address was copied."
                            }
                        }
                    }
                    Button("Copy Email Address") {
                        UIPasteboard.general.string = Feedback.address
                        note = "Copied \(Feedback.address)"
                    }
                    Link("View on GitHub", destination: Feedback.repoURL)
                    if !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Support") {
                    NavigationLink("Say Thank You ☕") { SupportView() }
                }

                Section {
                    LabeledContent("Version", value: Feedback.version)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSetup) {
                SetupView(runAfter: false).environmentObject(lib)
            }
        }
    }
}

// MARK: - Say thank you

enum Support {
    static let paypalUser = "shantanukhedar"
    static let currency = "USD"

    static let message = """
    DynamicWall is free — no ads, no tracking, no subscriptions — and it will stay that way. \
    It's built by an independent developer, and every update takes real time and care. \
    If a fresh wallpaper each day makes you smile, a small coffee is a lovely way to say thanks \
    and helps fund future versions. Every bit of support means a lot. Thank you!
    """

    struct Tier: Identifiable {
        let id: Int
        let name: String
        let amount: Int?
        let iconSize: CGFloat
    }

    static let tiers: [Tier] = [
        Tier(id: 0, name: "Small coffee", amount: 1, iconSize: 22),
        Tier(id: 1, name: "Medium coffee", amount: 2, iconSize: 28),
        Tier(id: 2, name: "Large coffee", amount: 3, iconSize: 34),
        Tier(id: 3, name: "Extra large coffee", amount: 5, iconSize: 40),
        Tier(id: 4, name: "Any amount", amount: nil, iconSize: 32),
    ]

    static func link(_ amount: Int?) -> URL? {
        var s = "https://paypal.me/\(paypalUser)"
        if let a = amount { s += "/\(a)\(currency)" }
        return URL(string: s)
    }

    static func price(_ amount: Int) -> String { amount.formatted(.currency(code: currency)) }
}

struct SupportView: View {
    @Environment(\.openURL) private var openURL
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Enjoying DynamicWall?").font(.title2.bold())
                Text(Support.message).foregroundStyle(.secondary)
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(Support.tiers) { tier in
                        VStack(spacing: 10) {
                            Text(tier.name).font(.subheadline).multilineTextAlignment(.center).frame(height: 40)
                            Image(systemName: tier.amount == nil ? "gift.fill" : "cup.and.saucer.fill")
                                .font(.system(size: tier.iconSize))
                                .foregroundStyle(tier.amount == nil ? Color.red : Color.brown)
                                .frame(height: 44)
                            Button {
                                if let u = Support.link(tier.amount) { openURL(u) }
                            } label: {
                                Text(tier.amount.map(Support.price) ?? "With PayPal").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                Text("Payments are handled securely by PayPal. DynamicWall never sees your payment details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Say Thank You")
        .navigationBarTitleDisplayMode(.inline)
    }
}
