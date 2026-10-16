import AppKit
import CoreAudio
import Accelerate

/// Live level bands from the Mac's audio output for the notch visualizer, using a
/// Core Audio process tap (macOS 14.2+). It runs only while something is playing,
/// nothing is recorded or stored, and levels reach the UI at most ~30 times a second.
@MainActor final class AudioSpectrum: ObservableObject {
    /// Bass, low-mid, high-mid, treble; 0...1.
    @Published private(set) var levels: [Float] = [0, 0, 0, 0]
    /// True once real audio has been seen; false means the UI should animate instead.
    @Published private(set) var live = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var analyzer: SpectrumAnalyzer?
    private let queue = DispatchQueue(label: "attending.spectrum", qos: .userInteractive)
    private(set) var running = false

    func start() {
        guard !running else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }
        tapID = tap
        guard let outputUID = Self.defaultOutputUID() else { stop(); return }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Attending Visualizer",
            kAudioAggregateDeviceUIDKey: "attending.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate) == noErr else { stop(); return }
        aggregateID = aggregate
        let sampleRate = Self.sampleRate(of: tap) ?? 48_000
        let analyzer = SpectrumAnalyzer(sampleRate: Float(sampleRate)) { [weak self] bands in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.publish(bands) } }
        }
        self.analyzer = analyzer
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, Self.ioBlock(analyzer))
        guard status == noErr, let proc else { stop(); return }
        procID = proc
        guard AudioDeviceStart(aggregate, proc) == noErr else { stop(); return }
        running = true
    }
    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
        analyzer = nil; running = false
        levels = [0, 0, 0, 0]
    }
    private func publish(_ bands: [Float]) {
        guard running else { return }
        levels = bands
        // Silence from a denied permission looks like all-zero bands; only real
        // signal switches the visualizer to live mode.
        if !live && bands.contains(where: { $0 > 0.02 }) { live = true }
    }

    /// The audio thread's callback, made outside the main actor: Core Audio calls it on
    /// its own queue, so it must not inherit main-actor isolation.
    nonisolated private static func ioBlock(_ analyzer: SpectrumAnalyzer) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in analyzer.consume(input) }
    }
    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
    private static func sampleRate(of tap: AudioObjectID) -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 else { return nil }
        return format.mSampleRate
    }
}

/// FFT band analysis on the audio queue. Accumulates a 1024-sample mono window,
/// then reports four smoothed, roughly perceptual bands.
private final class SpectrumAnalyzer: @unchecked Sendable {
    private let size = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private let window: [Float]
    private var samples: [Float] = []
    private var smoothed: [Float] = [0, 0, 0, 0]
    private var peakDb: [Float] = [-35, -35, -35, -35]
    private var lastReport = DispatchTime.now()
    private let binRanges: [Range<Int>]
    private let report: @Sendable ([Float]) -> Void

    init(sampleRate: Float, report: @escaping @Sendable ([Float]) -> Void) {
        self.report = report
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&w, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        window = w
        let binHz = sampleRate / 1024
        binRanges = [(40, 250), (250, 1200), (1200, 4500), (4500, 14000)].map { low, high in
            max(1, Int(Float(low) / binHz))..<max(2, Int(Float(high) / binHz))
        }
        samples.reserveCapacity(2048)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        let pointer = data.assumingMemoryBound(to: Float.self)
        // Mix interleaved channels to mono.
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += pointer[frame * channels + channel] }
            samples.append(sum / Float(channels))
        }
        // Non-overlapping windows: ~47 analyses a second at 48 kHz is plenty for 20 fps.
        while samples.count >= size {
            samples.withUnsafeBufferPointer { analyze($0) }
            samples.removeFirst(size)
        }
    }

    private lazy var windowed = [Float](repeating: 0, count: size)
    private lazy var real = [Float](repeating: 0, count: size / 2)
    private lazy var imag = [Float](repeating: 0, count: size / 2)
    private lazy var magnitudes = [Float](repeating: 0, count: size / 2)

    /// Reuses preallocated buffers; nothing is allocated per window.
    private func analyze(_ block: UnsafeBufferPointer<Float>) {
        vDSP_vmul(block.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }
        for (index, range) in binRanges.enumerated() {
            let upper = min(range.upperBound, magnitudes.count)
            guard range.lowerBound < upper else { continue }
            let slice = magnitudes[range.lowerBound..<upper]
            let mean = slice.reduce(0, +) / Float(slice.count)
            // Automatic gain: each band is scaled against its own recent peak (which
            // decays slowly), so bars keep moving at any volume or mix.
            let db = 20 * log10(max(mean, 1e-7))
            peakDb[index] = max(db, peakDb[index] - 0.04)
            let level = db < -80 ? 0 : min(1, max(0, (db - (peakDb[index] - 24)) / 24))
            // Fast attack, slower release, like a VU meter.
            smoothed[index] = level > smoothed[index] ? level : smoothed[index] * 0.82 + level * 0.18
        }
        let now = DispatchTime.now()
        // 20 updates a second is smooth for bars this small and keeps redraws cheap.
        if now.uptimeNanoseconds - lastReport.uptimeNanoseconds > 50_000_000 {
            lastReport = now
            report(smoothed)
        }
    }
}
