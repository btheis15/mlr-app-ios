import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - QRCodeView
//
// Generates a QR code entirely on-device via Core Image's built-in
// CIQRCodeGenerator — no third-party API, no network call, mirroring web's
// "generated on-device via the qrcode npm package" doctrine (the `qrcode`
// package there; Core Image is the native iOS equivalent). A QR code is just
// a container for the string it encodes, not anything issued by whatever
// service the link points at — a self-generated code scanning to the same
// URL behaves identically to one from the destination's own app.

struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.generate(from: string) {
            Image(uiImage: image)
                .interpolation(.none)   // keep QR modules crisp when scaled up
                .resizable()
                .scaledToFit()
        } else {
            Rectangle()
                .fill(Color.mlrCard)
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "qrcode").foregroundStyle(Color.mlrTextSubtle))
        }
    }

    private static func generate(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"   // built-in Reed–Solomon error correction
        guard let output = filter.outputImage else { return nil }
        // Upscale the (tiny) native pixel grid so it renders crisp, not blurry.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - VenmoQRDisclosure
//
// A collapsed "Show QR code" toggle under a member's Venmo row — never adds
// visual weight for the common case (tapping the row to open Venmo), but
// lets someone paying in person scan instead. Mirrors web's MemberSheet Pay
// section disclosure exactly, including the re-confirmation copy.

struct VenmoQRDisclosure: View {
    let name: String
    let handle: String
    let urlString: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.mlrScaled(12))
                    Text(expanded ? "Hide QR code" : "Show QR code")
                        .font(.mlrScaled(12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Color.mlrVenmo)
            }
            .buttonStyle(.pressable)

            if expanded {
                VStack(spacing: 8) {
                    QRCodeView(string: urlString)
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mlrBorder, lineWidth: 1))
                    Text("Scan to pay **\(name)** on Venmo")
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                        .multilineTextAlignment(.center)
                    Text(handle)
                        .font(.mlrScaled(12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.mlrVenmo)
                    Text("Venmo will show the name again before you send — double-check it matches.")
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }
}
