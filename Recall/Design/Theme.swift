import AppKit
import SwiftUI

enum Theme {
    static let panelWidth: CGFloat = 720
    static let cornerRadius: CGFloat = 28
    static let windowInset: CGFloat = 32

    /// The rest state is one line. Everything below it is earned by a query.
    static let searchHeight: CGFloat = 88
    static let searchPillHeight: CGFloat = 68
    static let filterButtonSize: CGFloat = 68
    static let filterSpacing: CGFloat = 10
    static let resultGap: CGFloat = 10

    static let hairlineHeight: CGFloat = 0.5
    static let sectionHeaderHeight: CGFloat = 46
    static let rowHeight: CGFloat = 56
    static let rowSpacing: CGFloat = 2
    static let listVerticalPadding: CGFloat = 10
    static let footerHeight: CGFloat = 36
    static let noResultsHeight: CGFloat = 96
    static let permissionHeight: CGFloat = 104

    /// Deliberately monochrome. The only colors on screen are the glass itself
    /// and the user's content; emphasis comes from hierarchy, not hue.
    static let accent = Color.primary
    static let accentStrong = Color(nsColor: .labelColor)
    static let hairline = Color.white.opacity(0.075)
    static let rowSelection = Color.primary.opacity(0.085)
    static let rowHover = Color.primary.opacity(0.03)
}

enum Motion {
    static let panel = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.24, dampingFraction: 0.88)
    static let row = Animation.easeOut(duration: 0.16)
    static let quick = Animation.easeOut(duration: 0.12)
    static let onboarding = Animation.easeInOut(duration: 0.22)
}

struct GlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = Theme.cornerRadius

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !forceLegacy {
                liquidGlass
            } else {
                legacyGlass
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.65),
                    lineWidth: 0.5
                )
        }
    }

    /// The snapshot harness renders through `cacheDisplay`, which cannot sample
    /// the desktop behind a live material. Force the pre-26 path there so visual
    /// QA still shows a representative surface.
    private var forceLegacy: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["RECALL_SNAPSHOT_LEGACY_GLASS"] == "1"
        #else
        false
        #endif
    }

    @available(macOS 26.0, *)
    private var liquidGlass: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.clear)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.035), Color.black.opacity(0.10)]
                        : [Color.white.opacity(0.22), Color.black.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
    }

    private var legacyGlass: some View {
        ZStack {
            VisualEffectView(material: colorScheme == .dark ? .hudWindow : .popover)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.045), Color.black.opacity(0.16)]
                    : [Color.white.opacity(0.42), Color.black.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.state = .active
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Theme.hairlineHeight)
    }
}

struct KeyCap: View {
    let text: String
    var animated: Bool = false
    @State private var breathing = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .scaleEffect(breathing ? 1.0 : 0.97)
            .opacity(breathing ? 1 : 0.9)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}
