import Cocoa
import CoreImage
import UniformTypeIdentifiers

// MARK: - Bundled Background Generator

struct BundledBackground {
    let name: String
    let thumbnail: NSImage
    let makeCIImage: (CGSize) -> CIImage
}

final class BundledBackgroundGenerator {

    static let backgrounds: [BundledBackground] = {
        return [
            // 1. Aurora — purple/blue/orange
            makeDarkGrainy(name: "Aurora", layers: [
                (hex(0x4A1A8A), hex(0x1A0533), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
                (hex(0x2244AA), hex(0x0A0A22), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0xCC6622), hex(0x1A0A00), CGPoint(x: 1, y: 0.8), CGPoint(x: 0, y: 0.2)),
            ]),
            // 2. Ember — deep red/orange/dark
            makeDarkGrainy(name: "Ember", layers: [
                (hex(0x8B1A1A), hex(0x1A0505), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)),
                (hex(0xCC5500), hex(0x0F0500), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.2)),
            ]),
            // 3. Twilight — navy/purple/pink
            makeDarkGrainy(name: "Twilight", layers: [
                (hex(0x0A1628), hex(0x2D1B4E), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
                (hex(0x6B2255), hex(0x0A0A1A), CGPoint(x: 1, y: 0.7), CGPoint(x: 0, y: 0.3)),
            ]),
            // 4. Deep Ocean — dark teal/navy/blue
            makeDarkGrainy(name: "Deep Ocean", layers: [
                (hex(0x0A3D5C), hex(0x051122), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x1A5577), hex(0x040D1A), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            ]),
            // 5. Volcanic — dark red/crimson/black
            makeDarkGrainy(name: "Volcanic", layers: [
                (hex(0x5C0A0A), hex(0x0F0000), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x8B0000), hex(0x1A0505), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
            ]),
            // 6. Nebula — violet/magenta/dark blue
            makeDarkGrainy(name: "Nebula", layers: [
                (hex(0x5B1A8A), hex(0x0D0522), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
                (hex(0x8B226B), hex(0x0A0A22), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0)),
            ]),
            // 7. Forest Night — dark green/teal/black
            makeDarkGrainy(name: "Forest Night", layers: [
                (hex(0x0A3D1A), hex(0x020A05), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)),
                (hex(0x1A5544), hex(0x050F0A), CGPoint(x: 0.8, y: 0.5), CGPoint(x: 0.2, y: 0.5)),
            ]),
            // 8. Midnight Rose — dark pink/purple/navy
            makeDarkGrainy(name: "Midnight Rose", layers: [
                (hex(0x6B1A4A), hex(0x0A0515), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x2D1B4E), hex(0x0A0A1A), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            ]),
            // 9. Solar Flare — amber/orange/dark brown
            makeDarkGrainy(name: "Solar Flare", layers: [
                (hex(0xAA6600), hex(0x1A0A00), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x884400), hex(0x0F0500), CGPoint(x: 0, y: 0.8), CGPoint(x: 1, y: 0.2)),
            ]),
            // 10. Electric — blue/cyan/dark purple
            makeDarkGrainy(name: "Electric", layers: [
                (hex(0x1155CC), hex(0x0A0A22), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
                (hex(0x0099AA), hex(0x050D1A), CGPoint(x: 1, y: 0.8), CGPoint(x: 0, y: 0.2)),
            ]),
            // 11. Mystic — indigo/violet/dark teal
            makeDarkGrainy(name: "Mystic", layers: [
                (hex(0x3322AA), hex(0x0A0522), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)),
                (hex(0x551A77), hex(0x0A1A1A), CGPoint(x: 0.8, y: 0.5), CGPoint(x: 0.2, y: 0.5)),
            ]),
            // 12. Copper — dark orange/brown/black
            makeDarkGrainy(name: "Copper", layers: [
                (hex(0x884422), hex(0x0F0500), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x663311), hex(0x0A0500), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
            ]),
            // 13. Arctic — steel blue/silver-gray/dark
            makeDarkGrainy(name: "Arctic", layers: [
                (hex(0x4477AA), hex(0x0A1122), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x556677), hex(0x0F1520), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            ]),
            // 14. Sakura — mauve/dusty pink/dark navy
            makeDarkGrainy(name: "Sakura", layers: [
                (hex(0x774466), hex(0x0A0510), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x995577), hex(0x0A0A22), CGPoint(x: 0, y: 0.8), CGPoint(x: 1, y: 0.2)),
            ]),
            // 15. Jade — emerald/gold/dark
            makeDarkGrainy(name: "Jade", layers: [
                (hex(0x116644), hex(0x020A05), CGPoint(x: 0.3, y: 1), CGPoint(x: 0.7, y: 0)),
                (hex(0x998822), hex(0x0A0A00), CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.2, y: 0.3)),
            ]),
            // 16. Storm — dark gray/blue/purple
            makeDarkGrainy(name: "Storm", layers: [
                (hex(0x333344), hex(0x0A0A12), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (hex(0x2A2A55), hex(0x0F0F1A), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
            ]),
        ]
    }()

    static func hex(_ value: UInt32) -> CIColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return CIColor(red: r, green: g, blue: b)
    }

    private typealias GradientLayer = (CIColor, CIColor, CGPoint, CGPoint)

    private static func makeDarkGrainy(name: String, layers: [GradientLayer]) -> BundledBackground {
        let thumb = renderThumbnail { size in
            compositeGrainy(layers: layers, size: size)
        }
        return BundledBackground(name: name, thumbnail: thumb) { size in
            compositeGrainy(layers: layers, size: size)
        }
    }

    private static func compositeGrainy(layers: [GradientLayer], size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)

        // Start with first gradient layer as base
        guard let first = layers.first else {
            return CIImage(color: .black).cropped(to: rect)
        }
        var result = makeGradient(first, size: size)

        // Composite additional gradient layers using screen blend
        for i in 1..<layers.count {
            let layer = makeGradient(layers[i], size: size)
            if let blend = CIFilter(name: "CIScreenBlendMode") {
                blend.setValue(result, forKey: kCIInputImageKey)
                blend.setValue(layer, forKey: kCIInputBackgroundImageKey)
                if let output = blend.outputImage {
                    result = output.cropped(to: rect)
                }
            }
        }

        // Add film grain noise overlay at ~5% opacity
        if let noise = CIFilter(name: "CIRandomGenerator"),
           let noiseImage = noise.outputImage {
            let cropped = noiseImage.cropped(to: rect)
            // Reduce noise opacity by darkening it
            if let darken = CIFilter(name: "CIColorMatrix") {
                darken.setValue(cropped, forKey: kCIInputImageKey)
                darken.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                darken.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                darken.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                darken.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.05), forKey: "inputAVector")
                darken.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
                if let faintNoise = darken.outputImage?.cropped(to: rect),
                   let composite = CIFilter(name: "CISourceOverCompositing") {
                    composite.setValue(faintNoise, forKey: kCIInputImageKey)
                    composite.setValue(result, forKey: kCIInputBackgroundImageKey)
                    if let output = composite.outputImage {
                        result = output.cropped(to: rect)
                    }
                }
            }
        }

        return result
    }

    private static func makeGradient(_ layer: GradientLayer, size: CGSize) -> CIImage {
        let (color0, color1, start, end) = layer
        let p0 = CGPoint(x: start.x * size.width, y: start.y * size.height)
        let p1 = CGPoint(x: end.x * size.width, y: end.y * size.height)
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: color0).cropped(to: CGRect(origin: .zero, size: size))
        }
        filter.setValue(CIVector(cgPoint: p0), forKey: "inputPoint0")
        filter.setValue(CIVector(cgPoint: p1), forKey: "inputPoint1")
        filter.setValue(color0, forKey: "inputColor0")
        filter.setValue(color1, forKey: "inputColor1")
        return (filter.outputImage ?? CIImage()).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func renderThumbnail(generator: (CGSize) -> CIImage) -> NSImage {
        let size = CGSize(width: 440, height: 296)
        let ciImage = generator(size)
        let ctx = CIContext(options: nil)
        guard let cgImage = ctx.createCGImage(ciImage, from: CGRect(origin: .zero, size: size)) else {
            return NSImage(size: NSSize(width: size.width, height: size.height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height))
    }
}

