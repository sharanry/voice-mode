import SwiftUI

struct PlayerBar: View {
    let player: NarrationPlayer
    let theme: ReaderTheme
    let togglePlayback: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if case .failed(let message) = player.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 36) {
                Button { cycleRate() } label: {
                    Text(rateLabel).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 48)
                }
                Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                Button(action: togglePlayback) {
                    ZStack {
                        Circle().fill(ReaderTheme.accent).frame(width: 52, height: 52)
                        if player.status == .loading {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: player.status == .playing ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(.black)
                        }
                    }
                }
                .accessibilityLabel(player.status == .playing ? "Pause" : "Play")
                Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title2) }
                Color.clear.frame(width: 48, height: 1)
            }
            .foregroundStyle(Color(uiColor: theme.text))
        }
    }

    private var rateLabel: String {
        player.rate == player.rate.rounded() ? "\(Int(player.rate))×" : "\(player.rate.formatted())×"
    }

    private func cycleRate() {
        let rates = NarrationPlayer.rates
        let index = rates.firstIndex(of: player.rate) ?? 1
        player.rate = rates[(index + 1) % rates.count]
    }
}
