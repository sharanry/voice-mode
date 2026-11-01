import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Plays a document chunk by chunk through a TTS provider and publishes the text
/// position currently being spoken, which the reader follows.
@Observable
final class NarrationPlayer: NSObject {
    enum Status: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    private struct ChunkID: Hashable {
        var chapter: Int
        var chunk: Int
    }

    static let rates: [Float] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    private(set) var status: Status = .idle
    private(set) var position: ReadingPosition?
    var rate: Float = 1.0 {
        didSet {
            audioPlayer?.rate = rate
            updateNowPlaying()
        }
    }

    @ObservationIgnored private let document: Document
    @ObservationIgnored private let provider: (any TTSProvider)?
    @ObservationIgnored private let director: (any ExpressionDirector)?
    @ObservationIgnored private var chunkCache: [Int: [NSRange]] = [:]
    @ObservationIgnored private var clipTasks: [ChunkID: Task<SpeechClip, Error>] = [:]
    @ObservationIgnored private var current: ChunkID?
    @ObservationIgnored private var clip: SpeechClip?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let chapterStarts: [Int]
    /// Narration speed at 1×, measured from synthesized clips; drives the lock screen's chapter timeline.
    @ObservationIgnored private var charsPerSecond = 14.0

    /// Lock screen / Dynamic Island cover. Set by `PlaybackSession`.
    @ObservationIgnored var artwork: UIImage?
    /// Called whenever the spoken position moves, so it can be saved even with the book closed.
    @ObservationIgnored var onPositionChange: ((ReadingPosition) -> Void)?
    /// Called with the cost of every paragraph generated (cache hits are free and not reported).
    @ObservationIgnored var onCost: ((SpeechCost) -> Void)?
    /// Called when narration stops because the network is unavailable.
    @ObservationIgnored var onOffline: (() -> Void)?

    init(document: Document, provider: (any TTSProvider)?, director: (any ExpressionDirector)?) {
        self.document = document
        self.provider = provider
        self.director = director
        chapterStarts = document.chapterStarts
        super.init()
    }

    var isActive: Bool { status == .playing || status == .loading }
    /// Has something to show on the lock screen: playing, loading or paused.
    var isEngaged: Bool { status != .idle }

    // MARK: Controls

    func play(from start: ReadingPosition) {
        guard provider != nil else {
            status = .failed(TTSError.missingKey.localizedDescription)
            return
        }
        guard document.chapters.indices.contains(start.chapter) else { return }
        let ranges = chunks(forChapter: start.chapter)
        guard let index = TextSegmenter.index(of: start.offset, in: ranges) ?? (ranges.isEmpty ? nil : 0) else {
            if let next = firstChunk(fromChapter: start.chapter + 1) { play(from: startPosition(of: next)) }
            return
        }

        stopAudio()
        let id = ChunkID(chapter: start.chapter, chunk: index)
        setPosition(start)
        status = .loading
        updateNowPlaying()
        loadToken += 1
        let token = loadToken
        // While loading no audio plays, so iOS could suspend a backgrounded app; ask for time to finish.
        beginBackgroundTask()
        Task {
            defer { self.endBackgroundTask() }
            do {
                let clip = try await self.clip(for: id)
                guard token == self.loadToken else { return }
                let within = max(0, start.offset - ranges[index].location)
                try self.startPlayback(clip, id: id, at: clip.time(forOffset: within))
                self.prefetch(after: id)
            } catch {
                guard token == self.loadToken else { return }
                self.status = .failed(Self.isOffline(error) ? "You’re offline. Narration will continue from here." : error.localizedDescription)
                self.updateNowPlaying()
                if Self.isOffline(error) { self.onOffline?() }
            }
        }
    }

    func pause() {
        if status == .loading {
            stop()
            return
        }
        guard status == .playing else { return }
        audioPlayer?.pause()
        tick()
        status = .paused
        updateNowPlaying()
    }

    func resume() {
        if status == .paused, let audioPlayer {
            audioPlayer.play()
            status = .playing
            updateNowPlaying()
        } else if !isActive, let position {
            play(from: position) // e.g. after going offline
        }
    }

