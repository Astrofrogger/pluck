import AppKit

/// Editing in HDR on a screen that can show it: the picture goes past white, up to what the
/// screen has room for (4× at most, as an HDR export).
extension PhotoEditing {
    /// How bright the edit may go: 1 (white) without HDR; with it, the screen's headroom, up to 4.
    nonisolated static func peak(hdr: Bool, headroom: Double) -> Double {
        hdr ? min(max(headroom, 1), PhotoExportSettings.hdrPeak) : 1
    }

    /// The room above white a screen has now (1: none). It changes with the brightness and the screen.
    @MainActor static func headroom(of screen: NSScreen?) -> Double {
        guard let screen else { return 1 }
        return Double(max(screen.maximumExtendedDynamicRangeColorComponentValue, 1))
    }

    /// Whether the screen can show HDR at all (on macOS 15 and later, where the edit can use it).
    @MainActor static func canShowHDR(_ screen: NSScreen?) -> Bool {
        guard #available(macOS 15, *), let screen else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    }
}
