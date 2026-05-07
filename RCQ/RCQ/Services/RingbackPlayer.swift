import AVFoundation
import Foundation

/// Outgoing-call ringback tone — synthesised at runtime so we don't need
/// a `.caf` asset in the bundle. Plays the classic US-style dual-tone
/// (440 Hz + 480 Hz, 2s on / 4s off, looping) through whatever audio
/// route AVAudioSession currently has selected (speaker for video calls,
/// earpiece for audio calls).
///
/// Incoming calls don't use this — CallKit plays the user's chosen
/// system ringtone automatically when `reportNewIncomingCall` lands.
@MainActor
final class RingbackPlayer {
    static let shared = RingbackPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isPlaying = false

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    /// Start the ringback loop. Idempotent — calling while already
    /// playing is a no-op so the start-on-state-transition pattern in
    /// CallService doesn't have to track it.
    func start() {
        guard !isPlaying else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let onSamples = Int(sampleRate * 2.0)   // 2 s of tone
        let offSamples = Int(sampleRate * 4.0)  // 4 s of silence
        let total = AVAudioFrameCount(onSamples + offSamples)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return }
        buf.frameLength = total

        let channels = Int(format.channelCount)
        let twoPi = 2.0 * Double.pi
        for c in 0..<channels {
            guard let data = buf.floatChannelData?[c] else { continue }
            for i in 0..<onSamples {
                let t = Double(i) / sampleRate
                // Half-amplitude per sine to avoid clipping the sum.
                let s = sin(twoPi * 440.0 * t) * 0.18
                       + sin(twoPi * 480.0 * t) * 0.18
                data[i] = Float(s)
            }
            for i in onSamples..<(onSamples + offSamples) {
                data[i] = 0
            }
        }
        buffer = buf

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            return
        }
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        player.play()
        isPlaying = true
    }

    /// Stop and unwind. Safe to call from any state. Tears the engine
    /// down too so the next call gets a fresh AVAudioEngine attached to
    /// whatever audio session category is in effect at that point.
    func stop() {
        guard isPlaying else { return }
        player.stop()
        engine.stop()
        buffer = nil
        isPlaying = false
    }
}
