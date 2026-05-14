import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Encodes a pairing handshake into a `mcpocket://pair?...` URL plus a QR image.
/// The iOS app scans this URL, decodes the host/port/secret, and stores it in
/// keychain. The whole thing is self-contained — no Apple ID, no cloud.
enum PairingPayload {
    struct Payload {
        let host: String
        let port: UInt16
        let secret: String
        let nickname: String  // shown in iOS Settings to identify the paired Mac

        var url: URL {
            var comps = URLComponents()
            comps.scheme = "mcpocket"
            comps.host = "pair"
            comps.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "secret", value: secret),
                URLQueryItem(name: "nick", value: nickname),
            ]
            return comps.url!
        }
    }

    /// Best-effort hostname guess. Prefers `.local` hostname; falls back to first
    /// non-loopback IPv4. Caller may override to a Tailscale magic-DNS name.
    static func defaultHostname() -> String {
        if let h = Host.current().localizedName,
           !h.isEmpty {
            return h.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                + ".local"
        }
        for addr in Host.current().addresses where addr.contains(".") && !addr.hasPrefix("127.") {
            return addr
        }
        return "localhost"
    }

    /// Render a QR PNG suitable for showing in a SwiftUI Image view.
    static func qrImage(for payload: Payload, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let nsImage = NSImage(cgImage: cg, size: scaled.extent.size)
        return nsImage
    }
}