// MARK: - Bookmark Store

final class BackgroundImageBookmarkStore {
    private static let key = "selfieBackgroundImageBookmarks"

    static func loadBookmarks() -> [Data] {
        return UserDefaults.standard.array(forKey: key) as? [Data] ?? []
    }

    static func addBookmark(_ bookmark: Data) {
        var bookmarks = loadBookmarks()
        // Avoid duplicates
        if !bookmarks.contains(bookmark) {
            bookmarks.append(bookmark)
            UserDefaults.standard.set(bookmarks, forKey: key)
        }
    }

    static func removeBookmark(at index: Int) {
        var bookmarks = loadBookmarks()
        guard index >= 0, index < bookmarks.count else { return }
        bookmarks.remove(at: index)
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    static func thumbnailForBookmark(_ bookmark: Data) -> NSImage? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let image = NSImage(contentsOf: url) else { return nil }
        // Scale to thumbnail size
        let thumbSize = NSSize(width: 110, height: 74)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }
}

// MARK: - Background Thumbnail View

final class BackgroundThumbnailView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var isSelectedTile: Bool = false {
        didSet { updateSelectionAppearance() }
    }

    private let imageLayer = CALayer()
    private let checkmarkLayer = CALayer()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(image: NSImage, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        imageLayer.frame = bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = image
        layer?.addSublayer(imageLayer)

        // Checkmark overlay (hidden by default)
        let checkSize: CGFloat = 20
        checkmarkLayer.frame = CGRect(x: bounds.width - checkSize - 4, y: 4,
                                       width: checkSize, height: checkSize)
        checkmarkLayer.cornerRadius = checkSize / 2
        checkmarkLayer.backgroundColor = NSColor.systemBlue.cgColor
        checkmarkLayer.isHidden = true
        layer?.addSublayer(checkmarkLayer)

        // Render checkmark SF Symbol into the layer
        if let checkImage = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            if let configured = checkImage.withSymbolConfiguration(config) {
                let imgSize = NSSize(width: checkSize, height: checkSize)
                let rendered = NSImage(size: imgSize)
                rendered.lockFocus()
                NSColor.white.set()
                configured.draw(in: NSRect(x: 3, y: 3, width: 14, height: 14),
                                from: .zero, operation: .sourceOver, fraction: 1.0)
                rendered.unlockFocus()
                checkmarkLayer.contents = rendered
                checkmarkLayer.contentsGravity = .resizeAspect
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.03, y: 1.03))
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.layer?.setAffineTransform(.identity)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    private func updateSelectionAppearance() {
        checkmarkLayer.isHidden = !isSelectedTile
        if isSelectedTile {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.systemBlue.cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        let checkSize: CGFloat = 20
        checkmarkLayer.frame = CGRect(x: bounds.width - checkSize - 4, y: 4,
                                       width: checkSize, height: checkSize)
    }
}

