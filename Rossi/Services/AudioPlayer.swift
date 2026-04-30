//
//  AudioPlayer.swift — singleton-плеер голосовых сообщений.
//  Только один трек воспроизводится одновременно.
//

import AVFoundation
import Combine

@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()

    @Published var currentURL: URL?
    @Published var isPlaying = false
    @Published var progress: Double = 0     // 0...1
    @Published var duration: TimeInterval = 0
    @Published var current: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    func toggle(url: URL) {
        if currentURL == url, isPlaying {
            pause()
        } else if currentURL == url, !isPlaying {
            resume()
        } else {
            play(url: url)
        }
    }

    private func play(url: URL) {
        // Останавливаем предыдущий
        if let obs = timeObserver, let p = player {
            p.removeTimeObserver(obs)
            timeObserver = nil
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.play()
        player = p
        currentURL = url
        isPlaying = true
        progress = 0
        current = 0

        // Длительность: грузится асинхронно
        Task { @MainActor in
            let dur = try? await item.asset.load(.duration)
            self.duration = dur.map { CMTimeGetSeconds($0) } ?? 0
        }

        // Прогресс — каждые 0.2 сек
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let cur = CMTimeGetSeconds(t)
            self.current = cur
            if self.duration > 0 {
                self.progress = max(0, min(1, cur / self.duration))
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    @objc private func itemDidFinish() {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 1
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }
}
