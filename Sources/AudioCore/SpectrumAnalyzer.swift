import Accelerate
import Foundation

/// Turns a block of samples into the band levels drawn by the visualizer.
///
/// Bands are spaced logarithmically because hearing is: a linear FFT would spend
/// most of its width on the top octave, where speech has almost nothing.
///
/// Owned by the analysis timer and touched from nowhere else.
public final class SpectrumAnalyzer: @unchecked Sendable {
	public let bandCount: Int
	public let fftSize: Int

	private let fft: vDSP.FFT<DSPSplitComplex>
	private let window: [Float]
	private var windowed: [Float]
	private var realParts: [Float]
	private var imagParts: [Float]
	private var magnitudes: [Float]
	private var levels: [Float]
	private var binRanges: [Range<Int>] = []
	private var configuredSampleRate: Double = 0

	private let lowestFrequency: Double = 40
	private let highestFrequency: Double = 16000
	private let floorDecibels: Float = -72

	public init(bandCount: Int = 24, fftSize: Int = 1024) {
		self.bandCount = bandCount
		self.fftSize = fftSize
		let half = fftSize / 2

		fft = vDSP.FFT(
			log2n: vDSP_Length(log2(Double(fftSize)).rounded()),
			radix: .radix2,
			ofType: DSPSplitComplex.self
		)!
		window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
		windowed = [Float](repeating: 0, count: fftSize)
		realParts = [Float](repeating: 0, count: half)
		imagParts = [Float](repeating: 0, count: half)
		magnitudes = [Float](repeating: 0, count: half)
		levels = [Float](repeating: 0, count: bandCount)
	}

	/// Normalized 0...1 band levels, smoothed for display.
	public func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> [Float] {
		guard count > 0, sampleRate > 0 else { return levels }
		configureBins(sampleRate: sampleRate)

		let usable = min(count, fftSize)
		windowed.withUnsafeMutableBufferPointer { destination in
			destination.baseAddress!.update(from: samples, count: usable)
			if usable < fftSize {
				destination.baseAddress!.advanced(by: usable)
					.update(repeating: 0, count: fftSize - usable)
			}
		}
		vDSP.multiply(windowed, window, result: &windowed)

		let half = fftSize / 2
		windowed.withUnsafeBufferPointer { input in
			realParts.withUnsafeMutableBufferPointer { real in
				imagParts.withUnsafeMutableBufferPointer { imaginary in
					var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
					input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
						vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
					}
					fft.forward(input: split, output: &split)
					magnitudes.withUnsafeMutableBufferPointer { output in
						vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
					}
				}
			}
		}

		let scale = 2 / Float(fftSize)
		vDSP.multiply(scale, magnitudes, result: &magnitudes)

		for band in 0 ..< bandCount {
			let range = binRanges[band]
			var peak: Float = 0
			for bin in range where bin < magnitudes.count {
				peak = max(peak, magnitudes[bin])
			}
			let decibels = 20 * log10(peak + 1e-9)
			let normalized = ((decibels - floorDecibels) / -floorDecibels).clamped(to: 0 ... 1)
			// Rise quickly so transients register, fall slowly so bars stay readable.
			let coefficient: Float = normalized > levels[band] ? 0.6 : 0.15
			levels[band] += (normalized - levels[band]) * coefficient
		}
		return levels
	}

	public func reset() {
		for index in levels.indices { levels[index] = 0 }
	}

	private func configureBins(sampleRate: Double) {
		guard sampleRate != configuredSampleRate else { return }
		configuredSampleRate = sampleRate

		let half = fftSize / 2
		let binWidth = sampleRate / Double(fftSize)
		let top = min(highestFrequency, sampleRate / 2)
		let ratio = log(top / lowestFrequency)

		binRanges = (0 ..< bandCount).map { band in
			let lower = lowestFrequency * exp(ratio * Double(band) / Double(bandCount))
			let upper = lowestFrequency * exp(ratio * Double(band + 1) / Double(bandCount))
			let first = max(1, Int(lower / binWidth))
			let last = max(first + 1, min(half, Int(upper / binWidth)))
			return first ..< last
		}
	}
}
