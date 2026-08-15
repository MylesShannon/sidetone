import Synchronization

/// What the UI draws. Produced off the audio threads by the analysis timer and
/// read on the main thread, so it is a plain value behind a mutex.
public struct AudioSnapshot: Sendable, Equatable {
	public var peak: Float = 0
	public var rms: Float = 0
	public var bands: [Float] = []
	public var clipping: Bool = false
	public var limiterReductionDecibels: Double = 0
	public var underruns: Int = 0
	public var overruns: Int = 0
	public var bufferFillFrames: Int = 0

	public init() {}

	public static let silent = AudioSnapshot()
}

public final class SnapshotBox: Sendable {
	private let storage = Mutex(AudioSnapshot.silent)

	public init() {}

	public func read() -> AudioSnapshot {
		storage.withLock { $0 }
	}

	public func write(_ snapshot: AudioSnapshot) {
		storage.withLock { $0 = snapshot }
	}

	public func clear() {
		storage.withLock { $0 = .silent }
	}
}

/// Float that can be handed between the UI and the audio threads. `Atomic` has no
/// Float conformance, so this stores the bit pattern.
public final class AtomicFloat: Sendable {
	private let storage: Atomic<UInt32>

	public init(_ value: Float) {
		storage = Atomic(value.bitPattern)
	}

	public var value: Float {
		get { Float(bitPattern: storage.load(ordering: .relaxed)) }
		set { storage.store(newValue.bitPattern, ordering: .relaxed) }
	}
}
