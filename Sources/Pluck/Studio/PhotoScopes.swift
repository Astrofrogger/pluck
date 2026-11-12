import CoreImage
import SwiftUI

/// The scope over the Adjust panel: the histogram, or the Edit page's parade, waveform and vectorscope
/// (same maths and drawing), of the developed preview.
enum PhotoScopes {
    /// Scope data from a developed image: a 256 px copy in sRGB steps (as the screen shows it), off the main thread by the caller.
    nonisolated static func data(_ image: CIImage) -> ScopeData? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, 256 / max(extent.width, extent.height))
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
        guard let cg = PhotoEngine.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: space) else { return nil }
        return ScopeAnalyzer.analyzed(cg, columns: 128)
    }
}

struct PhotoScopeView: View {
    let bins: [[Float]]
    let data: ScopeData?
    var drag: ((WritableKeyPath<PhotoAdjustments, Double>, Double) -> Void)?
    @AppStorage("photoScopeKind") private var choice = "histogram"

    var body: some View {
        let kind = ScopeKind(rawValue: choice)
        VStack(spacing: 6) {
            if let kind {
                ScopesView(data: data, kind: kind, fit: false)
                    .frame(maxWidth: kind == .vectorscope ? 120 : .infinity)
                    .frame(height: kind == .vectorscope ? 120 : 64)
                    .padding(.horizontal, 8)
                    .accessibilityHidden(false)
                    .accessibilityLabel(Text(kind.label))
            } else {
                HistogramView(bins: bins, drag: drag)
            }
        }
    }
}
