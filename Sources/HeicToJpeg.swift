import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private struct FileSignature: Equatable {
    let size: UInt64
    let modified: Date
}

private struct FolderSnapshot {
    let paths: Set<URL>
    let signatures: [URL: FileSignature]
}

enum ImageSizePreset: String, CaseIterable, Identifiable {
    case original, large, medium, small

    var id: String { rawValue }

    var longestSide: Int? {
        switch self {
        case .original: return nil
        case .large: return 2560
        case .medium: return 1280
        case .small: return 640
        }
    }

    var label: String {
        switch self {
        case .original: return "Original dimensions"
        case .large: return "Large · up to 2560 px"
        case .medium: return "Medium · up to 1280 px"
        case .small: return "Small · up to 640 px"
        }
    }
}

private struct ConversionSettings {
    let preset: ImageSizePreset
    let maximumBytes: Int?
}

private enum PhotoConverter {
    static func isHEIC(_ url: URL) -> Bool {
        ["heic", "heif"].contains(url.pathExtension.lowercased())
    }

    static func convert(_ sourceURL: URL, settings: ConversionSettings) throws -> URL {
        guard isHEIC(sourceURL) else {
            throw ConversionError.unsupportedFile
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ConversionError.cannotRead
        }

        let originalWidth = (sourceProperties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let originalHeight = (sourceProperties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard originalWidth > 0, originalHeight > 0 else { throw ConversionError.cannotRead }
        var longestSide = min(settings.preset.longestSide ?? max(originalWidth, originalHeight), max(originalWidth, originalHeight))
        var image = try decodedImage(from: source, longestSide: longestSide, originalLongestSide: max(originalWidth, originalHeight))
        var result = Data()
        var fits = false

        for _ in 0..<12 {
            for quality in [0.92, 0.80, 0.68, 0.56, 0.44, 0.32] {
                result = try encodedJPEG(image: image, sourceProperties: sourceProperties, quality: quality)
                if let maximum = settings.maximumBytes, result.count > maximum { continue }
                fits = true
                break
            }
            if fits { break }
            guard let maximum = settings.maximumBytes, longestSide > 160 else { break }
            let estimatedScale = sqrt(Double(maximum) / Double(max(result.count, 1))) * 0.92
            longestSide = max(160, Int(Double(longestSide) * min(0.85, estimatedScale)))
            image = try decodedImage(from: source, longestSide: longestSide, originalLongestSide: max(originalWidth, originalHeight))
        }
        guard fits else { throw ConversionError.cannotMeetSize }

        let fileManager = FileManager.default
        let directory = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(stem).appendingPathExtension("jpg")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension("jpg")
            suffix += 1
        }

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).jpg")
        defer { try? fileManager.removeItem(at: temporary) }
        try result.write(to: temporary)
        // A move in the same folder makes the completed JPEG appear all at once.
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func decodedImage(from source: CGImageSource, longestSide: Int, originalLongestSide: Int) throws -> CGImage {
        if longestSide >= originalLongestSide {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.cannotRead }
            return image
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: longestSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.cannotRead
        }
        return image
    }

