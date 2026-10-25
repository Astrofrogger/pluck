import CoreImage

/// HDR editing (Task 22): the picture goes past white only when asked, and SDR stays as it was.
extension PhotoSelfTest {
    static func hdr() {
        // A bright scene in linear light (a sky at three stops over middle grey), as a decoded photo.
        let bright = CIImage(color: CIColor(red: 1.6, green: 1.5, blue: 1.4, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        var a = PhotoAdjustments()
        a.exposure = 3
        func brightest(_ peak: Double) -> Float {
            let out = PhotoRender.adjusted(bright, a, isRaw: true, kelvin: 6500, peak: peak)
            var pixels = [Float](repeating: 0, count: 64 * 64 * 4)
            CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
                .render(out, toBitmap: &pixels, rowBytes: 64 * 16, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf,
                        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return stride(from: 0, to: pixels.count, by: 4).map { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }.max() ?? 0
        }
        let hdr = brightest(4), sdr = brightest(1)
        check("hdr peak passes through", hdr > 1.5 && sdr <= 1.001, "> 1.5 at peak 4, ≤ 1 at peak 1; got \(hdr), \(sdr)")
        check("hdr off is the SDR render", brightest(1) == sdr && PhotoEditing.peak(hdr: false, headroom: 8) == 1
              && PhotoEditing.peak(hdr: true, headroom: 8) == 4 && PhotoEditing.peak(hdr: true, headroom: 1) == 1,
              "peak 1 without HDR, the headroom up to 4 with it")
    }
}
