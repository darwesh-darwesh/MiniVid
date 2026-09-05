import PhotosUI
import SwiftUI
import UIKit

/// Studio tab: single-image generation (Image Lab) and a standalone image
/// resizer — small utilities sharing the same pipeline and theme.
struct StudioView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    BrandHeader()
                    ImageLabCard()
                    ResizerCard()
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CosmicBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Image Lab

private struct ImageLabCard: View {
    @Environment(AppModel.self) private var model
    @State private var prompt = ""
    @State private var steps = 15
    @State private var shareURL: URL?
    @State private var usedForVideo = false

    var body: some View {
        GlassCard(icon: "photo.artframe", title: "Image Lab") {
            if case .ready = model.modelManager.status {
                TextField("Describe a single image…", text: $prompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                HStack {
                    Text("Steps")
                        .font(.subheadline)
                    Spacer()
                    StepperPill(value: $steps, range: 2...40, step: 2)
                }

                if model.isGeneratingStill {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Theme.cyan)
                        Text(model.stillProgressText)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Button {
                        shareURL = nil
                        usedForVideo = false
                        Task { await model.generateStill(prompt: prompt, steps: steps, seed: nil) }
                    } label: {
                        Label("Generate image", systemImage: "sparkles")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !model.stillProgressText.isEmpty {
                        Text(model.stillProgressText)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                    }
                }

                if let image = model.stillImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))

                    HStack(spacing: 10) {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share PNG", systemImage: "square.and.arrow.up")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.cyan)
                        } else {
                            Button {
                                exportStill(image)
                            } label: {
                                Label("Share PNG", systemImage: "square.and.arrow.up")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.cyan)
                        }
                        Button {
                            model.inputImage = image
                            usedForVideo = true
                        } label: {
                            Label(usedForVideo ? "Ready in Create tab" : "Use for video", systemImage: "film")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(usedForVideo ? .green : Theme.cyan)
                    }
                }
            } else {
                Text("Install a model first (Create tab).")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func exportStill(_ image: CGImage) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minivid-image-\(Int(Date().timeIntervalSince1970)).png")
        try? VideoExporter.writePNG(image, to: url)
        shareURL = url
    }
}

// MARK: - Resizer

private struct ResizerCard: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var source: CGImage?
    @State private var targetSize = 512
    @State private var squareCrop = true
    @State private var shareURL: URL?

    var body: some View {
        GlassCard(icon: "aspectratio", title: "Image resizer") {
            if let source {
                Image(decorative: source, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                ChipPicker(items: [256, 384, 512, 768, 1024], label: { "\($0)" }, selection: $targetSize)

                Toggle("Square crop (center)", isOn: $squareCrop)
                    .font(.subheadline)
                    .tint(Theme.cyan)

                HStack(spacing: 10) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Label("Share result", systemImage: "square.and.arrow.up")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                    } else {
                        Button {
                            export()
                        } label: {
                            Label("Resize & export", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.violet)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Other photo", systemImage: "photo")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.cyan)
                }
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose a photo to resize", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        )
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let image = await PhotoLoader.loadCGImage(from: item) {
                    withAnimation(.spring(duration: 0.3)) {
                        source = image
                        shareURL = nil
                    }
                }
            }
        }
        .onChange(of: targetSize) { _, _ in shareURL = nil }
        .onChange(of: squareCrop) { _, _ in shareURL = nil }
    }

    private func export() {
        guard let source else { return }
        let resized = squareCrop
            ? VideoExporter.aspectFillSquare(source, side: targetSize)
            : VideoExporter.fitLongestSide(source, to: targetSize)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minivid-resized-\(targetSize).png")
        do {
            try VideoExporter.writePNG(resized, to: url)
            shareURL = url
        } catch {
            shareURL = nil
        }
    }
}
