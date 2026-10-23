import AppKit
import SwiftUI

/// Hosts SwiftUI in a plain container so the view can paint under the window's
/// titlebar. Hosting the root directly as the content view makes macOS reserve
/// the titlebar as a safe-area inset, which leaves a transparent strip above
/// the glass.
@MainActor
func makeHostingContainer<Content: View>(rootView: Content) -> NSView {
    let container = NSView(frame: .zero)
    container.wantsLayer = true

    let hosting = NSHostingView(rootView: rootView)
    hosting.safeAreaRegions = []
    hosting.sizingOptions = []
    hosting.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(hosting)

    NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: container.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])

    return container
}
