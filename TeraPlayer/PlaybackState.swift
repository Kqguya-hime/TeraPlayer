import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class PlaybackState {
    var player = AVPlayer()
    var isPlaying = false
    var nowPlayingManager = NowPlayingManager()

    @ObservationIgnored
    var timeObserverToken: Any?

    var elapsedTime: Double = 0
    var playbackDuration: Double = 0
    var isSeeking = false
}

struct PlaybackTimelineView: View {
    @Bindable var playbackState: PlaybackState
    let seekPlayback: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: $playbackState.elapsedTime,
                in: 0...max(playbackState.playbackDuration, 1),
                onEditingChanged: { isEditing in
                    playbackState.isSeeking = isEditing
                    if !isEditing {
                        seekPlayback(playbackState.elapsedTime)
                    }
                }
            )
            .disabled(playbackState.playbackDuration <= 0)

            HStack {
                Text(formattedTime(playbackState.elapsedTime))
                Spacer()
                Text(
                    playbackState.playbackDuration > 0
                        ? formattedTime(playbackState.playbackDuration)
                        : "--:--"
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(max(0, seconds))
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}
