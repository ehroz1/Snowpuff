import AVFoundation

/// A quiet bed of winter sound, made on the fly so the app ships no audio files: wind that rises and falls in
/// slow gusts, and a fire crackling in the next room.
final class Ambience {
    enum Mode: Int, CaseIterable {
        case off, wind, fireplace, both

        var title: String {
            switch self {
            case .off: tr("Off", "Выкл")
            case .wind: tr("Wind", "Ветер")
            case .fireplace: tr("Fireplace", "Камин")
            case .both: tr("Wind and Fireplace", "Ветер и камин")
            }
        }
    }

    var mode: Mode = .off {
        didSet { apply() }
    }
    /// 0 to 1.
    var volume: Float = 0.5 {
        didSet { synth.volume = volume }
    }
    /// Silenced during a call, whatever the mode.
    var muted = false {
        didSet { apply() }
    }
    /// How hard the snow is falling, 0 to 1: the wind follows it.
    var windiness: Float = 0.5 {
        didSet { synth.windiness = windiness }
    }

    private var engine: AVAudioEngine?
    private let synth = Synth()

    private func apply() {
        synth.wind = mode == .wind || mode == .both
        synth.fire = mode == .fireplace || mode == .both
        if mode == .off || muted {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        if let engine, engine.isRunning { return }
        let engine = AVAudioEngine()
        let output = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = output.sampleRate > 0 ? output.sampleRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        synth.sampleRate = Float(sampleRate)
        let synth = synth
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("Snowpuff: ambience failed to start: \(error)")
        }
    }

    private func stop() {
        engine?.stop()
        engine = nil
    }
}

/// Runs on the audio thread. Settings are plain floats and flags written from the main thread; a stale read
/// for a buffer or two is harmless.
private final class Synth: @unchecked Sendable {
    var sampleRate: Float = 48000
    var wind = false
    var fire = false
    var volume: Float = 0.5
    var windiness: Float = 0.5

    private var seed: UInt32 = 0x9E37_79B9
    // Wind.
    private var brown: (Float, Float) = (0, 0)
    private var hiss: (Float, Float) = (0, 0)
    private var gust: Float = 0.5
    private var gustTarget: Float = 0.5
    private var gustTimer: Float = 0
    private var windLevel: Float = 0
    // Fire.
    private var roar: Float = 0
    private var roarLow: Float = 0
    private var crackles: [(left: Float, right: Float, envelope: Float, decay: Float, tone: Float, last: Float)] = []
    private var fireLevel: Float = 0
    private var burst: Float = 0

    init() {
        crackles.reserveCapacity(32)
    }

    private func noise() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    private func chance() -> Float { noise() * 0.5 + 0.5 }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let dt = 1 / sampleRate
        let master = volume * 0.5
        for n in 0..<frames {
            var l: Float = 0, r: Float = 0

            // Levels glide, so switching a sound on or off fades rather than clicks.
            windLevel += ((wind ? 1 : 0) - windLevel) * dt * 1.5
            fireLevel += ((fire ? 1 : 0) - fireLevel) * dt * 1.5

            if windLevel > 0.0005 {
                gustTimer -= dt
                if gustTimer <= 0 {
                    gustTimer = 1.5 + chance() * 4
                    gustTarget = 0.25 + chance() * (0.45 + 0.5 * windiness)
                }
                gust += (gustTarget - gust) * dt * 0.6
                // Brown noise for the low rush, filtered white noise for the airy hiss whose brightness follows the gust.
                brown.0 = (brown.0 + 0.02 * noise()) / 1.02
                brown.1 = (brown.1 + 0.02 * noise()) / 1.02
                let cutoff = 0.02 + 0.06 * gust
                hiss.0 += (noise() - hiss.0) * cutoff
                hiss.1 += (noise() - hiss.1) * cutoff
                let level = windLevel * (0.25 + gust)
                l += (brown.0 * 3.2 + hiss.0 * 0.5) * level
                r += (brown.1 * 3.2 + hiss.1 * 0.5) * level
            }

            if fireLevel > 0.0005 {
                // A soft low roar under it all.
                roar += (noise() - roar) * 0.01
                roarLow += (roar - roarLow) * 0.05
                let body = roarLow * 1.4 * fireLevel
                l += body
                r += body
                // Crackles come in little bursts: now and then a run of snaps, between them only the odd one.
                burst = max(0, burst - dt * 2)
                if chance() < dt * 0.35 { burst = 1 }
                let rate: Float = 3 + 40 * burst
                if crackles.count < 24, chance() < rate * dt {
                    let pan = chance()
                    let loud = pow(chance(), 2.2) * 0.9 + 0.05
                    let pop = chance() < 0.12
                    crackles.append((
                        left: loud * (1 - pan * 0.7),
                        right: loud * (0.3 + pan * 0.7),
                        envelope: 1,
                        decay: pop ? 40 : 250 + chance() * 600,
                        tone: pop ? 0.25 : 0.9,
                        last: 0
                    ))
                }
                var k = crackles.count - 1
                while k >= 0 {
                    var c = crackles[k]
                    let raw = noise()
                    // High-passed for a snap, low-passed for a pop.
                    let shaped = c.tone > 0.5 ? raw - c.last : c.last + (raw - c.last) * c.tone
                    c.last = c.tone > 0.5 ? raw : shaped
                    let s = shaped * c.envelope * fireLevel
                    l += s * c.left
                    r += s * c.right
                    c.envelope *= exp(-c.decay * dt)
                    if c.envelope < 0.002 {
                        crackles.remove(at: k)
                    } else {
                        crackles[k] = c
                    }
                    k -= 1
                }
            }

            left[n] = max(-1, min(1, l * master))
            right[n] = max(-1, min(1, r * master))
        }
    }
}
