import Foundation
import UIKit

/// Sends a photo to storage and returns its key.
protocol PhotoUploading: Sendable {
    func uploadProfilePhoto(_ jpeg: Data) async throws -> String
    func uploadListingPhoto(_ jpeg: Data) async throws -> String
}

/// Asks the server for a short-lived upload link, then PUTs the photo straight
/// to storage. The server never handles the photo's bytes.
struct PhotoUploader: PhotoUploading {
    let api: AccountAPI
    let session: URLSession

    static let failureMessage = "Couldn't upload the photo. You can add one later."

    func uploadProfilePhoto(_ jpeg: Data) async throws -> String {
        try await upload(jpeg, to: api.presignProfilePhoto(contentType: "image/jpeg"))
    }

    func uploadListingPhoto(_ jpeg: Data) async throws -> String {
        try await upload(jpeg, to: api.presignListingPhoto(contentType: "image/jpeg"))
    }

    private func upload(_ jpeg: Data, to link: PresignedUpload) async throws -> String {
        guard jpeg.count <= link.maxBytes, let url = URL(string: link.uploadUrl) else {
            throw APIError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = link.method
        for (name, value) in link.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.upload(for: request, from: jpeg)
        } catch {
            // Storage could not be reached. The profile itself is unaffected.
            throw APIError.unreachable
        }
        guard let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.server(
                status: status,
                code: "upload_failed",
                message: Self.failureMessage,
                fields: []
            )
        }
        return link.key
    }
}

enum ImageResizer {
    /// Shrinks a photo so its longest side is at most `maxDimension` points and
    /// returns it as JPEG. Returns nil if `data` is not an image.
    static func jpegData(from data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let size = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
