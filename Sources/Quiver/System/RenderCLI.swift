import SwiftUI
import AppKit

/// Dev-only visual verification: `Quiver --render-png <path>` scans, then rasterizes the
/// real panel (with live data) to a PNG via ImageRenderer — no menu-bar click needed.
/// Pumps the main run loop while the async scan completes (can't block main here).
enum RenderCLI {
    static func runIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--render-png"),
              idx + 1 < CommandLine.arguments.count else { return }
        let outPath = CommandLine.arguments[idx + 1]

        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()

        Task { @MainActor in
            let app = AppState()
            await app.refresh()
            let view = PanelView(scrollable: false)
                .environment(app)
                .frame(width: Theme.panelWidth)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage,
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
}
