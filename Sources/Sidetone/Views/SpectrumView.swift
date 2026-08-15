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

			for index in 0 ..< count {
				let x = CGFloat(index) * (barWidth + barSpacing)
				let track = Path(
					roundedRect: CGRect(x: x, y: 0, width: barWidth, height: size.height),
					cornerRadius: cornerRadius
				)
				context.fill(track, with: .color(Theme.track))

				guard isActive, index < bands.count else { continue }
				let level = CGFloat(max(0, min(1, bands[index])))
				guard level > 0.001 else { continue }
				let height = max(1, level * size.height)
				let bar = Path(
					roundedRect: CGRect(x: x, y: size.height - height, width: barWidth, height: height),
					cornerRadius: cornerRadius
				)
				context.fill(bar, with: .linearGradient(
					Gradient(colors: [Theme.accent.opacity(0.5), Theme.accent]),
					startPoint: CGPoint(x: 0, y: size.height),
					endPoint: CGPoint(x: 0, y: 0)
				))
			}
		}
		.frame(height: 54)
		.animation(.linear(duration: 0.05), value: bands)
		.accessibilityHidden(true)
	}
}
