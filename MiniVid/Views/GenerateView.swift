import PhotosUI
import SwiftUI
import UIKit

struct GenerateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if case .ready = model.modelManager.status {
                    GenerationFormView()
                } else {
                    ModelSetupView()
                }
            }
            .background(CosmicBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct GenerationFormView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 14) {
                BrandHeader()
                ModelSwitcherButton()
                if model.isGenerating {
                    ProgressHeroView()
                } else {
                    PromptCard()
                    StoryboardCard()
                    InputImageCard()
                    MotionCard()
                    OutputCard()
                    SoundCard()
                    DiffusionCard()
                    GenerateButton()
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.magenta)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $model.showResult) {
            if let result = model.lastResult {
                ResultView(result: result)
            }
        }
        .onChange(of: model.showResult) { _, shown in
            if shown { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}

/// Always-visible way back to the model page: switch, delete or download
/// models without reinstalling the app.
private struct ModelSwitcherButton: View {
    @Environment(AppModel.self) private var model
    @State private var showModels = false

    var body: some View {
        Button {
            showModels = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                Text(model.modelManager.activeModel?.name ?? "Choose a model")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModels) {
            NavigationStack {
                ModelSetupView()
                    .background(CosmicBackground())
                    .navigationTitle("Models")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showModels = false }
                                .tint(Theme.cyan)
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Cards

private struct PromptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "sparkles", title: "Prompt") {
            TextField(
                "A neon jellyfish drifting through deep space…",
                text: $model.config.prompt,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.plain)
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

            TextField("Negative prompt", text: $model.config.negativePrompt, axis: .vertical)
                .lineLimit(1...3)
                .font(.footnote)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white.opacity(0.7))

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    model.config.prompt = PromptEnhancer.enhance(model.config.prompt)
                }
            } label: {
                Label("Enhance prompt", systemImage: "wand.and.sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.cyan)
            }
            .buttonStyle(.plain)
            .disabled(model.config.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Optional extra prompts: the clip is split evenly across scenes and the
/// img2img chain morphs from one to the next.
private struct StoryboardCard: View {
    @Environment(AppModel.self) private var model

    private let maxExtraScenes = 3

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "square.stack.3d.down.right", title: "Storyboard") {
            Text(model.config.scenes.isEmpty
                 ? "Single scene. Add scenes to morph the clip from one prompt to the next."
                 : sceneSummary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            ForEach(Array(model.config.scenes.indices), id: \.self) { index in
                HStack(spacing: 10) {
                    Text("\(index + 2)")
                        .font(.caption.weight(.heavy))
                        .frame(width: 24, height: 24)
                        .background(Theme.accent, in: Circle())
                    TextField("Scene \(index + 2) prompt…", text: $model.config.scenes[index], axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            _ = model.config.scenes.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.config.scenes.count < maxExtraScenes {
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        model.config.scenes.append("")
                    }
                } label: {
                    Label("Add scene", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cyan)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sceneSummary: String {
        let count = model.config.scenes.count + 1
        let perScene = model.config.frameCount / count
        return "\(count) scenes · ~\(perScene) frames each — the clip morphs between prompts."
    }
}

/// Image→video: a picked photo becomes frame 0 (img2img), the rest of the
/// clip animates away from it.
private struct InputImageCard: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "photo.on.rectangle.angled", title: "Image → Video") {
            if let image = model.inputImage {
                HStack(spacing: 14) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Starting from your photo")
                            .font(.subheadline.weight(.semibold))
                        Text("Frame 1 is re-dreamed from this image, then the clip animates away from it.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            model.inputImage = nil
                            pickerItem = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                LabeledSlider(
                    label: "Stylization",
                    value: $model.config.initImageStrength,
                    range: 0.2...0.8,
                    format: "%.2f"
                )
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose a photo", systemImage: "photo.badge.plus")
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
            Task { await load(item) }
        }
    }

    /// Bakes EXIF orientation, center-crops to the pipeline's 512² input.
    private func load(_ item: PhotosPickerItem) async {
        guard let cg = await PhotoLoader.loadCGImage(from: item) else { return }
        let prepared = VideoExporter.aspectFillSquare(cg, side: 512)
        withAnimation(.spring(duration: 0.3)) { model.inputImage = prepared }
    }
}

private struct MotionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "camera.metering.center.weighted", title: "Motion") {
            ChipPicker(
                items: CameraMove.allCases,
                label: { $0.label },
                selection: $model.config.cameraMove
            )
            LabeledSlider(
                label: "Motion strength",
                value: $model.config.motionStrength,
                range: 0.2...0.8,
                format: "%.2f"
            )
            LabeledSlider(
                label: "Coherence lock",
                value: $model.config.coherence,
                range: 0...1,
                format: "%.2f"
            )
            Text("Anchors colors to the first frame and damps flicker between frames — raise it if subjects mutate too much.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            if model.config.cameraMove != .fixed {
                LabeledSlider(
                    label: "Camera speed",
                    value: $model.config.cameraAmount,
                    range: 0.1...1.0,
                    format: "%.2f"
                )
            }
        }
    }
}

private struct OutputCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "film", title: "Output") {
            ChipPicker(
                items: ResolutionMode.allCases,
                label: { $0.label },
                selection: $model.config.resolution
            )
            HStack {
                Text("Frames")
                    .font(.subheadline)
                Spacer()
                StepperPill(
                    value: $model.config.frameCount,
                    range: 8...DeviceProfile.current.maxFrames,
                    step: 4
                )
            }
            HStack {
                Text("FPS")
                    .font(.subheadline)
                Spacer()
                ChipPicker(items: [8, 10, 12, 16], label: { "\($0)" }, selection: $model.config.fps)
                    .fixedSize()
            }
            HStack {
                Text("Smoothing")
                    .font(.subheadline)
                Spacer()
                ChipPicker(
                    items: SmoothingLevel.allCases,
                    label: { $0.label },
                    selection: $model.config.smoothing
                )
                .fixedSize()
            }
            HStack {
                Text("Duration")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1f s · %d fps out", model.config.durationSeconds, model.config.exportFPS))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.cyan)
            }
        }
    }
}

