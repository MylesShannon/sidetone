import Synchronization

/// Single-producer, single-consumer float ring buffer holding interleaved frames.
///
/// The capture callback is the only writer and the render callback is the only
/// reader, so the indices need nothing heavier than acquire/release atomics. No
/// method here allocates, locks, or can block a real-time thread.
public final class RingBuffer: @unchecked Sendable {
	public let capacityFrames: Int
	public let channels: Int

	private let storage: UnsafeMutablePointer<Float>
	private let mask: Int
	private let writeIndex = Atomic<Int>(0)
	private let readIndex = Atomic<Int>(0)
	private let overrunCount = Atomic<Int>(0)

	public init(capacityFrames: Int, channels: Int) {
		let capacity = max(256, capacityFrames).roundedUpToPowerOfTwo
		self.capacityFrames = capacity
		self.channels = max(1, channels)
		mask = capacity - 1
		storage = .allocate(capacity: capacity * self.channels)
		storage.initialize(repeating: 0, count: capacity * self.channels)
	}

	deinit {
		storage.deinitialize(count: capacityFrames * channels)
		storage.deallocate()
	}

	public var availableFrames: Int {
		writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
	}

	public var freeFrames: Int { capacityFrames - availableFrames }

	public var overruns: Int { overrunCount.load(ordering: .relaxed) }

	/// Writes interleaved frames. When the reader has fallen behind the incoming
	/// frames are dropped and counted, rather than overwriting audio the reader is
	/// still using.
	@discardableResult
	public func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
		let write = writeIndex.load(ordering: .relaxed)
		let read = readIndex.load(ordering: .acquiring)
		let free = capacityFrames - (write - read)
		guard free > 0 else {
			overrunCount.wrappingAdd(frames, ordering: .relaxed)
			return 0
		}
		let count = min(frames, free)
		if count < frames {
			overrunCount.wrappingAdd(frames - count, ordering: .relaxed)
		}

		for frame in 0 ..< count {
			let slot = ((write + frame) & mask) * channels
			for channel in 0 ..< channels {
				storage[slot + channel] = source[frame * channels + channel]
			}
		}
		writeIndex.store(write + count, ordering: .releasing)
		return count
	}

	/// Reads one sample without consuming it. `frameOffset` is relative to the
	/// current read position; the caller must have checked `availableFrames`.
	public func sample(frameOffset: Int, channel: Int) -> Float {
		let read = readIndex.load(ordering: .relaxed)
		return storage[((read + frameOffset) & mask) * channels + min(channel, channels - 1)]
	}

	/// Copies out interleaved frames and consumes them.
	@discardableResult
	public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
		let read = readIndex.load(ordering: .relaxed)
		let available = writeIndex.load(ordering: .acquiring) - read
		let count = min(frames, available)
		guard count > 0 else { return 0 }

		for frame in 0 ..< count {
			let slot = ((read + frame) & mask) * channels
			for channel in 0 ..< channels {
				destination[frame * channels + channel] = storage[slot + channel]
			}
		}
		readIndex.store(read + count, ordering: .releasing)
		return count
	}

	public func advanceRead(frames: Int) {
		guard frames > 0 else { return }
		let read = readIndex.load(ordering: .relaxed)
		let available = writeIndex.load(ordering: .acquiring) - read
		readIndex.store(read + min(frames, available), ordering: .releasing)
	}

	/// Drops everything except the newest `frames`, so an analysis consumer that
	/// falls behind stays on recent audio instead of replaying history.
	public func keepNewest(_ frames: Int) {
		let read = readIndex.load(ordering: .relaxed)
		let available = writeIndex.load(ordering: .acquiring) - read
		if available > frames {
			readIndex.store(read + (available - frames), ordering: .releasing)
		}
	}

	public func reset() {
		readIndex.store(0, ordering: .relaxed)
		writeIndex.store(0, ordering: .relaxed)
		overrunCount.store(0, ordering: .relaxed)
	}
}

extension Int {
	var roundedUpToPowerOfTwo: Int {
		guard self > 1 else { return 1 }
		return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
	}
}