    private static func encodedJPEG(image: CGImage, sourceProperties: [CFString: Any], quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.cannotWrite
        }
        var properties = sourceProperties
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ConversionError.cannotWrite }
        return data as Data
    }

    private enum ConversionError: LocalizedError {
        case unsupportedFile, cannotRead, cannotWrite, cannotMeetSize
        var errorDescription: String? {
            switch self {
            case .unsupportedFile: return "Choose a HEIC or HEIF photo."
            case .cannotRead: return "The photo could not be read yet."
            case .cannotWrite: return "The JPEG could not be saved."
            case .cannotMeetSize: return "The photo could not fit within the chosen file size."
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var watchEnabled = UserDefaults.standard.bool(forKey: "watchEnabled")
    @Published var folderPath = UserDefaults.standard.string(forKey: "folderPath") ?? ""
    @Published var imageSize = ImageSizePreset(rawValue: UserDefaults.standard.string(forKey: "imageSize") ?? "original") ?? .original {
        didSet { UserDefaults.standard.set(imageSize.rawValue, forKey: "imageSize") }
    }
    @Published var limitFileSize = UserDefaults.standard.bool(forKey: "limitFileSize") {
        didSet { UserDefaults.standard.set(limitFileSize, forKey: "limitFileSize") }
    }
    @Published var maximumMB = UserDefaults.standard.object(forKey: "maximumMB") == nil ? 2.0 : UserDefaults.standard.double(forKey: "maximumMB") {
        didSet { UserDefaults.standard.set(maximumMB, forKey: "maximumMB") }
    }
    @Published var isBusy = false
    @Published var latestMessage = "Choose HEIC photos or turn on folder watching."
    @Published var convertedCount = 0
    @Published var recentFiles: [URL] = []

    private var timer: Timer?
    private var observed: [URL: FileSignature] = [:]
    private var preexistingPaths: Set<URL> = []
    private var handled: [URL: FileSignature] = [:]
    private var inFlight: Set<URL> = []

    init() {
        if watchEnabled && !folderPath.isEmpty {
            startWatching()
        } else {
            watchEnabled = false
        }
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.heic, .heif]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose HEIC photos to convert to JPEG"
        if panel.runModal() == .OK { convertFiles(panel.urls) }
    }

    func convertFiles(_ urls: [URL]) {
        let photos = urls.filter(PhotoConverter.isHEIC)
        guard !photos.isEmpty else {
            latestMessage = "Drop HEIC or HEIF photos here."
            return
        }
        guard let settings = conversionSettings() else { return }
        isBusy = true
        latestMessage = "Converting \(photos.count) photo\(photos.count == 1 ? "" : "s")…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var successes: [URL] = []
            var errors: [String] = []
            for url in photos {
                do { successes.append(try PhotoConverter.convert(url, settings: settings)) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.record(successes)
                if let first = errors.first {
                    self.latestMessage = "Converted \(successes.count) of \(photos.count). \(first)"
                } else {
                    self.latestMessage = "Converted \(successes.count) photo\(successes.count == 1 ? "" : "s") to JPEG."
                }
            }
        }
    }

    func setWatching(_ enabled: Bool) {
        if enabled {
            if folderPath.isEmpty { chooseFolder() }
            guard !folderPath.isEmpty else { return }
            watchEnabled = true
            UserDefaults.standard.set(true, forKey: "watchEnabled")
            startWatching()
        } else {
            watchEnabled = false
            UserDefaults.standard.set(false, forKey: "watchEnabled")
            timer?.invalidate()
            timer = nil
            observed.removeAll()
            preexistingPaths.removeAll()
            handled.removeAll()
            latestMessage = "Folder watching is off."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where AirDrop saves photos"
        panel.directoryURL = folderPath.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            : URL(fileURLWithPath: folderPath)
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            UserDefaults.standard.set(url.path, forKey: "folderPath")
            if watchEnabled { startWatching() }
        }
    }

    private func startWatching() {
        timer?.invalidate()
        guard let snapshot = currentHEICFiles() else {
            watchEnabled = false
            UserDefaults.standard.set(false, forKey: "watchEnabled")
            latestMessage = "Cannot read this folder. Choose it again to restore access."
            return
        }
        observed = snapshot.signatures
        preexistingPaths = snapshot.paths
        handled.removeAll()
        latestMessage = "Watching \(URL(fileURLWithPath: folderPath).lastPathComponent) for new photos."
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    private func currentHEICFiles() -> FolderSnapshot? {
        guard !folderPath.isEmpty,
              let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folderPath), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        var result: [URL: FileSignature] = [:]
        let paths = Set(urls.filter(PhotoConverter.isHEIC))
        for url in paths {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            result[url] = FileSignature(size: UInt64(size), modified: modified)
        }
        return FolderSnapshot(paths: paths, signatures: result)
    }

    private func scan() {
        guard watchEnabled else { return }
        guard let settings = conversionSettings() else { return }
        guard let snapshot = currentHEICFiles() else {
            latestMessage = "Cannot read the watched folder. Choose it again to restore access."
            return
        }
        let files = snapshot.signatures
        for (url, signature) in files {
            let stable = observed[url] == signature && Date().timeIntervalSince(signature.modified) >= 3
            if stable && !preexistingPaths.contains(url) && handled[url] != signature && !inFlight.contains(url) {
                inFlight.insert(url)
                handled[url] = signature
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let result = Result { try PhotoConverter.convert(url, settings: settings) }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.inFlight.remove(url)
                        switch result {
                        case .success(let output):
                            self.record([output])
                            self.latestMessage = "Converted \(url.lastPathComponent)."
                        case .failure(let error):
                            self.latestMessage = "Could not convert \(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        observed = files
        handled = handled.filter { files[$0.key] == $0.value }
    }

    private func conversionSettings() -> ConversionSettings? {
        if limitFileSize && (!maximumMB.isFinite || maximumMB < 0.1 || maximumMB > 100) {
            latestMessage = "Enter a maximum JPEG size between 0.1 and 100 MB."
            return nil
        }
        return ConversionSettings(preset: imageSize, maximumBytes: limitFileSize ? Int(maximumMB * 1_000_000) : nil)
    }

    private func record(_ urls: [URL]) {
        convertedCount += urls.count
        recentFiles = Array((urls.reversed() + recentFiles).prefix(5))
    }
}

private enum StudioPalette {
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.27)
    static let coralDeep = Color(red: 0.82, green: 0.29, blue: 0.19)
    static let cream = Color(red: 1.0, green: 0.97, blue: 0.91)
    static let navy = Color(red: 0.09, green: 0.18, blue: 0.23)
    static let teal = Color(red: 0.24, green: 0.72, blue: 0.65)
}

private struct BrandIcon: View {
    private static let artwork: NSImage? = {
        guard let path = Bundle.main.path(forResource: "BrandMark", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 13).fill(StudioPalette.coral)
                    .overlay(Image(systemName: "arrow.right").foregroundStyle(.white))
            }
        }
        .frame(width: 54, height: 54)
        .accessibilityHidden(true)
    }
}

private struct HeroArtwork: View {
    var body: some View {
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(StudioPalette.navy)
                    .frame(width: 105, height: 130)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(16), spacing: 6), count: 3), spacing: 6) {
                    ForEach(0..<9, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(StudioPalette.cream.opacity(index < 5 ? 0.95 : 0.55))
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: 60)
            }
            .rotationEffect(.degrees(-12))
            .offset(x: -28, y: 11)

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(StudioPalette.cream)
                    .frame(width: 108, height: 134)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.89, green: 0.92, blue: 0.87))
                    .frame(width: 86, height: 110)
                    .overlay {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.98, green: 0.65, blue: 0.31))
                                .frame(width: 27, height: 27)
                                .offset(x: 22, y: -28)
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 95))
                                path.addLine(to: CGPoint(x: 32, y: 40))
                                path.addLine(to: CGPoint(x: 54, y: 70))
                                path.addLine(to: CGPoint(x: 72, y: 54))
                                path.addLine(to: CGPoint(x: 86, y: 79))
                                path.addLine(to: CGPoint(x: 86, y: 110))
                                path.addLine(to: CGPoint(x: 0, y: 110))
                            }
                            .fill(Color(red: 0.22, green: 0.52, blue: 0.52))
                        }
                        .frame(width: 86, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
            }
            .rotationEffect(.degrees(9))
            .offset(x: 30, y: -8)
            .shadow(color: StudioPalette.navy.opacity(0.23), radius: 11, y: 9)
        }
        .frame(width: 180, height: 175)
        .accessibilityHidden(true)
    }
}

