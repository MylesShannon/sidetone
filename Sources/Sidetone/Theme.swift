import SwiftUI

/// Colours for the parts the app draws itself: meters, spectrum, and warnings.
///
/// All of them are either system colours or derived from `primary`/`accentColor`,
/// so light and dark mode both look deliberate rather than one being an
/// afterthought with hardcoded greys. Controls use system styles and bring their
/// own colours.
enum Theme {
	static let accent = Color.accentColor

	/// Meter and spectrum ramp. Green through amber to red, using system colours so
	/// they stay legible and consistent with the rest of macOS in both appearances.
	static let levelSafe = Color(nsColor: .systemGreen)
	static let levelWarm = Color(nsColor: .systemYellow)
	static let levelHot = Color(nsColor: .systemRed)

	/// Backgrounds for meter tracks and spectrum bars, tinted by the current
	/// foreground colour so they sit correctly on either appearance.
	static let track = Color.primary.opacity(0.09)
	static let trackBorder = Color.primary.opacity(0.06)

	static let panelDivider = Color.primary.opacity(0.08)
	static let warning = Color(nsColor: .systemOrange)

	/// Colour for a normalized 0...1 level.
	static func level(_ value: Float) -> Color {
		switch value {
		case ..<0.7: levelSafe
		case ..<0.9: levelWarm
		default: levelHot
		}
	}

	static let spectrumGradient = LinearGradient(
		colors: [accent.opacity(0.55), accent],
		startPoint: .bottom,
		endPoint: .top
	)
}
