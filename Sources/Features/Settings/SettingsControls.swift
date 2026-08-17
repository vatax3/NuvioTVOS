import SwiftUI

// MARK: - Option picker

/// A labelled setting whose value is one of a small enum. tvOS has no good popup picker for
/// a remote, so the choices live inline as a focusable chip run — the same shape the Compose
/// settings screens use.
struct SettingsOptionRow<T: SettingsOption>: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    var systemImage: String?
    var options: [T] = Array(T.allCases)
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            HStack(spacing: NuvioTheme.spacing.lg) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: NuvioTheme.sizes.icons.md))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: NuvioTheme.sizes.icons.lg)
                }
                VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                    Text(title)
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    ForEach(options) { option in
                        NuvioChip(
                            label: option.displayName,
                            isSelected: option == selection,
                            action: { selection = option }
                        )
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

// MARK: - Multi-select

/// Multi-selection over an enum — powers the preferred/required/excluded lists.
struct SettingsMultiSelectRow<T: SettingsOption>: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    var options: [T] = Array(T.allCases)
    @Binding var selection: [T]

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(title)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    ForEach(options) { option in
                        NuvioChip(
                            label: option.displayName,
                            isSelected: selection.contains(option),
                            action: { toggle(option) }
                        )
                    }
                }
                .padding(.vertical, NuvioTheme.spacing.xs)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func toggle(_ option: T) {
        if let index = selection.firstIndex(of: option) {
            selection.remove(at: index)
        } else {
            selection.append(option)
        }
    }
}

/// Reorderable preference list — position drives ranking in the stream sorter.
struct SettingsPriorityListRow<T: SettingsOption>: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    @Binding var order: [T]

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(title)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
            }

            VStack(spacing: NuvioTheme.spacing.xs) {
                ForEach(Array(order.enumerated()), id: \.element) { index, option in
                    HStack(spacing: NuvioTheme.spacing.md) {
                        Text("\(index + 1)")
                            .nuvioText(NuvioTextStyles.metadata)
                            .foregroundStyle(colors.textTertiary)
                            .frame(width: dp(28), alignment: .leading)
                        Text(option.displayName)
                            .nuvioText(NuvioTextStyles.bodyCompact)
                            .foregroundStyle(colors.textPrimary)
                        Spacer(minLength: 0)
                        Button(action: { move(index, by: -1) }) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .semibold))
                                .frame(width: dp(40), height: dp(40))
                        }
                        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full))
                        .disabled(index == 0)
                        .opacity(index == 0 ? NuvioTheme.effects.disabledAlpha : 1)

                        Button(action: { move(index, by: 1) }) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: NuvioTheme.sizes.icons.xs, weight: .semibold))
                                .frame(width: dp(40), height: dp(40))
                        }
                        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full))
                        .disabled(index == order.count - 1)
                        .opacity(index == order.count - 1 ? NuvioTheme.effects.disabledAlpha : 1)
                    }
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, NuvioTheme.spacing.md)
                    .padding(.vertical, NuvioTheme.spacing.xs)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.radii.sm, style: .continuous)
                            .fill(colors.surface.opacity(0.5))
                    }
                }
            }
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }
}

// MARK: - Numeric stepper

struct SettingsStepperRow: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    var systemImage: String?
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            trailing: {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    stepButton("minus", enabled: value > range.lowerBound) {
                        value = max(range.lowerBound, value - step)
                    }
                    Text(format(value))
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .frame(minWidth: dp(96))
                    stepButton("plus", enabled: value < range.upperBound) {
                        value = min(range.upperBound, value + step)
                    }
                }
            },
            action: {}
        )
        .focusSection()
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                .frame(width: dp(44), height: dp(44))
                .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full))
        .disabled(!enabled)
        .opacity(enabled ? 1 : NuvioTheme.effects.disabledAlpha)
    }
}

/// Same control for fractional values (subtitle scale, audio gain).
struct SettingsDecimalStepperRow: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.1
    var format: (Double) -> String = { String(format: "%.1f", $0) }

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            trailing: {
                HStack(spacing: NuvioTheme.spacing.sm) {
                    stepButton("minus", enabled: value > range.lowerBound) {
                        value = max(range.lowerBound, value - step)
                    }
                    Text(format(value))
                        .nuvioText(NuvioTextStyles.cardTitle)
                        .foregroundStyle(colors.textPrimary)
                        .frame(minWidth: dp(96))
                    stepButton("plus", enabled: value < range.upperBound) {
                        value = min(range.upperBound, value + step)
                    }
                }
            },
            action: {}
        )
        .focusSection()
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: NuvioTheme.sizes.icons.sm, weight: .semibold))
                .frame(width: dp(44), height: dp(44))
                .contentShape(Rectangle())
        }
        .buttonStyle(NuvioRowButtonStyle(cornerRadius: NuvioTheme.radii.full))
        .disabled(!enabled)
        .opacity(enabled ? 1 : NuvioTheme.effects.disabledAlpha)
    }
}

// MARK: - Text entry

/// Secure-ish text row for API keys. tvOS shows its own full-screen keyboard on focus.
struct SettingsTextFieldRow: View {
    @Environment(\.nuvioColors) private var colors

    let title: String
    var subtitle: String?
    var placeholder: String = ""
    var masked: Bool = false
    @Binding var text: String
    var trailingAction: (label: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: NuvioTheme.spacing.sm) {
            VStack(alignment: .leading, spacing: NuvioTheme.spacing.xxs) {
                Text(title)
                    .nuvioText(NuvioTextStyles.cardTitle)
                    .foregroundStyle(colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .nuvioText(NuvioTextStyles.metadata)
                        .foregroundStyle(colors.textSecondary)
                }
            }

            HStack(spacing: NuvioTheme.spacing.md) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .nuvioText(NuvioTextStyles.bodyCompact)
                    .padding(.horizontal, NuvioTheme.spacing.lg)
                    .padding(.vertical, NuvioTheme.spacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: NuvioTheme.shapes.field, style: .continuous)
                            .fill(colors.field)
                    }

                if let trailingAction {
                    Button(action: trailingAction.action) {
                        Text(trailingAction.label)
                            .nuvioText(NuvioTextStyles.button)
                            .padding(.horizontal, NuvioTheme.spacing.xl)
                            .frame(height: NuvioTheme.components.buttonHeight)
                    }
                    .buttonStyle(NuvioPillButtonStyle(emphasis: .secondary))
                }
            }

            if masked, !text.isEmpty {
                Text("Saved · \(String(repeating: "•", count: min(text.count, 24)))")
                    .nuvioText(NuvioTypography.labelSmall)
                    .foregroundStyle(colors.textTertiary)
            }
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

// MARK: - Informational row

struct SettingsInfoRow: View {
    @Environment(\.nuvioColors) private var colors
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: NuvioTheme.spacing.lg) {
            Text(title)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(colors.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .nuvioText(NuvioTextStyles.bodyCompact)
                .foregroundStyle(tint ?? colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, NuvioTheme.spacing.lg)
        .padding(.vertical, NuvioTheme.spacing.sm)
    }
}
