import Foundation

/// A small assertion harness.
///
/// The Command Line Tools SDK ships neither XCTest nor swift-testing, so `swift
/// test` cannot run without a full Xcode install. This keeps the project testable
/// from a bare toolchain. If Xcode is present, these checks port to swift-testing
/// almost line for line.
@MainActor
enum Report {
	static var passed = 0
	static var failures: [String] = []
	private static var currentSuite = ""

	static func suite(_ name: String, _ body: () throws -> Void) {
		currentSuite = name
		do {
			try body()
		} catch {
			failures.append("\(name): threw \(error)")
		}
	}

	static func check(_ condition: Bool, _ label: String) {
		if condition {
			passed += 1
		} else {
			failures.append("\(currentSuite): \(label)")
		}
	}

	static func close(
		_ actual: Double,
		_ expected: Double,
		tolerance: Double,
		_ label: String
	) {
		check(abs(actual - expected) <= tolerance, "\(label) (got \(actual), expected \(expected) ± \(tolerance))")
	}

	static func close(
		_ actual: Float,
		_ expected: Float,
		tolerance: Float,
		_ label: String
	) {
		close(Double(actual), Double(expected), tolerance: Double(tolerance), label)
	}

	static func finish() -> Never {
		if failures.isEmpty {
			print("ok: \(passed) checks passed")
			exit(0)
		}
		print("FAILED: \(failures.count) of \(passed + failures.count) checks")
		for failure in failures {
			print("  - \(failure)")
		}
		exit(1)
	}
}