// MARK: - Add Tile View (+ button)

final class AddTileView: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Draw "+" symbol
        let plusColor = NSColor(white: 0.5, alpha: 1.0)
        ctx.setStrokeColor(plusColor.cgColor)
        ctx.setLineWidth(2.0)
        let midX = bounds.midX
        let midY = bounds.midY
        let armLen: CGFloat = 12
        ctx.move(to: CGPoint(x: midX - armLen, y: midY))
        ctx.addLine(to: CGPoint(x: midX + armLen, y: midY))
        ctx.move(to: CGPoint(x: midX, y: midY - armLen))
        ctx.addLine(to: CGPoint(x: midX, y: midY + armLen))
        ctx.strokePath()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 0.24, alpha: 1.0).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1.0).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Background Image Picker Window

final class BackgroundImagePickerWindow: NSWindow {
    var onBackgroundSelected: ((VirtualBackgroundMode, Data?, Int?) -> Void)?
    var onPreviewBackground: ((VirtualBackgroundMode, Data?, Int?) -> Void)?
    var onCancelled: ((VirtualBackgroundMode, Data?, Int?) -> Void)?

    private var selectedBundledIndex: Int? = nil
    private var selectedBookmark: Data? = nil
    private var originalMode: VirtualBackgroundMode = .none
    private var originalBundledIndex: Int? = nil
    private var originalBookmark: Data? = nil
    private var thumbnailViews: [BackgroundThumbnailView] = []
    private var userThumbnailViews: [BackgroundThumbnailView] = []
    private var userGridContainer: NSView!
    private let contentBox = NSView()