    func stop() {
        loadToken += 1
        stopAudio()
        status = .idle
        updateNowPlaying()
    }

    func skip(by seconds: TimeInterval) {
        guard let audioPlayer, let current else { return }
        let target = audioPlayer.currentTime + seconds
        if target >= 0, target < audioPlayer.duration {
            audioPlayer.currentTime = target
            tick()
            updateNowPlaying()
        } else if target >= audioPlayer.duration {
            if let next = chunk(after: current) { play(from: startPosition(of: next)) }
        } else if current.chunk > 0 {
            play(from: startPosition(of: ChunkID(chapter: current.chapter, chunk: current.chunk - 1)))
        } else {
            audioPlayer.currentTime = 0
            tick()
        }
    }

    func seek(toChapterTime time: TimeInterval) {
        guard let chapter = current?.chapter ?? position?.chapter else { return }
        let length = chapterStarts[chapter + 1] - chapterStarts[chapter]
        play(from: ReadingPosition(chapter: chapter, offset: min(max(Int(time * charsPerSecond), 0), max(length - 1, 0))))
    }

    /// Makes this the player that owns the lock screen, remote commands and audio interruptions.
    func activate() {
        guard remoteTargets.isEmpty else { return }
        configureRemoteCommands()
        observeAudioSession()
    }

    /// Releases the lock screen and remote commands.
    func shutdown() {
        stop()
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Chunks

    private func chunks(forChapter chapter: Int) -> [NSRange] {
        if let cached = chunkCache[chapter] { return cached }
        let ranges = TextSegmenter.chunks(in: document.chapters[chapter].text)
        chunkCache[chapter] = ranges
        return ranges
    }

    private func startPosition(of id: ChunkID) -> ReadingPosition {
        ReadingPosition(chapter: id.chapter, offset: chunks(forChapter: id.chapter)[id.chunk].location)
    }

    private func chunk(after id: ChunkID) -> ChunkID? {
        if id.chunk + 1 < chunks(forChapter: id.chapter).count {
            return ChunkID(chapter: id.chapter, chunk: id.chunk + 1)
        }
        return firstChunk(fromChapter: id.chapter + 1)
    }

    private func firstChunk(fromChapter chapter: Int) -> ChunkID? {
        guard chapter < document.chapters.count else { return nil }
        for index in chapter..<document.chapters.count where !chunks(forChapter: index).isEmpty {
            return ChunkID(chapter: index, chunk: 0)
        }
        return nil
    }

    private func clip(for id: ChunkID) async throws -> SpeechClip {
        if let task = clipTasks[id] { return try await task.value }
        guard let provider else { throw TTSError.missingKey }
        let ranges = chunks(forChapter: id.chapter)
        let text = document.chapters[id.chapter].text as NSString
        let speech = SpeechRequest(
            text: text.substring(with: ranges[id.chunk]),
            previousText: id.chunk > 0 ? text.substring(with: ranges[id.chunk - 1]) : nil,
            nextText: id.chunk + 1 < ranges.count ? text.substring(with: ranges[id.chunk + 1]) : nil
        )
        let director = self.director
        let task = Task { try await TTSCache.shared.clip(for: speech, provider: provider, director: director) }
        clipTasks[id] = task
        do {
            // Only the request that created the task reports its cost, so it's counted once.
            let clip = try await task.value
            if clip.cost != .free { onCost?(clip.cost) }
            return clip
        } catch {
            clipTasks[id] = nil
            throw error
        }
    }

    /// Keeps two paragraphs ready so playback never waits on the network between them,
    /// which matters most with the screen locked.
    private func prefetch(after id: ChunkID) {
        guard let next = chunk(after: id) else { return }
        Task {
            _ = try? await clip(for: next)
            if let afterNext = chunk(after: next) { _ = try? await clip(for: afterNext) }
        }
    }

    // MARK: Playback

    private func startPlayback(_ clip: SpeechClip, id: ChunkID, at time: TimeInterval) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: clip.audioURL)
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        player.currentTime = min(time, max(0, player.duration - 0.05))
        player.play()

