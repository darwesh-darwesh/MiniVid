import Foundation

/// Local "prompt booster": expands a base idea with curated style tokens.
/// Rule-based on purpose — no text LLM fits next to a 1.2 GB diffusion model
/// on a 4 GB iPad, and SD 2.1 responds well to these classic modifiers.
enum PromptEnhancer {

    private static let quality = [
        "highly detailed", "sharp focus", "intricate detail", "award-winning",
    ]
    private static let lighting = [
        "volumetric lighting", "golden hour glow", "neon rim light",
        "soft cinematic light", "dramatic chiaroscuro",
    ]
    private static let camera = [
        "35mm film still", "cinematic composition", "shallow depth of field",
        "wide-angle shot", "epic scale",
    ]
    private static let mood = [
        "ethereal atmosphere", "vivid colors", "moody haze", "dreamlike",
        "otherworldly",
    ]

    /// Appends one token per pool, skipping any the prompt already contains.
    static func enhance(_ prompt: String) -> String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return prompt }
        var parts = [base]
        for pool in [quality, lighting, camera, mood] {
            if let pick = pool.randomElement(),
               !base.localizedCaseInsensitiveContains(pick) {
                parts.append(pick)
            }
        }
        return parts.joined(separator: ", ")
    }
}
