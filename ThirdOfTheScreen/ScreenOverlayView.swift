import SwiftUI

struct ScreenOverlayView: View {
    let showGrid: Bool
    let emphasisEnabled: Bool
    let emphasisOpacity: Double
    let activeWindowCutouts: [CGRect]

    private let accent = Color(red: 0.11, green: 0.84, blue: 0.73)
    private let emphasisTint = Color(red: 0.07, green: 0.08, blue: 0.10)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let columnWidth = width / 3

            ZStack(alignment: .topLeading) {
                if emphasisEnabled, !activeWindowCutouts.isEmpty {
                    Rectangle()
                        .fill(emphasisTint.opacity(emphasisOpacity))
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                ForEach(Array(activeWindowCutouts.enumerated()), id: \.offset) { _, cutout in
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .frame(width: cutout.width, height: cutout.height)
                                        .position(x: cutout.midX, y: cutout.midY)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .frame(width: width, height: height, alignment: .topLeading)
                        }
                        .compositingGroup()
                }

                if showGrid {
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { index in
                            Rectangle()
                                .fill(accent.opacity(index == 1 ? 0.10 : 0.05))
                                .overlay(alignment: .top) {
                                    Text("1/3")
                                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .background(.black.opacity(0.32), in: Capsule())
                                        .padding(.top, 18)
                                }
                        }
                    }

                    Path { path in
                        path.addRoundedRect(
                            in: CGRect(origin: .zero, size: proxy.size),
                            cornerSize: CGSize(width: 18, height: 18)
                        )
                    }
                    .stroke(accent.opacity(0.85), style: StrokeStyle(lineWidth: 3))

                    Path { path in
                        path.move(to: CGPoint(x: columnWidth, y: 0))
                        path.addLine(to: CGPoint(x: columnWidth, y: height))
                        path.move(to: CGPoint(x: columnWidth * 2, y: 0))
                        path.addLine(to: CGPoint(x: columnWidth * 2, y: height))
                    }
                    .stroke(
                        accent.opacity(0.95),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 8])
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Thirds Overlay")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("\(Int(columnWidth.rounded())) pt per column")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(
                        .black.opacity(0.32),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .padding(18)
                }
            }
        }
        .allowsHitTesting(false)
        .background(Color.clear)
    }
}