struct DropArea: View {
    let onFiles: ([URL]) -> Void
    let onChoose: () -> Void
    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 25)
                .fill(LinearGradient(colors: [StudioPalette.coral, StudioPalette.coralDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 285, height: 285)
                .offset(x: 430, y: -112)
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: 330, height: 330)
                .offset(x: 395, y: 102)
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Drag and drop")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioPalette.cream.opacity(0.78))
                    Text("HEIC in.\nJPEG out.")
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.5)
                        .lineSpacing(-2)
                        .foregroundStyle(StudioPalette.cream)
                    Text("Drop photos here, or pick them from your Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioPalette.cream.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onChoose) {
                        HStack(spacing: 9) {
                            Text("Choose photos")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioPalette.navy)
                        .padding(.horizontal, 17)
                        .frame(height: 37)
                        .background(StudioPalette.cream, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityHint("Choose HEIC or HEIF photos to convert")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HeroArtwork()
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 22)
        }
        .frame(height: 224)
        .clipShape(RoundedRectangle(cornerRadius: 25))
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(Color.white.opacity(isTargeted ? 0.95 : (isHovered ? 0.3 : 0.1)), lineWidth: isTargeted ? 2 : 1)
        }
        .shadow(color: StudioPalette.coralDeep.opacity(0.18), radius: 20, y: 9)
        .onHover { isHovered = $0 }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    if let url = object {
                        lock.lock(); urls.append(url); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { onFiles(urls) }
            return true
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var displayedFolderPath: String {
        guard !model.folderPath.isEmpty else { return "Choose an AirDrop folder" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if model.folderPath.hasPrefix(home + "/") {
            return "~" + model.folderPath.dropFirst(home.count)
        }
        return model.folderPath
    }
    private var background: Color { dark ? Color(red: 0.07, green: 0.11, blue: 0.14) : Color(red: 0.97, green: 0.96, blue: 0.94) }
    private var surface: Color { dark ? Color(red: 0.12, green: 0.17, blue: 0.20) : Color.white }
    private var primary: Color { dark ? StudioPalette.cream : StudioPalette.navy }
    private var muted: Color { dark ? Color(red: 0.67, green: 0.74, blue: 0.75) : Color(red: 0.42, green: 0.48, blue: 0.50) }
    private var hairline: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BrandIcon()
                VStack(alignment: .leading, spacing: 3) {
                    Text("HEIC to JPEG")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(primary)
                    Text("Your iPhone photos, ready to share.")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                }
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.watchEnabled ? StudioPalette.teal : muted.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(model.watchEnabled ? "Watching" : "Paused")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(model.watchEnabled ? StudioPalette.teal : muted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(model.watchEnabled ? StudioPalette.teal.opacity(0.12) : muted.opacity(0.10), in: Capsule())
            }

            DropArea(onFiles: model.convertFiles, onChoose: model.choosePhotos)

            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Output settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primary)
                }
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Image size").font(.system(size: 14, weight: .semibold)).foregroundStyle(primary)
                        Text("Scale the longest edge").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Picker("Image size", selection: $model.imageSize) {
                        ForEach(ImageSizePreset.allCases) { preset in Text(preset.label).tag(preset) }
                    }
                    .labelsHidden()
                    .frame(width: 225)
                }
                Rectangle().fill(hairline).frame(height: 1)
                HStack(spacing: 12) {
                    Toggle("Limit JPEG size", isOn: $model.limitFileSize)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primary)
                    Spacer()
                    TextField("MB", value: $model.maximumMB, format: .number)
                        .frame(width: 62)
                        .multilineTextAlignment(.trailing)
                        .disabled(!model.limitFileSize)
                    Text("MB").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                }
                Text("A file size limit may lower quality or dimensions. Applies to manual and automatic conversions.")
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(19)
            .background(surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Automatic conversion")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primary)
                }
                Rectangle().fill(hairline).frame(height: 1)
                Toggle("Convert new arrivals automatically", isOn: Binding(get: { model.watchEnabled }, set: { model.setWatching($0) }))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primary)
                    .tint(StudioPalette.teal)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(muted)
                    Text(displayedFolderPath)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(muted)
                    Spacer(minLength: 8)
                    Button("Change…") { model.chooseFolder() }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(StudioPalette.coral)
                }
            }
            .padding(19)
            .background(surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(hairline, lineWidth: 1))

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: model.watchEnabled ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(model.watchEnabled ? StudioPalette.teal : muted)
                Text(model.latestMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 3)

            if !model.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Recent JPEGs")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted)
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                Text(url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(primary)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(27)
        .frame(width: 610)
        .background(background)
        .tint(StudioPalette.coral)
    }
}

@main
struct HeicToJpegApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView(model: model)
        }
        .windowResizability(.contentSize)
        MenuBarExtra("HEIC to JPEG", systemImage: "photo") {
            Text(model.watchEnabled ? "Watching for new HEIC photos" : "Folder watching is off")
            Button("Open HEIC to JPEG") { openWindow(id: "main") }
            Button("Choose photos…") { model.choosePhotos() }
            Divider()
            Button(model.watchEnabled ? "Stop watching" : "Start watching") { model.setWatching(!model.watchEnabled) }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
