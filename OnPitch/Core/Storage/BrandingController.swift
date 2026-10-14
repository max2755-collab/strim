import Foundation
import UIKit

/// Sponsor / league logo burned into the corner of the stream.
@MainActor
final class BrandingController: ObservableObject {
    struct Settings: Codable, Equatable {
        var isEnabled = true
        var position: ScoreboardPosition = .topRight
        var size: LogoSize = .medium
        /// 0.2 … 1
        var opacity: Double = 0.9
    }

    enum LogoSize: String, Codable, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        /// Logo height on the 16:9 canvas.
        var height: CGFloat {
            switch self {
            case .small: return 48
            case .medium: return 72
            case .large: return 104
            }
        }

        var title: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            }
        }
    }

    @Published private(set) var logo: UIImage?
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            pushToStream()
        }
    }

    private weak var engine: StreamEngine?
    private let fileURL: URL
    private static let settingsKey = "onpitch.branding.settings"
    /// Stored logo is capped to this many pixels on the long side.
    private static let maxPixels: CGFloat = 512

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Branding", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("sponsor.png")

        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
        logo = UIImage(contentsOfFile: fileURL.path)
    }

    func attach(engine: StreamEngine) {
        self.engine = engine
        pushToStream()
    }

    /// Re-apply after the camera pipeline was rebuilt.
    func resync() {
        pushToStream()
    }

    func setLogo(_ image: UIImage?) {
        if let image {
            let scaled = Self.fit(image, maxPixels: Self.maxPixels)
            try? scaled.pngData()?.write(to: fileURL, options: .atomic)
            logo = scaled
        } else {
            try? FileManager.default.removeItem(at: fileURL)
            logo = nil
        }
        pushToStream()
    }

    private func pushToStream() {
        guard let engine else { return }
        guard settings.isEnabled, let logo, let image = renderOverlay(logo) else {
            engine.setOverlay(nil, slot: .sponsor)
            return
        }
        engine.setOverlay(OverlayImage(image: image, position: settings.position, margin: 20), slot: .sponsor)
    }

    /// Logo at the chosen height with the chosen opacity baked in.
    private func renderOverlay(_ logo: UIImage) -> CGImage? {
        guard logo.size.height > 0 else { return nil }
        let height = settings.size.height
        let width = (logo.size.width * height / logo.size.height).rounded()
        let size = CGSize(width: max(1, width), height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            logo.draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: CGFloat(settings.opacity))
        }
        return image.cgImage
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private static func fit(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixels else { return image }
        let factor = maxPixels / longest
        let target = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
