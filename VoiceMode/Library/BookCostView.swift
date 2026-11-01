import SwiftUI

/// Converts ElevenLabs credits to dollars. The API reports credits per request but not their price,
/// which depends on the plan, so the rate is a user setting.
enum Pricing {
    static let creditRateKey = "elevenLabsUSDPer1KCredits"
    /// Starter plan: $5 for 30,000 credits.
    static let defaultUSDPer1KCredits = 5.0 / 30.0

    static func ttsUSD(credits: Int, ratePer1K: Double) -> Double {
        Double(credits) / 1000 * ratePer1K
    }

    /// Two decimals normally; more for the fractions of a cent the LLM usually costs.
    static func format(_ usd: Double) -> String {
        let digits = usd == 0 || usd >= 0.01 ? 2 : 4
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

/// Long-press preview on a book: what generating its narration has cost so far.
struct BookCostCard: View {
    let book: Book
    @AppStorage(Pricing.creditRateKey) private var ratePer1K = Pricing.defaultUSDPer1KCredits

    private var ttsUSD: Double { Pricing.ttsUSD(credits: book.ttsCredits, ratePer1K: ratePer1K) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CoverArt(book: book, compact: true)
                    .frame(width: 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.headline).lineLimit(2)
                    Text("Narration cost").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Divider()

            costRow("Text to speech", detail: "ElevenLabs \(ElevenLabsProvider.activeModelName) · \(book.ttsCredits.formatted()) credits", usd: ttsUSD)
            costRow("Expression (LLM)", detail: "Qwen via OpenRouter · \(book.llmTokens.formatted()) tokens", usd: book.llmCostUSD)

            Divider()

            HStack {
                Text("Total").font(.headline)
                Spacer()
                Text(Pricing.format(ttsUSD + book.llmCostUSD)).font(.headline.monospacedDigit())
            }

            Text("\(book.generatedParagraphs.formatted()) paragraphs generated. Replays come from the cache and are free. Credits priced at \(Pricing.format(ratePer1K)) per 1,000.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 320)
    }

    private func costRow(_ title: String, detail: String, usd: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Pricing.format(usd)).font(.subheadline.monospacedDigit())
        }
    }
}

/// Opened from the long-press menu: the same breakdown plus the credit price, which depends on your plan.
struct BookCostSheet: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pricing.creditRateKey) private var ratePer1K = Pricing.defaultUSDPer1KCredits

    var body: some View {
        NavigationStack {
            Form {
                Section { BookCostCard(book: book).frame(maxWidth: .infinity) }
                    .listRowInsets(EdgeInsets())
                Section {
                    HStack {
                        Text("Price per 1,000 credits")
                        Spacer()
                        TextField("Price", value: $ratePer1K, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                    }
                    Button("Reset to Starter plan ($5 / 30,000 credits)") { ratePer1K = Pricing.defaultUSDPer1KCredits }
                } footer: {
                    Text("ElevenLabs reports the credits each request uses but not what you pay for them. Your plan sets the price: divide the monthly price by the plan's credits.")
                }
            }
            .navigationTitle("Cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
