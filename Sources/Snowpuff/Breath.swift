import AVFoundation

/// Listens to the microphone for a breath blown at it, and reports how hard.
/// Blowing on a microphone is loud rumbling noise, mostly far below the pitch of a voice, so a loud sound whose
/// energy sits mostly under ~150 Hz for a few tens of milliseconds counts as a puff; talking does not.
final class Breath {
    /// Called on the main thread with the puff's strength, about 0.2 to 1.2, several times a second while blowing.
    var puffed: (Float) -> Void = { _ in }
    private(set) var isListening = false
    private var engine: AVAudioEngine?
    private let detector = Detector()

    /// Asks for the microphone the first time; `completion` says whether listening started.
    func start(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isListening else { return completion(true) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(begin())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted && self.begin()) }
            }
        default:
            completion(false)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isListening = false
    }

    private func begin() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        detector.sampleRate = Float(format.sampleRate)
        let detector = detector
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            if let strength = detector.feed(channel, count: Int(buffer.frameLength)) {
                DispatchQueue.main.async { self?.puffed(strength) }
            }
        }
        do {
            try engine.start()
        } catch {
            NSLog("Snowpuff: microphone failed to start: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        isListening = true
        return true
    }
}

private final class Detector: @unchecked Sendable {
    var sampleRate: Float = 48000
    private var low: Float = 0
    private var streak: Float = 0
    private var lastPuff: Float = -10
    private var clock: Float = 0

    /// Returns a strength when this buffer continues a puff.
    func feed(_ samples: UnsafePointer<Float>, count: Int) -> Float? {
        guard count > 0 else { return nil }
        let duration = Float(count) / sampleRate
        clock += duration
        let alpha = 1 - exp(-2 * Float.pi * 150 / sampleRate)
        var total: Float = 0, lowEnergy: Float = 0
        for i in 0..<count {
            let x = samples[i]
            low += (x - low) * alpha
            total += x * x
            lowEnergy += low * low
        }
        let rms = (total / Float(count)).squareRoot()
        let share = total > 0 ? lowEnergy / total : 0
        if rms > 0.06 && share > 0.55 {
            streak += duration
        } else {
            streak = 0
            return nil
        }
        guard streak > 0.06, clock - lastPuff > 0.15 else { return nil }
        lastPuff = clock
        return min(1.2, max(0.2, (rms - 0.06) / 0.22 + 0.2))
    }
}
