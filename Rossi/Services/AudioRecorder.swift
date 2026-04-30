//
//  AudioRecorder.swift — обёртка над AVAudioRecorder для голосовых сообщений в чате.
//
//  Запись:  start() → m4a-файл во временной директории.
//  Метрика уровня сигнала каждые 100мс — для волнограммы во время записи.
//

import AVFoundation
import Combine

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    static let shared = AudioRecorder()

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var meterLevel: Float = 0          // 0...1
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var startedAt: Date?
    private var fileURL: URL?

    /// Запросить разрешение на микрофон. Возвращает true, если можно писать.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Начать запись. Возвращает URL файла где будет m4a.
    func start() throws -> URL {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey:           Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:         44100.0,
            AVNumberOfChannelsKey:   1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        r.isMeteringEnabled = true
        r.prepareToRecord()
        guard r.record() else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось начать запись"])
        }

        self.recorder = r
        self.fileURL = url
        self.startedAt = Date()
        self.elapsed = 0
        self.meterLevel = 0
        self.isRecording = true
        startLevelTimer()
        return url
    }

    /// Остановить и вернуть URL записанного файла.
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        let url = fileURL
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return url
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        levelTimer?.invalidate()
        levelTimer = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startLevelTimer() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let r = self.recorder else { return }
                r.updateMeters()
                let avgPower = r.averagePower(forChannel: 0)
                // dBFS: -160...0 → нормализуем к 0...1
                let level = max(0, min(1, (avgPower + 50) / 50))
                self.meterLevel = level
                if let s = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription
            self.isRecording = false
        }
    }
}
