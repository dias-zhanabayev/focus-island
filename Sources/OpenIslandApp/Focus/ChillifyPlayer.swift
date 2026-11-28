import AVFoundation
import FocusCore
import Foundation
import Observation
import os

@MainActor
@Observable
final class ChillifyPlayer {
    nonisolated static let baseURL = URL(string: "https://chillify.me")!
    static let userUUIDKey = "focus.music.userUuid"
    nonisolated static let fadeSeconds: Double = 10
    nonisolated static let mixGenres: [MusicGenre] = [.chill, .cafe, .asian]

    private(set) var currentTrack: String?
    private(set) var isPlaying = false
    private(set) var isUserPaused = false
    private(set) var likedTracks: Set<String> = []

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let userUUID: String
    @ObservationIgnored private let sessionID = UUID().uuidString
    @ObservationIgnored private var tracks: [String] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var genre: MusicGenre?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var volume: Double = 0.5
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let logger = Logger(subsystem: "app.focusisland", category: "music")

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.session = session
        if let saved = defaults.string(forKey: Self.userUUIDKey) {
            userUUID = saved
        } else {
            let fresh = UUID().uuidString.lowercased()
            defaults.set(fresh, forKey: Self.userUUIDKey)
            userUUID = fresh
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let finished = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let finished, let current = self.player.currentItem, finished == ObjectIdentifier(current) else { return }
                self.next()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyVolume() }
        }
    }

    func update(playing: Bool, genre newGenre: MusicGenre, volume newVolume: Double) {
        volume = newVolume
        applyVolume()
        if newGenre != genre {
            genre = newGenre
            tracks = []
            currentTrack = nil
            player.replaceCurrentItem(with: nil)
            loadTask?.cancel()
            loadTask = nil
        }
        if !playing {
            isUserPaused = false
        }
        wanted = playing
        syncPlayback()
    }

    func togglePause() {
        isUserPaused.toggle()
        syncPlayback()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        let snapshot = tracks
        let current = index
        Task { [weak self] in
            guard let self else { return }
            let chosen = await self.fetchNext(tracks: snapshot, currentIndex: current) ?? Self.fallbackNext(count: snapshot.count, current: current)
            guard self.tracks == snapshot, chosen < snapshot.count else { return }
            self.load(index: chosen)
        }
    }

    func like() {
        guard let track = currentTrack, !likedTracks.contains(track) else { return }
        likedTracks.insert(track)
        let body: [String: Any] = ["userUuid": userUUID, "trackName": track, "genre": Self.genre(ofTrack: track)]
        Task { [weak self] in
            _ = await self?.post(path: "api/v1/likes", body: body)
        }
    }

    private func syncPlayback() {
        let shouldPlay = wanted && !isUserPaused
        if shouldPlay {
            if player.currentItem == nil {
                startLoadingIfNeeded()
            } else {
                player.play()
                isPlaying = true
            }
        } else {
            player.pause()
            isPlaying = false
        }
    }

    private func startLoadingIfNeeded() {
        guard loadTask == nil, let genre else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil }
            guard let result = await self.fetchTracks(genre: genre), !Task.isCancelled, self.genre == genre, !result.tracks.isEmpty else { return }
            self.tracks = result.tracks
            self.likedTracks = Set(result.liked)
            self.load(index: Int.random(in: 0..<result.tracks.count))
        }
    }

    private func load(index newIndex: Int) {
        guard newIndex < tracks.count, let url = Self.trackURL(tracks[newIndex]) else { return }
        index = newIndex
        currentTrack = tracks[newIndex]
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        applyVolume()
        syncPlayback()
    }

    private func applyVolume() {
        var multiplier = 1.0
        if let genre, genre.fadesOut, let item = player.currentItem {
            let duration = item.duration.seconds
            let position = item.currentTime().seconds
            if duration.isFinite, position.isFinite {
                multiplier = Self.fadeMultiplier(remaining: duration - position)
            }
        }
        player.volume = Float(volume * multiplier)
    }

    private func fetchTracks(genre: MusicGenre) async -> (tracks: [String], liked: [String])? {
        guard let url = Self.tracksURL(genre: genre, userUUID: userUUID) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(TracksResponse.self, from: data)
            return (decoded.tracks, decoded.likedTracks ?? [])
        } catch {
            logger.error("chillify tracks failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func fetchNext(tracks: [String], currentIndex: Int) async -> Int? {
        let body: [String: Any] = [
            "sessionId": sessionID,
            "tracks": tracks,
            "currentTrackIndex": currentIndex,
            "shuffle": true,
            "likedTracks": Array(likedTracks),
            "likedBoost": 2,
        ]
        guard let data = await post(path: "api/v1/next-track", body: body),
              let decoded = try? JSONDecoder().decode(NextResponse.self, from: data),
              decoded.success, let next = decoded.nextIndex else { return nil }
        return next
    }

    private func post(path: String, body: [String: Any]) async -> Data? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            logger.error("chillify \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private struct TracksResponse: Decodable {
        let tracks: [String]
        let likedTracks: [String]?
    }

    private struct NextResponse: Decodable {
        let success: Bool
        let nextIndex: Int?
    }

    nonisolated static func tracksURL(genre: MusicGenre, userUUID: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/tracks"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "folder", value: genre.rawValue)]
        if genre == .mix {
            items.append(URLQueryItem(name: "include", value: mixGenres.map(\.rawValue).joined(separator: ",")))
        }
        items.append(URLQueryItem(name: "userUuid", value: userUUID))
        components?.queryItems = items
        return components?.url
    }

    nonisolated static func trackURL(_ track: String) -> URL? {
        guard !track.contains(".."), !track.hasPrefix("/") else { return nil }
        var url = baseURL.appendingPathComponent("tracks")
        for part in track.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }

    nonisolated static func genre(ofTrack track: String) -> String {
        track.split(separator: "/").first.map(String.init) ?? ""
    }

    nonisolated static func fadeMultiplier(remaining: Double) -> Double {
        guard remaining < fadeSeconds else { return 1 }
        return max(0, pow(max(0, remaining) / fadeSeconds, 1.2))
    }

    nonisolated static func fallbackNext(count: Int, current: Int) -> Int {
        count > 0 ? (current + 1) % count : 0
    }
}
