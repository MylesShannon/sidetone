import AppKit
import Foundation

/// Temporary. Writes what the panel's window is doing to `~/Library/Logs/Sidetone-panel.log`.
///
/// The empty band above the panel only appears in builds linked against the SDK CI
/// pins, so it cannot be watched in a local build or measured from outside: a menu bar
/// panel does not appear in `CGWindowListCopyWindowInfo` at all. This goes away with the
/// fix it is here to find.
@MainActor
enum PanelDiag {
	private static let url = URL(filePath: NSHomeDirectory())
		.appending(path: "Library/Logs/Sidetone-panel.log")

	static func log(_ message: String) {
		let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
		guard let data = line.data(using: .utf8) else { return }
		if let handle = try? FileHandle(forWritingTo: url) {
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
			try? handle.close()
		} else {
			try? data.write(to: url)
		}
	}

	/// Every visible window with its level, frame, and what its content view says it
	/// would like to be. The panel is the one at the pop-up menu level.
	static func windows(_ note: String) {
		let described = NSApp.windows.filter(\.isVisible).map { window -> String in
			let content = window.contentView
			let fitting = content?.fittingSize ?? .zero
			return "level=\(window.level.rawValue)"
				+ " frame=\(short(window.frame))"
				+ " content=\(short(content?.frame ?? .zero))"
				+ " fitting=\(Int(fitting.width))x\(Int(fitting.height))"
				+ " view=\(content.map { String(describing: type(of: $0)) } ?? "none")"
		}
		log("\(note): \(described.joined(separator: "  |  "))")
	}

	private static func short(_ rect: CGRect) -> String {
		"(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
	}
}
