import SwiftUI
import CoreImage.CIFilterBuiltins

/// Addon configuration hand-off.
///
/// Stremio addons that advertise `behaviorHints.configurable` expose a `/configure` web page.
/// tvOS ships no browser and no WKWebView, so the page cannot be opened on the device. What
/// works is finishing the job on a phone: the URL is shown as a QR code, and the configured
/// manifest URL comes back through the normal L10n.text("settings.addon_config.add_addon", fallback: "add addon") field.
struct AddonConfiguratorView: View {
    @Environment(\.nuvioColors) private var colors
    @Environment(AddonStore.self) private var addons
    @Environment(\.dismiss) private var dismiss

    let addon: Addon

    @State private var configuredUrl = ""
    @State private var status: String?
    @State private var isInstalling = false

    private var configureUrl: String {
        // `/configure` sits next to `/manifest.json` on every configurable addon.
        StremioURL.canonicalize(addon.baseUrl) + "/configure"
    }

    var body: some View {
        NuvioScreenBackground {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: NuvioTheme.components.settings.rowGap) {
                    Text("Configure \(addon.displayName)")
                        .nuvioText(NuvioTextStyles.display)
                        .foregroundStyle(colors.textPrimary)

                    Text(L10n.text("settings.addon_config.footnote", fallback: "This addon is configured on its own web page. Apple TV has no browser, so scan the code with a phone, finish the setup there, then paste the configured manifest URL below."))
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: dp(760), alignment: .leading)

                    HStack(alignment: .top, spacing: NuvioTheme.spacing.xxl) {
                        qrCode

                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                            Text(L10n.text("settings.addon_config.or_manual", fallback: "Or type it in manually"))
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                            Text(configureUrl)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.secondary)
                                .frame(maxWidth: dp(520), alignment: .leading)
                        }
                    }

                    SettingsCard(
                        title: L10n.text("settings.addon_config.manifest_url", fallback: "Configured manifest URL"),
                        footnote: L10n.text("settings.addon_config.manifest_url_sub", fallback: "The configure page ends with an Install button — copy the URL it points at.")
                    ) {
                        SettingsTextFieldRow(
                            title: L10n.text("settings.addon_config.manifest_hint", fallback: "Manifest URL"),
                            placeholder: "https://…/manifest.json",
                            text: $configuredUrl,
                            trailingAction: (label: isInstalling ? L10n.text("settings.addon_config.installing", fallback: "Installing…") : L10n.text("settings.addon_config.install", fallback: "Install"), action: install)
                        )
                    }

                    if let status {
                        Text(status)
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(status.hasPrefix(L10n.text("settings.addon_config.installed", fallback: "Installed")) ? colors.success : colors.error)
                    }

                    Button(action: { dismiss() }) {
                        Text(L10n.text("settings.addon_config.done", fallback: "Done"))
                            .nuvioText(NuvioTextStyles.button)
                            .padding(.horizontal, NuvioTheme.spacing.xl)
                            .frame(height: NuvioTheme.components.buttonHeight)
                    }
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .primary))
                }
                .padding(.bottom, NuvioTheme.spacing.xxxl)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let image = QRCodeRenderer.image(for: configureUrl) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: dp(220), height: dp(220))
                .padding(NuvioTheme.spacing.md)
                .background {
                    RoundedRectangle(cornerRadius: NuvioTheme.radii.md, style: .continuous)
                        .fill(.white)
                }
        }
    }

    private func install() {
        let trimmed = configuredUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isInstalling else { return }
        isInstalling = true
        status = nil
        Task {
            defer { isInstalling = false }
            switch await addons.install(url: trimmed) {
            case .success(let installed):
                status = "Installed \(installed.displayName)."
                configuredUrl = ""
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }
}

/// Renders a QR code with Core Image. `CIQRCodeGenerator` is available on tvOS, so no bundled
/// library is needed.
///
/// Memoised, because every caller asks from a view body. The sign-in screen redraws once a second
/// for its countdown, and each redraw built a fresh `CIContext` and rendered the code again on the
/// main thread — upstream's "jank on the QR sign-in screen", which we had in the same place.
@MainActor
enum QRCodeRenderer {
    private static let context = CIContext()
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        return cache
    }()

    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let key = "\(scale)|\(string)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = render(string, scale: scale) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func render(_ string: String, scale: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction keeps the code readable when a TV panel softens the edges.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