        audioPlayer = player
        self.clip = clip
        current = id
        status = .playing
        measureNarrationSpeed(clip, id: id, duration: player.duration)
        startTicker()
        updateNowPlaying()
    }

    private func stopAudio() {
        ticker?.cancel()
        ticker = nil
        audioPlayer?.stop()
        audioPlayer = nil
        clip = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func tick() {
        guard let audioPlayer, let clip, let current else { return }
        let base = chunks(forChapter: current.chapter)[current.chunk].location
        let spoken = ReadingPosition(chapter: current.chapter, offset: base + clip.offset(atTime: audioPlayer.currentTime))
        if spoken != position { setPosition(spoken) }
    }

    private func setPosition(_ spoken: ReadingPosition) {
        position = spoken
        onPositionChange?(spoken)
    }

    private func measureNarrationSpeed(_ clip: SpeechClip, id: ChunkID, duration: TimeInterval) {
        let length = chunks(forChapter: id.chapter)[id.chunk].length
        guard duration > 2, length > 40 else { return }
        // Smooth across clips so the lock screen timeline doesn't jump around.
        charsPerSecond = charsPerSecond * 0.7 + (Double(length) / duration) * 0.3
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Narration") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed]
            .contains(urlError.code)
    }

    private func chunkDidFinish(_ finished: ObjectIdentifier) {
        guard let audioPlayer, ObjectIdentifier(audioPlayer) == finished, let current else { return }
        if let next = chunk(after: current) {
            play(from: startPosition(of: next))
        } else {
            stop()
        }
    }

    // MARK: Lock screen & Dynamic Island

    /// iOS draws the lock screen player, Control Center and Dynamic Island from this.
    /// Times describe the whole chapter (estimated from narration speed), not the current paragraph.
    private func updateNowPlaying() {
        guard status != .idle, let spoken = position ?? current.map(startPosition) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let chapter = document.chapters[spoken.chapter]
        let chapterLength = chapterStarts[spoken.chapter + 1] - chapterStarts[spoken.chapter]
        var title = chapter.title
        if let heading = chapter.headings.last(where: { $0.offset <= spoken.offset }) { title += " · \(heading.title)" }

        var subtitle = [document.title]
        if rate != 1 { subtitle.append("\(rate.formatted())×") }
        let fraction = Double(chapterStarts[spoken.chapter] + spoken.offset) / Double(max(chapterStarts.last ?? 1, 1))
        subtitle.append(fraction.formatted(.percent.precision(.fractionLength(0))))

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle.joined(separator: " · "),
            MPMediaItemPropertyAlbumTitle: document.author ?? document.title,
            MPMediaItemPropertyPlaybackDuration: Double(chapterLength) / charsPerSecond,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(spoken.offset) / charsPerSecond,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer calls the image handler on a background thread.
    private nonisolated static func mediaArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping (NarrationPlayer, MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                action(self, event)
                return .success
            }
            remoteTargets.append((command, target))
        }
        add(center.playCommand) { player, _ in player.resume() }
        add(center.pauseCommand) { player, _ in player.pause() }
        add(center.togglePlayPauseCommand) { player, _ in player.status == .playing ? player.pause() : player.resume() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { player, _ in player.skip(by: 15) }
        add(center.skipBackwardCommand) { player, _ in player.skip(by: -15) }
        add(center.changePlaybackPositionCommand) { player, event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { player.seek(toChapterTime: event.positionTime) }
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        add(center.changePlaybackRateCommand) { player, event in
            if let event = event as? MPChangePlaybackRateCommandEvent { player.rate = event.playbackRate }
        }
    }

    // MARK: Interruptions

    /// Pause for calls and Siri (resuming after when iOS says so) and when headphones are unplugged.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began: self.pause()
                case .ended where options.contains(.shouldResume): self.resume()
                default: break
                }
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
    }
}

extension NarrationPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.chunkDidFinish(finished) }
    }
}