private struct SoundCard: View {
    @Environment(AppModel.self) private var model
    @State private var showAudioImporter = false

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "waveform", title: "Sound") {
            ChipPicker(
                items: SoundStyle.allCases,
                label: { $0.label },
                selection: $model.config.soundStyle
            )
            if model.config.soundStyle == .imported {
                Button {
                    showAudioImporter = true
                } label: {
                    Label(
                        model.customAudioURL?.lastPathComponent ?? "Choose an audio file (MP3, M4A, WAV…)",
                        systemImage: "music.note"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.cyan)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    )
                }
                .buttonStyle(.plain)
                .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) { result in
                    if case .success(let url) = result { importAudio(url) }
                }
                Text("The track is trimmed to the clip duration at export.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            if model.config.soundStyle != .none {
                LabeledSlider(
                    label: "Volume",
                    value: $model.config.soundVolume,
                    range: 0.1...1.0,
                    format: "%.2f"
                )
            }
        }
    }

    /// Copies the picked file into the app container so it survives the
    /// security-scoped access window.
    private func importAudio(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ImportedAudio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            model.customAudioURL = destination
        } catch {
            model.errorMessage = "Could not import audio: \(error.localizedDescription)"
        }
    }
}

private struct DiffusionCard: View {
    @Environment(AppModel.self) private var model
    @State private var seedText = ""

    /// Quality shortcuts: fewer steps = faster render, more steps = detail.
    /// Turbo targets distilled models (sd-turbo class): 2 steps, no CFG.
    private let presets: [(name: String, steps: Int, guidance: Float)] = [
        ("Turbo", 2, 1.0), ("Draft", 8, 6.0), ("Balanced", 12, 7.5), ("Fine", 20, 9.0),
    ]

    var body: some View {
        @Bindable var model = model
        GlassCard(icon: "dial.high", title: "Diffusion") {
            HStack(spacing: 8) {
                ForEach(presets, id: \.name) { preset in
                    let isActive = model.config.stepCount == preset.steps
                        && model.config.guidanceScale == preset.guidance
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            model.config.stepCount = preset.steps
                            model.config.guidanceScale = preset.guidance
                        }
                    } label: {
                        Text(preset.name)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 12).fill(Theme.accent)
                                } else {
                                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07))
                                }
                            }
                            .foregroundStyle(isActive ? .white : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Steps")
                    .font(.subheadline)
                Spacer()
                StepperPill(value: $model.config.stepCount, range: 2...30, step: 2)
            }
            LabeledSlider(
                label: "Guidance",
                value: $model.config.guidanceScale,
                range: 1...15,
                format: "%.1f"
            )
            HStack {
                Text("Seed")
                    .font(.subheadline)
                Spacer()
                TextField("random", text: $seedText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 140)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .onChange(of: seedText) { _, newValue in
                        model.config.seed = UInt32(newValue)
                    }
            }
        }
    }
}

// MARK: - Generate button & progress

private struct GenerateButton: View {
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    private var isDisabled: Bool {
        model.config.prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            Task { await model.generate() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                Text("GENERATE")
                    .kerning(3)
            }
            .font(.system(.headline, design: .rounded).weight(.black))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: Theme.violet.opacity(pulse ? 0.7 : 0.35), radius: pulse ? 24 : 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .padding(.top, 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct ProgressHeroView: View {
    @Environment(AppModel.self) private var model
    @State private var borderAngle: Double = 0

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white.opacity(0.04))
                if let frame = model.latestFrame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.accent)
                        Text("Dreaming…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(
                        AngularGradient(
                            colors: [Theme.violet, Theme.cyan, Theme.magenta, Theme.violet],
                            center: .center,
                            angle: .degrees(borderAngle)
                        ),
                        lineWidth: 2.5
                    )
            )
            .shadow(color: Theme.violet.opacity(0.35), radius: 22)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: model.progressFraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: model.progressFraction)
                Text("\(Int(model.progressFraction * 100))%")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .monospacedDigit()
            }
            .frame(width: 110, height: 110)

            VStack(spacing: 4) {
                Text(model.progressText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                if let eta = model.etaText {
                    Text(eta)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.cyan)
                }
            }
            .multilineTextAlignment(.center)

            Button {
                model.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.magenta.opacity(0.6)))
                    .foregroundStyle(Theme.magenta)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                borderAngle = 360
            }
        }
    }
}