    // Layout constants
    private static let winWidth: CGFloat = 540
    private static let pad: CGFloat = 20
    private static let tileW: CGFloat = 110
    private static let tileH: CGFloat = 74
    private static let spacing: CGFloat = 8
    private static let columns: Int = 4
    private static let bottomBarH: CGFloat = 52

    private static func userGridRows(imageCount: Int) -> Int {
        let totalTiles = imageCount + 1  // +1 for the "+" button
        return max(1, (totalTiles + columns - 1) / columns)
    }

    private static func calcWindowHeight(userImageCount: Int) -> CGFloat {
        let titleAreaH: CGFloat = 44
        let bgHeaderH: CGFloat = 26
        let bgGridH = CGFloat(4) * tileH + CGFloat(3) * spacing
        let gapAfterBg: CGFloat = 20
        let userHeaderH: CGFloat = 26
        let userRows = CGFloat(userGridRows(imageCount: userImageCount))
        let userGridH = userRows * tileH + (userRows - 1) * spacing
        let gapAfterUser: CGFloat = 16
        let dividerH: CGFloat = 1
        return titleAreaH + bgHeaderH + bgGridH + gapAfterBg + userHeaderH + userGridH + gapAfterUser + dividerH + bottomBarH
    }

    init(currentMode: VirtualBackgroundMode, currentBundledIndex: Int?, currentBookmark: Data?) {
        self.originalMode = currentMode
        self.originalBundledIndex = currentBundledIndex
        self.originalBookmark = currentBookmark

        if currentMode == .customImage {
            self.selectedBundledIndex = currentBundledIndex
            self.selectedBookmark = currentBookmark
        }

        let userCount = BackgroundImageBookmarkStore.loadBookmarks().count
        let winHeight = Self.calcWindowHeight(userImageCount: userCount)

        let frame = NSRect(x: 0, y: 0, width: Self.winWidth, height: winHeight)
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.isMovableByWindowBackground = true

        setupContentView(currentMode: currentMode)
        self.center()
    }

    private func setupContentView(currentMode: VirtualBackgroundMode) {
        let boxWidth = self.contentView!.bounds.width
        let boxHeight = self.contentView!.bounds.height
        let pad = Self.pad
        let tileW = Self.tileW
        let tileH = Self.tileH
        let spacing = Self.spacing
        let columns = Self.columns
        let bottomBarH = Self.bottomBarH

        contentBox.frame = self.contentView!.bounds
        contentBox.autoresizingMask = [.width, .height]
        contentBox.wantsLayer = true
        contentBox.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0).cgColor
        contentBox.layer?.cornerRadius = 14
        contentBox.layer?.masksToBounds = true
        self.contentView?.addSubview(contentBox)

