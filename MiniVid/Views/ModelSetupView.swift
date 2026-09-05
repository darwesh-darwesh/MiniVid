import SwiftUI

/// Model management: shown at first launch until a model is installed, and
/// reachable at any time from the Create tab to switch, delete or download
/// models.
struct ModelSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showModelImporter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                BrandHeader()

                GlassCard(icon: "arrow.down.circle", title: "On-device models") {
                    Text("MiniVid runs entirely on-device. Download a Core ML model once (Wi-Fi recommended); generation then works fully offline.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                switch model.modelManager.status {
                case .downloading(let fraction):
                    GlassCard(icon: "antenna.radiowaves.left.and.right", title: "Downloading") {
                        ProgressView(value: fraction)
                            .tint(Theme.cyan)
                        Text("\(Int(fraction * 100)) % — keep the app in the foreground")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                case .unpacking:
                    GlassCard(icon: "shippingbox", title: "Installing") {
                        ProgressView("Unpacking model…")
                            .tint(Theme.cyan)
                    }
                case .failed(let message):
                    GlassCard(icon: "exclamationmark.triangle", title: "Error") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                    }
                    installedSection
                    downloadSection
                default:
                    installedSection
                    downloadSection
                }
            }
            .padding(16)
        }
    }

    // MARK: - Installed models

    @ViewBuilder
    private var installedSection: some View {
        if !model.modelManager.installed.isEmpty {
            GlassCard(icon: "checkmark.seal", title: "Installed — tap to switch") {
                ForEach(model.modelManager.installed) { installed in
                    HStack(spacing: 12) {
                        Image(systemName: isActive(installed) ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive(installed) ? Theme.cyan : .white.opacity(0.3))
                        Text(installed.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Button {
                            model.modelManager.delete(installed)
                        } label: {
                            Image(systemName: "trash")
                                .font(.footnote)
                                .foregroundStyle(Theme.magenta.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(
                        .white.opacity(isActive(installed) ? 0.08 : 0.03),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.modelManager.select(installed) }
                }
            }
        }
    }

    private func isActive(_ installed: ModelManager.InstalledModel) -> Bool {
        model.modelManager.activeModel == installed
    }

    // MARK: - Downloads

    @ViewBuilder
    private var downloadSection: some View {
        GlassCard(icon: "square.and.arrow.down.on.square", title: "Download") {
            ForEach(ModelManager.options) { option in
                Button {
                    Task { await model.modelManager.install(option) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        Button {
            showModelImporter = true
        } label: {
            Label("Import model (zip or folder)", systemImage: "square.and.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.cyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                )
        }
        .buttonStyle(.plain)
        .fileImporter(
            isPresented: $showModelImporter,
            allowedContentTypes: [.zip, .folder]
        ) { result in
            if case .success(let url) = result {
                Task { await model.modelManager.importModel(from: url) }
            }
        }
        Button {
            model.modelManager.refresh()
        } label: {
            Label("Re-scan Models folder", systemImage: "arrow.clockwise")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.cyan)
        }
        .buttonStyle(.plain)
        Text("Advanced: any compatible compiled Core ML Stable Diffusion folder dropped into MiniVid/Models via the Files app appears here after a re-scan.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}
