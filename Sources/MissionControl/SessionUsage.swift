import Foundation

/// Token totals for one Claude Code session, plus the (best-effort) USD cost
/// derived from the per-million-token Anthropic API rates.
struct SessionUsage: Hashable {
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Estimated USD using public Anthropic API rates as of late 2025. Falls
    /// back to Sonnet pricing if model is unknown.
    var costUSD: Double {
        let rates = pricing(for: model ?? "")
        let mil = 1_000_000.0
        return  Double(inputTokens)         * rates.input  / mil
              + Double(outputTokens)        * rates.output / mil
              + Double(cacheReadTokens)     * rates.cacheRead   / mil
              + Double(cacheCreationTokens) * rates.cacheCreate / mil
    }

    private struct Rates {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheCreate: Double
    }

    private func pricing(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("opus") {
            return Rates(input: 15, output: 75, cacheRead: 1.50, cacheCreate: 18.75)
        }
        if m.contains("haiku") {
            return Rates(input: 0.80, output: 4, cacheRead: 0.08, cacheCreate: 1.00)
        }
        // sonnet (incl. unknown)
        return Rates(input: 3, output: 15, cacheRead: 0.30, cacheCreate: 3.75)
    }

    var formattedSummary: String {
        let total = formatTokens(totalTokens)
        return String(format: "%@ tok · $%.3f", total, costUSD)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
