import AppKit
import SwiftUI

/// Shows a picture centered on a checkerboard, fitted to the window or at actual size; pinch to zoom.
struct ImageViewer: View {
    let document: EditorDocument
    @State private var zoom = Zoom.fit

    enum Zoom: Hashable {
        case fit, actual
    }

    var body: some View {
        VStack(spacing: 0) {
            if let image = document.image {
                ImageScrollView(image: image, zoom: zoom)
                Divider()
                HStack(spacing: 12) {
                    Text(info(for: image))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Boyut", selection: $zoom) {
                        Text("Sığdır").tag(Zoom.fit)
                        Text("%100").tag(Zoom.actual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if !document.isRasterImage {
                        Button("Kaynağı Düzenle") { document.showsImage = false }
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([document.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Finder'da göster")
                    .accessibilityLabel("Finder'da göster")
                }
                .font(.caption)
                .controlSize(.small)
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.bar)
            } else {
                ContentUnavailableView(document.title, systemImage: "photo", description: Text("Görsel açılamadı."))
            }
        }
    }

    private func info(for image: NSImage) -> String {
        var parts: [String] = []
        // Pixel size of the largest representation; `size` is in points and may be halved for @2x files.
        let pixels = image.representations.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
        if let pixels, pixels.width > 0 {
            parts.append("\(Int(pixels.width))×\(Int(pixels.height)) px")
        } else {
            parts.append("\(Int(image.size.width))×\(Int(image.size.height))")
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: document.url.path))?[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append(document.url.pathExtension.uppercased())
        return parts.joined(separator: " · ")
    }
}

private struct ImageScrollView: NSViewRepresentable {
    let image: NSImage
    let zoom: ImageViewer.Zoom

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 32
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.checkerboard
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        if imageView.image !== image {
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
        }
        if context.coordinator.zoom != zoom || context.coordinator.image !== image {
            context.coordinator.zoom = zoom
            context.coordinator.image = image
            DispatchQueue.main.async { apply(zoom, to: scrollView) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var zoom: ImageViewer.Zoom?
        var image: NSImage?
    }

    private func apply(_ zoom: ImageViewer.Zoom, to scrollView: NSScrollView) {
        switch zoom {
        case .actual:
            scrollView.magnification = 1
        case .fit:
            let available = scrollView.contentSize
            guard image.size.width > 0, image.size.height > 0 else { return }
            // Shrink large pictures to fit; never blow small ones up.
            let scale = min(1, min(available.width / image.size.width, available.height / image.size.height) * 0.95)
            scrollView.magnification = scale
        }
    }

    /// Light and dark squares that show where a picture is transparent.
    private static let checkerboard = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? darkPattern : lightPattern
    }
    private static let lightPattern = pattern(NSColor(white: 1, alpha: 1), NSColor(white: 0.9, alpha: 1))
    private static let darkPattern = pattern(NSColor(white: 0.16, alpha: 1), NSColor(white: 0.21, alpha: 1))

    private static func pattern(_ base: NSColor, _ square: NSColor) -> NSColor {
        let size: CGFloat = 16
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.setFill()
            rect.fill()
            square.setFill()
            NSRect(x: 0, y: 0, width: size / 2, height: size / 2).fill()
            NSRect(x: size / 2, y: size / 2, width: size / 2, height: size / 2).fill()
            return true
        }
        return NSColor(patternImage: image)
    }
}

/// Keeps a document smaller than the scroll view in the middle instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}
