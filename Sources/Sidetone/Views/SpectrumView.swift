import SwiftUI

/// Log-spaced band levels drawn as bars.
struct SpectrumView: View {
	let bands: [Float]
	var isActive: Bool

	private let barSpacing: CGFloat = 2
	private let cornerRadius: CGFloat = 1.5

	var body: some View {
		Canvas { context, size in
			let count = max(bands.count, 1)
			let totalSpacing = barSpacing * CGFloat(count - 1)
			let barWidth = max(1, (size.width - totalSpacing) / CGFloat(count))

			// Gathered into two paths and filled twice, rather than two fills per bar.
			// The gradient always ran the height of the view rather than the height of
			// each bar, so one fill for all of them looks the same.
			var tracks = Path()
			var bars = Path()
			let corner = CGSize(width: cornerRadius, height: cornerRadius)

			for index in 0 ..< count {
				let x = CGFloat(index) * (barWidth + barSpacing)
				tracks.addRoundedRect(
					in: CGRect(x: x, y: 0, width: barWidth, height: size.height), cornerSize: corner
				)

				guard isActive, index < bands.count else { continue }
				let level = CGFloat(max(0, min(1, bands[index])))
				guard level > 0.001 else { continue }
				let height = max(1, level * size.height)
				bars.addRoundedRect(
					in: CGRect(x: x, y: size.height - height, width: barWidth, height: height),
					cornerSize: corner
				)
			}

			context.fill(tracks, with: .color(Theme.track))
			context.fill(bars, with: .linearGradient(
				Gradient(colors: [Theme.accent.opacity(0.5), Theme.accent]),
				startPoint: CGPoint(x: 0, y: size.height),
				endPoint: CGPoint(x: 0, y: 0)
			))
		}
		.frame(height: 54)
		// No animation on the bands. The analyser already smooths them for display, and
		// animating an array of levels asks the panel to redraw at the display's rate
		// between every update rather than once per update.
		.accessibilityHidden(true)
	}
}
