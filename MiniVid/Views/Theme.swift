import SwiftUI

/// MiniVid's visual identity: deep-space gradient, neon violet→cyan accent,
/// glass cards. Everything is programmatic — no image assets to ship.
enum Theme {
    static let violet = Color(red: 0.58, green: 0.37, blue: 1.0)
    static let cyan = Color(red: 0.25, green: 0.87, blue: 0.96)
    static let magenta = Color(red: 0.95, green: 0.35, blue: 0.75)
    static let bgTop = Color(red: 0.055, green: 0.045, blue: 0.13)
    static let bgBottom = Color(red: 0.015, green: 0.015, blue: 0.05)

    static let accent = LinearGradient(
        colors: [violet, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let title = LinearGradient(
        colors: [magenta, violet, cyan],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct CosmicBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Theme.violet.opacity(0.22), .clear],
                center: .init(x: 0.15, y: 0.05), startRadius: 10, endRadius: 420
            )
            RadialGradient(
                colors: [Theme.cyan.opacity(0.13), .clear],
                center: .init(x: 0.9, y: 0.92), startRadius: 10, endRadius: 460
            )
            StarField()
        }
        .ignoresSafeArea()
    }
}

/// Deterministic starfield — same sky at every launch, no shimmer on redraw.
private struct StarField: View {
    var body: some View {
        Canvas { context, size in
            func hash(_ n: Double) -> Double {
                abs((sin(n) * 43758.5453).truncatingRemainder(dividingBy: 1))
            }
            for i in 0..<140 {
                let f = Double(i) + 1
                let x = hash(f * 12.9898) * size.width
                let y = hash(f * 78.233) * size.height
                let r = 0.4 + hash(f * 3.7) * 1.2
                let opacity = 0.12 + hash(f * 9.1) * 0.45
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// App title + device badge, shared between the main screens.
struct BrandHeader: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("MiniVid")
                .font(.system(size: 38, weight: .black, design: .rounded))
                .foregroundStyle(Theme.title)
                .shadow(color: Theme.violet.opacity(0.55), radius: 14)
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text("\(DeviceProfile.current.rawValue.capitalized) profile · fully on-device")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

/// Rounded glass panel with an icon + uppercase section title.
struct GlassCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                Text(title.uppercased())
                    .font(.caption.weight(.heavy))
                    .kerning(1.5)
                    .foregroundStyle(.white.opacity(0.55))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
    }
}

/// Horizontal row of selectable neon capsules.
struct ChipPicker<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button {
                        withAnimation(.spring(duration: 0.3)) { selection = item }
                    } label: {
                        Text(label(item))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if selection == item {
                                    Capsule().fill(Theme.accent)
                                } else {
                                    Capsule().fill(.white.opacity(0.07))
                                }
                            }
                            .overlay(
                                Capsule().strokeBorder(.white.opacity(selection == item ? 0 : 0.12))
                            )
                            .foregroundStyle(selection == item ? .white : .white.opacity(0.75))
                            .shadow(
                                color: selection == item ? Theme.violet.opacity(0.5) : .clear,
                                radius: 8
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Slider with a trailing neon value readout.
struct LabeledSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.cyan)
            }
            Slider(value: $value, in: range)
                .tint(Theme.cyan)
        }
    }
}

/// Compact − / value / + control used instead of the stock Stepper.
struct StepperPill: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 14) {
            pillButton("minus") { value = max(range.lowerBound, value - step) }
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 34)
            pillButton("plus") { value = min(range.upperBound, value + step) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
    }

    private func pillButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.cyan)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
