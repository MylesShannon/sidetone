import CoreAudio
import Foundation

public enum HALError: Error, CustomStringConvertible {
	case property(OSStatus, AudioObjectPropertySelector)
	case noValue(AudioObjectPropertySelector)

	public var description: String {
		switch self {
		case let .property(status, selector):
			"CoreAudio property \(fourCharCode(selector)) failed with status \(status)"
		case let .noValue(selector):
			"CoreAudio property \(fourCharCode(selector)) returned no value"
		}
	}
}

public extension HAL {
	/// True for aggregates CoreAudio built for someone's private use rather than for
	/// a person to choose.
	///
	/// Opening the default device gets a process its own `CADefaultDeviceAggregate`,
	/// which then lives as long as the process does. It is plumbing, and it is not
	/// marked hidden, so the composition dictionary is the only thing that says so.
	static func isPrivateAggregate(_ device: AudioDeviceID) -> Bool {
		var address = HAL.address(kAudioAggregateDevicePropertyComposition)
		guard AudioObjectHasProperty(device, &address) else { return false }

		var size = UInt32(MemoryLayout<CFDictionary?>.size)
		var composition: CFDictionary?
		let status = withUnsafeMutablePointer(to: &composition) {
			AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
		}
		guard status == noErr, let dictionary = composition as? [String: Any] else { return false }
		return isPrivate(composition: dictionary)
	}

	/// Split out so the rule can be tested without a live aggregate to point at.
	static func isPrivate(composition: [String: Any]) -> Bool {
		(composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.intValue == 1
	}
}

/// CoreAudio status codes are four character codes, and its documentation is
/// written in those rather than in decimal.
public func fourCharCode(_ value: UInt32) -> String {
	let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
	let scalars = bytes.map { (32 ... 126).contains($0) ? Character(UnicodeScalar($0)) : "?" }
	return String(scalars)
}

/// Thin wrapper over the CoreAudio HAL property API.
public enum HAL {
	public static func address(
		_ selector: AudioObjectPropertySelector,
		scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
		element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
	) -> AudioObjectPropertyAddress {
		AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
	}

	public static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
		var address = address
		return AudioObjectHasProperty(object, &address)
	}

	public static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> T {
		var address = address
		var size = UInt32(MemoryLayout<T>.size)
		let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
		defer { buffer.deallocate() }
		let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer)
		guard status == noErr else { throw HALError.property(status, address.mSelector) }
		return buffer.pointee
	}

	public static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [T] {
		var address = address
		var size: UInt32 = 0
		var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
		guard status == noErr else { throw HALError.property(status, address.mSelector) }
		let count = Int(size) / MemoryLayout<T>.size
		guard count > 0 else { return [] }
		let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
		defer { buffer.deallocate() }
		status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
		guard status == noErr else { throw HALError.property(status, address.mSelector) }
		return Array(buffer.prefix(Int(size) / MemoryLayout<T>.size))
	}

	public static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
		var address = address
		var size = UInt32(MemoryLayout<CFString?>.size)
		var result: CFString?
		let status = withUnsafeMutablePointer(to: &result) {
			AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
		}
		guard status == noErr else { throw HALError.property(status, address.mSelector) }
		guard let result else { throw HALError.noValue(address.mSelector) }
		return result as String
	}

	public static func setValue<T>(_ value: T, on object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws {
		var address = address
		var value = value
		let status = withUnsafeBytes(of: &value) { bytes in
			AudioObjectSetPropertyData(
				object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!
			)
		}
		guard status == noErr else { throw HALError.property(status, address.mSelector) }
	}

	/// Total channels across every stream in a scope. Zero means the device cannot
	/// be used in that direction.
	public static func channelCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
		var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
		var size: UInt32 = 0
		guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

		let raw = UnsafeMutableRawPointer.allocate(
			byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
		)
		defer { raw.deallocate() }
		guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return 0 }

		let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
		return list.reduce(0) { $0 + Int($1.mNumberChannels) }
	}
}
