// SPDX-License-Identifier: MPL-2.0
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code, black on white whatever the appearance: that is what cameras read.
struct QRCodeView: View {
    let text: String
    let size: CGFloat
    let label: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(size * 0.06)
                .frame(width: size, height: size)
                .background(.white, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
        }
    }

    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
