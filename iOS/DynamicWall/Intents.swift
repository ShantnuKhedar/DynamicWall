// The "Get DynamicWall Picture" action for the Shortcuts app.
// Pair it with "Set Wallpaper Photo" to change the wallpaper, and run it from a daily automation.

import AppIntents
import UniformTypeIdentifiers

enum SourceOption: String, AppEnum {
    case bing, spotlight

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Picture Source"
    static var caseDisplayRepresentations: [SourceOption: DisplayRepresentation] = [
        .bing: "Bing",
        .spotlight: "Windows Spotlight",
    ]

    var source: Source { self == .bing ? .bing : .spotlight }
}

enum WallpaperError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable

    var localizedStringResource: LocalizedStringResource {
        "Couldn't get today's picture. Check your internet connection and try again."
    }
}

struct GetWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Get DynamicWall Picture"
    static var description = IntentDescription(
        "Gets today's Bing or Windows Spotlight picture, sized for your iPhone. Add “Set Wallpaper Photo” after it to change your wallpaper.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Source", description: "Leave empty to use the picture chosen in the DynamicWall app.")
    var source: SourceOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Get DynamicWall picture from \(\.$source)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let url = await WallpaperService.shared.wallpaperFile(source: source?.source) else {
            throw WallpaperError.unavailable
        }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .jpeg))
    }
}

struct DynamicWallShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetWallpaperIntent(),
            phrases: [
                "Get \(.applicationName) picture",
                "Get today's \(.applicationName) wallpaper",
            ],
            shortTitle: "Get Picture",
            systemImageName: "photo"
        )
    }
}
