import SwiftUI

let isDevBuild: Bool = {
    let path = ProcessInfo.processInfo.arguments[0]
    return path.contains(".build/") || path.contains("/DerivedData/")
}()

@main
struct StreifenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = MenuBarViewModel.shared

    /// Render a menu bar icon: rounded rect with workspace number knocked out.
    /// Dev builds get a small dot in the top-right corner.
    /// Template image: opaque → menu bar color, transparent → see-through.
    private static func makeIcon(number: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            // In dev mode we manage colors ourselves; release uses template mode
            let fillColor: NSColor = isDevBuild
                ? (NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .white : NSColor(white: 0.2, alpha: 1))
                : .black

            // Filled rounded rect
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            fillColor.setFill()
            path.fill()

            // Punch out the number (clear blend mode → transparent where text is)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setBlendMode(.clear)

            let str = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let strSize = str.size(withAttributes: attrs)
            let strRect = CGRect(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect, withAttributes: attrs)

            // Dev mode: orange dot top-right
            if isDevBuild {
                ctx.setBlendMode(.normal)
                NSColor.systemOrange.setFill()
                let dotSize: CGFloat = 6
                let dot = NSBezierPath(ovalIn: CGRect(
                    x: rect.maxX - dotSize,
                    y: rect.maxY - dotSize,
                    width: dotSize,
                    height: dotSize
                ))
                dot.fill()
            }

            return true
        }
        img.isTemplate = !isDevBuild
        return img
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(nsImage: Self.makeIcon(number: viewModel.activeWorkspace))
        }
        .menuBarExtraStyle(.menu)
    }
}
