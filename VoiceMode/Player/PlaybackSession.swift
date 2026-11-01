import Observation
import SwiftUI
import UserNotifications

/// App-wide owner of the narration that's playing, so it keeps going after you leave the book.
/// Exactly one player owns the lock screen and remote commands at a time.
@Observable
final class PlaybackSession: NSObject {
    private(set) var book: Book?
    private(set) var player: NarrationPlayer?
    /// Set when a notification is tapped; the library opens `book` and clears it.
    var openRequested = false

    @ObservationIgnored private var document: Document?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// The player for `book`: the playing one if it's this book, otherwise a new, inactive one.
    func player(for book: Book, document: Document) -> NarrationPlayer {
        if book.persistentModelID == self.book?.persistentModelID, let player { return player }
        return NarrationPlayer(document: document, provider: ElevenLabsProvider.fromSecrets(),
                               director: OpenRouterDirector.fromSecrets())
    }

    /// Call before starting playback: hands the lock screen to `player`, stopping any other book.
    func activate(_ player: NarrationPlayer, book: Book, document: Document) {
        guard player !== self.player else { return }
        self.player?.shutdown()
        self.player = player
        self.book = book
        self.document = document
        player.artwork = Self.coverImage(for: book)
        player.onPositionChange = { [weak self] spoken in self?.save(spoken) }
        player.onOffline = { [weak self] in self?.notifyOffline() }
        // Bound to this book, so paragraphs still generating after a switch are charged to the right one.
        player.onCost = { [weak book] cost in book?.record(cost) }
        player.activate()
        Notifier.requestAuthorizationIfNeeded()
    }

    /// The reader closed. Keep narration that's playing or paused; release one that never started.
    func readerClosed(_ player: NarrationPlayer) {
        guard player === self.player else { return }
        if !player.isEngaged {
            player.shutdown()
            self.player = nil
            book = nil
        }
    }

    private func save(_ spoken: ReadingPosition) {
        guard let book, let document else { return }
        book.position = spoken
        book.readingProgress = document.fraction(at: spoken)
    }

    private func notifyOffline() {
        guard UIApplication.shared.applicationState != .active, let book, let spoken = player?.position, let document else { return }
        Notifier.post(
            title: "Narration paused · offline",
            body: "Lost connection in \(document.chapters[spoken.chapter].title). Tap to resume from that sentence once you’re back online.",
            cover: book.coverData ?? Self.coverImage(for: book).jpegData(compressionQuality: 0.8)
        )
    }

    /// The book's cover, or the generated one rendered to an image.
    static func coverImage(for book: Book) -> UIImage {
        if let data = book.coverData, let image = UIImage(data: data) { return image }
        let renderer = ImageRenderer(content: CoverArt(book: book).frame(width: 200, height: 300))
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }
}

extension PlaybackSession: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { openRequested = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [] // In the foreground the player bar already shows the state.
    }
}

/// Local notifications. Only for events worth interrupting someone for; no reminders or streaks.
enum Notifier {
    static func requestAuthorizationIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func post(title: String, body: String, cover: Data?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let cover {
            // Attachments must be files; iOS moves the file into its own store.
            let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
            if (try? cover.write(to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "cover", url: file) {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
