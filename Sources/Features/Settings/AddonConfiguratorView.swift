import SwiftUI
import CoreImage.CIFilterBuiltins

/// Addon configuration hand-off.
///
/// Stremio addons that advertise `behaviorHints.configurable` expose a `/configure` web page.
/// tvOS ships no browser and no WKWebView, so the page cannot be opened on the device. What
/// works is finishing the job on a phone: the URL is shown as a QR code, and the configured
/// manifest URL comes back through the normal "add addon" field.
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

                    Text("This addon is configured on its own web page. Apple TV has no browser, so scan the code with a phone, finish the setup there, then paste the configured manifest URL below.")
                        .nuvioText(NuvioTextStyles.bodyCompact)
                        .foregroundStyle(colors.textSecondary)
                        .frame(maxWidth: dp(760), alignment: .leading)

                    HStack(alignment: .top, spacing: NuvioTheme.spacing.xxl) {
                        qrCode

                        VStack(alignment: .leading, spacing: NuvioTheme.spacing.md) {
                            Text("Or type it in manually")
                                .nuvioText(NuvioTextStyles.cardTitle)
                                .foregroundStyle(colors.textPrimary)
                            Text(configureUrl)
                                .nuvioText(NuvioTextStyles.metadata)
                                .foregroundStyle(colors.secondary)
                                .frame(maxWidth: dp(520), alignment: .leading)
                        }
                    }

                    SettingsCard(
                        title: "Configured manifest URL",
                        footnote: "The configure page ends with an Install button — copy the URL it points at."
                    ) {
                        SettingsTextFieldRow(
                            title: "Manifest URL",
                            placeholder: "https://…/manifest.json",
                            text: $configuredUrl,
                            trailingAction: (label: isInstalling ? "Installing…" : "Install", action: install)
                        )
                    }

                    if let status {
                        Text(status)
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(status.hasPrefix("Installed") ? colors.success : colors.error)
                    }

                    Button(action: { dismiss() }) {
                        Text("Done")
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
enum QRCodeRenderer {
    static func image(for string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction keeps the code readable when a TV panel softens the edges.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
