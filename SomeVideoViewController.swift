import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            SomeVideoViewControllerRepresentable()
                .edgesIgnoringSafeArea(.all)
        }
    }
}

struct SomeVideoViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SomeVideoViewController {
        return SomeVideoViewController()
    }

    func updateUIViewController(_ uiViewController: SomeVideoViewController, context: Context) {
        // updateUIViewController
    }
}

import CoreHaptics
import UIKit
import AVFoundation
import Accelerate

class SomeVideoViewController: UIViewController {
    private let videoView = VideoView()
    private var audioAnalyzer: AudioHapticAnalyzer?
    private var audioDownloadTask: URLSessionDownloadTask?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let audioURL = URL(string: "some audio link")!
        audioDownloadTask = downloadAudioFile(from: audioURL) { [weak self] localURL in
            guard let self = self, let localURL = localURL else { return }
            let analyzer = AudioHapticAnalyzer()
            self.audioAnalyzer = analyzer
            analyzer.playAndAnalyzeAudio(url: localURL)
            self.videoView.play()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        videoView.pause()
        audioAnalyzer?.stop()
        audioAnalyzer = nil
        audioDownloadTask?.cancel()
        audioDownloadTask = nil
    }

    @discardableResult
    private func downloadAudioFile(from url: URL, completion: @escaping (URL?) -> Void) -> URLSessionDownloadTask {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            guard let tempURL = tempURL, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: localURL)
            do {
                try FileManager.default.copyItem(at: tempURL, to: localURL)
                DispatchQueue.main.async { completion(localURL) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
        task.resume()
        return task
    }
}

// AVAudioEngine Analyzer
final class AudioHapticAnalyzer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var lastHapticTime = Date()
    private var hapticEngine: CHHapticEngine?
    private var supportsCoreHaptics: Bool = {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }()

    init() {
        if supportsCoreHaptics {
            do {
                hapticEngine = try CHHapticEngine()
                try hapticEngine?.start()
            } catch {
                print("Error instantiating CHHapticEngine: \(error)")
            }
        }
    }

    func playAndAnalyzeAudio(url: URL) {
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            print("Error opening audio file: \(error)")
            return
        }
        let format = audioFile!.processingFormat

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            let rms = self.calculateRMS(buffer: buffer)
            let sampleRate = Float(format.sampleRate)
            let freq = self.dominantFrequency(buffer: buffer, sampleRate: sampleRate)
            if rms > 0.2 && Date().timeIntervalSince(self.lastHapticTime) > 0.1 {
                self.lastHapticTime = Date()
                self.performHaptic(rms: rms, freq: freq)
            }
        }

        do {
            try engine.start()
            if let audioFile = audioFile {
                playerNode.scheduleFile(audioFile, at: nil)
                playerNode.play()
            }
        } catch {
            print("Error instantiating engine: \(error)")
        }
    }

    private func performHaptic(rms: Float, freq: Float) {
        if supportsCoreHaptics {
            let intensity = min(max((rms - 0.2) * 2, 0), 1)
            let sharpness: Float = freq < 60 ? 0.1 : freq < 120 ? 0.3 : 1
            let duration: Double = 0.5

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0,
                duration: duration
            )
            do {
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try hapticEngine?.makePlayer(with: pattern)
                try player?.start(atTime: 0)
            } catch {
                print("Error playing haptic: \(error)")
            }
        } else {
            DispatchQueue.main.async {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
            }
        }
    }

    func dominantFrequency(buffer: AVAudioPCMBuffer, sampleRate: Float) -> Float {
        guard let channelData = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let log2n = vDSP_Length(log2(Float(frameCount)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else { return 0 }

        var windowedBuffer = [Float](repeating: 0, count: frameCount)
        vDSP_hann_window(&windowedBuffer, vDSP_Length(frameCount), Int32(vDSP_HANN_NORM))
        var windowedSignal = [Float](repeating: 0, count: frameCount)
        vDSP_vmul(channelData, 1, windowedBuffer, 1, &windowedSignal, 1, vDSP_Length(frameCount))

        var realp = [Float](repeating: 0, count: frameCount/2)
        var imagp = [Float](repeating: 0, count: frameCount/2)

        let frequency: Float = realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowedSignal.withUnsafeBufferPointer { signalPtr in
                    signalPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { typeConvertedTransferBuffer in
                        vDSP_ctoz(typeConvertedTransferBuffer, 2, &splitComplex, 1, vDSP_Length(frameCount/2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, Int32(FFT_FORWARD))
                var magnitudes = [Float](repeating: 0, count: frameCount/2)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(frameCount/2))
                var maxMag: Float = 0
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(&magnitudes, 1, &maxMag, &maxIndex, vDSP_Length(frameCount/2))
                vDSP_destroy_fftsetup(fftSetup)
                return Float(maxIndex) * sampleRate / Float(frameCount)
            }
        }

        return frequency
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelDataValue[i] * channelDataValue[i]
        }
        return sqrt(sum / Float(frameLength))
    }
}

final class VideoView: UIView {
    private let player = AVPlayer()
    private var playerLayer: AVPlayerLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        setupPlayerLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        setupPlayerLayer()
    }

    private func setupPlayerLayer() {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        playerLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Error configuring AVAudioSession: \(error)")
        }
        let urlString = "some view link"
        guard let url = URL(string: urlString) else { return }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.play()
    }

    func pause() {
        player.pause()
    }
}
