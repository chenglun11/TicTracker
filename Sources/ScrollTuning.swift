import SwiftUI

#if os(macOS)
private struct ScrollTuningView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureSoon(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureSoon(from: nsView)
    }

    private func configureSoon(from view: NSView) {
        DispatchQueue.main.async {
            guard let scrollView = findScrollView(from: view) else { return }
            scrollView.usesPredominantAxisScrolling = true
            scrollView.verticalScrollElasticity = .allowed
            scrollView.horizontalScrollElasticity = .none
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.scrollsDynamically = true
        }
    }

    private func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            current = candidate.superview
        }
        return nil
    }
}

extension View {
    func tunedForResponsiveScroll() -> some View {
        background(ScrollTuningView().allowsHitTesting(false))
    }
}
#endif
