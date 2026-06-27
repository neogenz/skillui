import SwiftUI
import AppKit

/// Dev-only visual verification: rasterize a surface to PNG with live data — no GUI needed.
///   --render-png <path>        the menu-bar panel
///   --render-settings <path>   the Settings form
///   --render-dashboard <path>  the dashboard window
/// Add --dark for dark mode. SKILLUI_SCAN_ROOT narrows the dashboard project scan.
/// Pumps the main run loop while the async scan completes (can't block main here).
enum RenderCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        let flags: [(flag: String, target: String)] = [
            ("--render-png", "panel"), ("--render-settings", "settings"), ("--render-dashboard", "dashboard"),
        ]
        var target: String?
        var outPath: String?
        for f in flags {
            if let i = args.firstIndex(of: f.flag), i + 1 < args.count { target = f.target; outPath = args[i + 1]; break }
        }
        guard let target, let outPath else { return }
        let dark = args.contains("--dark")

        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()

        Task { @MainActor in
            let app = AppState()
            if let root = ProcessInfo.processInfo.environment["SKILLUI_SCAN_ROOT"] { app.scanRoot = root }
            await app.refresh()

            let content: AnyView
            let size: CGSize
            switch target {
            case "settings":
                content = AnyView(SettingsView().environment(app).frame(width: 460, height: 540))
                size = CGSize(width: 460, height: 540)
            case "dashboard":
                content = AnyView(DashboardView().environment(app).frame(width: 980, height: 560))
                size = CGSize(width: 980, height: 560)
            default:
                content = AnyView(PanelView(scrollable: false).environment(app).frame(width: Theme.panelWidth))
                size = .zero
            }
            let view = content.environment(\.colorScheme, dark ? .dark : .light)

            let image = target == "panel"
                ? Self.renderWithImageRenderer(view)
                : Self.renderWithHostingView(view, size: size)
            if let img = image,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outPath))
                print("rendered \(Int(img.size.width))x\(Int(img.size.height)) → \(outPath)")
            } else {
                print("render failed")
            }
            flag.done = true
        }
        while !flag.done { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        exit(0)
    }

    @MainActor private static func renderWithImageRenderer(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor private static func renderWithHostingView(_ view: some View, size: CGSize) -> NSImage? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
