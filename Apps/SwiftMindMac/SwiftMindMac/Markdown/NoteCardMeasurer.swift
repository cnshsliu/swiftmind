import SwiftUI
import SwiftMindCore

enum NoteCardMeasurer {
    /// Height in points of the rendered note at `width`, using the same view
    /// as the card. Zero means the host could not measure.
    @MainActor
    static func height(markdown: String, width: CGFloat, fontSize: CGFloat, maxImageHeight: CGFloat) -> CGFloat {
        let root = MarkdownTextView(markdown: markdown, fontSize: fontSize, maxImageHeight: maxImageHeight)
            .padding(10)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: root)
        host.frame.size = CGSize(width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize.height
        return fitted.isFinite && fitted > 0 ? fitted : 0
    }
}
