import SwiftData
import SwiftUI

@main
struct VoiceModeApp: App {
    @State private var playback = PlaybackSession()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(playback)
        }
        .modelContainer(for: Book.self)
    }
}