        // ── Bottom bar (pinned to bottom) ──
        let btnHeight: CGFloat = 28
        let btnWidth: CGFloat = 80

        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: boxWidth, height: bottomBarH))
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0).cgColor
        contentBox.addSubview(bottomBar)

        let divider = NSView(frame: NSRect(x: 0, y: bottomBarH, width: boxWidth, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1.0).cgColor
        contentBox.addSubview(divider)

        let btnY = (bottomBarH - btnHeight) / 2

        let cancelBtn = NSButton(frame: NSRect(x: pad, y: btnY, width: btnWidth, height: btnHeight))
        cancelBtn.title = "Cancel"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelPicker)
        cancelBtn.appearance = NSAppearance(named: .darkAqua)
        bottomBar.addSubview(cancelBtn)

        let saveBtn = NSButton(frame: NSRect(x: boxWidth - btnWidth - pad, y: btnY, width: btnWidth, height: btnHeight))
        saveBtn.title = "Save"
        saveBtn.bezelStyle = .rounded
        saveBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(savePicker)
        saveBtn.contentTintColor = .white
        saveBtn.appearance = NSAppearance(named: .darkAqua)
        if let cell = saveBtn.cell as? NSButtonCell {
            cell.backgroundColor = NSColor.systemBlue
        }
        bottomBar.addSubview(saveBtn)

        // ── Content area (top-down) ──
        var y = boxHeight

        // Title
        y -= 16
        y -= 22
        let titleLabel = NSTextField(labelWithString: "Choose Background")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: pad, y: y, width: 300, height: 22)
        contentBox.addSubview(titleLabel)

        let closeBtn = NSButton(frame: NSRect(x: boxWidth - pad - 24, y: y - 1, width: 24, height: 24))
        closeBtn.bezelStyle = .regularSquare
        closeBtn.isBordered = false
        closeBtn.title = ""
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            closeBtn.image = img.withSymbolConfiguration(config)
            closeBtn.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
        }
        closeBtn.target = self
        closeBtn.action = #selector(cancelPicker)
        contentBox.addSubview(closeBtn)

        // "BACKGROUNDS" header
        y -= 6
        y -= 16
        let bgHeader = NSTextField(labelWithString: "BACKGROUNDS")
        bgHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        bgHeader.textColor = NSColor(white: 0.40, alpha: 1.0)
        bgHeader.frame = NSRect(x: pad, y: y, width: 200, height: 14)
        contentBox.addSubview(bgHeader)
        y -= 10

        // 4x4 bundled gradient grid
        let gridWidth = CGFloat(columns) * tileW + CGFloat(columns - 1) * spacing
        let sideMargin = floor((boxWidth - gridWidth) / 2)

        for (i, bg) in BundledBackgroundGenerator.backgrounds.enumerated() {
            let col = i % columns
            let row = i / columns
            let tileX = sideMargin + CGFloat(col) * (tileW + spacing)
            let tileY = y - CGFloat(row + 1) * (tileH + spacing) + spacing
            let tile = BackgroundThumbnailView(image: bg.thumbnail,
                                                frame: NSRect(x: tileX, y: tileY, width: tileW, height: tileH))
            tile.isSelectedTile = (currentMode == .customImage && selectedBundledIndex == i)
            let index = i
            tile.onClick = { [weak self] in
                self?.selectBundled(index: index)
            }
            tile.onDoubleClick = { [weak self] in
                self?.selectBundled(index: index)
                self?.savePicker()
            }
            contentBox.addSubview(tile)
            thumbnailViews.append(tile)
        }

        let bgGridRows = (BundledBackgroundGenerator.backgrounds.count + columns - 1) / columns
        y -= CGFloat(bgGridRows) * (tileH + spacing)

        // Gap
        y -= 12

        // "YOUR IMAGES" header
        y -= 16
        let userHeader = NSTextField(labelWithString: "YOUR IMAGES")
        userHeader.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        userHeader.textColor = NSColor(white: 0.40, alpha: 1.0)
        userHeader.frame = NSRect(x: pad, y: y, width: 200, height: 14)
        contentBox.addSubview(userHeader)
        y -= 10

        // User images grid container (placed from here down to bottom bar)
        userGridContainer = NSView(frame: NSRect(x: 0, y: bottomBarH + 1, width: boxWidth, height: y - bottomBarH - 1))
        userGridContainer.wantsLayer = false
        contentBox.addSubview(userGridContainer)

        rebuildUserGrid(currentMode: currentMode)
    }

    private func rebuildUserGrid(currentMode: VirtualBackgroundMode) {
        userGridContainer.subviews.forEach { $0.removeFromSuperview() }
        userThumbnailViews.removeAll()

        let tileW = Self.tileW
        let tileH = Self.tileH
        let spacing = Self.spacing
        let columns = Self.columns
        let boxWidth = contentBox.bounds.width
        let gridWidth = CGFloat(columns) * tileW + CGFloat(columns - 1) * spacing
        let sideMargin = floor((boxWidth - gridWidth) / 2)

        let bookmarks = BackgroundImageBookmarkStore.loadBookmarks()
        var allItems: [(view: NSView, index: Int)] = []

        // Create tiles for each bookmark
        for (i, bookmark) in bookmarks.enumerated() {
            if let thumb = BackgroundImageBookmarkStore.thumbnailForBookmark(bookmark) {
                let tile = BackgroundThumbnailView(image: thumb,
                                                    frame: NSRect(x: 0, y: 0, width: tileW, height: tileH))
                tile.isSelectedTile = (currentMode == .customImage && selectedBundledIndex == nil && selectedBookmark == bookmark)
                let bm = bookmark
                tile.onClick = { [weak self] in
                    self?.selectUserImage(bookmark: bm)
                }
                tile.onDoubleClick = { [weak self] in
                    self?.selectUserImage(bookmark: bm)
                    self?.savePicker()
                }
                userThumbnailViews.append(tile)
                allItems.append((tile, allItems.count))
            }
        }

        // Add "+" tile
        let addTile = AddTileView(frame: NSRect(x: 0, y: 0, width: tileW, height: tileH))
        addTile.onClick = { [weak self] in
            self?.addUserImage()
        }
        allItems.append((addTile, allItems.count))

        // Layout as grid (top-down within container)
        let totalRows = (allItems.count + columns - 1) / columns
        let gridHeight = CGFloat(totalRows) * tileH + CGFloat(max(0, totalRows - 1)) * spacing
        let containerHeight = userGridContainer.bounds.height

        for (i, item) in allItems.enumerated() {
            let col = i % columns
            let row = i / columns
            let tileX = sideMargin + CGFloat(col) * (tileW + spacing)
            let tileY = containerHeight - CGFloat(row + 1) * (tileH + spacing) + spacing
            item.view.frame = NSRect(x: tileX, y: tileY, width: tileW, height: tileH)
            userGridContainer.addSubview(item.view)
        }
    }

    private func resizeForUserImages() {
        let userCount = BackgroundImageBookmarkStore.loadBookmarks().count
        let newHeight = Self.calcWindowHeight(userImageCount: userCount)
        let oldFrame = self.frame
        // Grow/shrink from top (keep top-left pinned)
        let newFrame = NSRect(x: oldFrame.origin.x,
                              y: oldFrame.origin.y + oldFrame.height - newHeight,
                              width: oldFrame.width,
                              height: newHeight)
        self.setFrame(newFrame, display: false)
        contentBox.frame = self.contentView!.bounds

        // Rebuild entire content
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        thumbnailViews.removeAll()
        userThumbnailViews.removeAll()

        let mode: VirtualBackgroundMode = (selectedBundledIndex != nil || selectedBookmark != nil) ? .customImage : originalMode
        setupContentView(currentMode: mode)
    }

    private func selectBundled(index: Int) {
        selectedBundledIndex = index
        selectedBookmark = nil
        for (i, tile) in thumbnailViews.enumerated() {
            tile.isSelectedTile = (i == index)
        }
        for tile in userThumbnailViews {
            tile.isSelectedTile = false
        }
        onPreviewBackground?(.customImage, nil, index)
    }

    private func selectUserImage(bookmark: Data) {
        selectedBundledIndex = nil
        selectedBookmark = bookmark
        for tile in thumbnailViews {
            tile.isSelectedTile = false
        }
        let bookmarks = BackgroundImageBookmarkStore.loadBookmarks()
        for (i, tile) in userThumbnailViews.enumerated() {
            if i < bookmarks.count {
                tile.isSelectedTile = (bookmarks[i] == bookmark)
            }
        }
        onPreviewBackground?(.customImage, bookmark, nil)
    }

    private func addUserImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a background image"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            BackgroundImageBookmarkStore.addBookmark(bookmark)
            selectedBundledIndex = nil
            selectedBookmark = bookmark
            resizeForUserImages()
            // Re-apply selection after rebuild
            selectUserImage(bookmark: bookmark)
        } catch {
            print("BackgroundImagePicker: Failed to create bookmark: \(error)")
        }
    }

    @objc private func savePicker() {
        if let index = selectedBundledIndex {
            onBackgroundSelected?(.customImage, nil, index)
        } else if let bookmark = selectedBookmark {
            onBackgroundSelected?(.customImage, bookmark, nil)
        }
        self.orderOut(nil)
    }

    @objc private func cancelPicker() {
        onCancelled?(originalMode, originalBookmark, originalBundledIndex)
        self.orderOut(nil)
    }
}
