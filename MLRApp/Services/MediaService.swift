import Foundation
import UIKit
import Supabase

// MARK: - MediaService

/// Handles image resizing, upload to the Mac mini media server (preferred) or
/// Supabase Storage (fallback), and profile avatar updates.
/// Not @Observable — all methods are fire-and-return async throws.
final class MediaService {

    // Mac mini media server (Tailscale URL). Must be reachable on-device for
    // uploads to land there; falls back to Supabase Storage if unreachable.
    static let miniServerURL = "https://brians-mac-mini.tail49943c.ts.net"

    // MARK: - Post images

    /// Resize to max 1920 px, try uploading to the Mac mini first (no size cap,
    /// videos get transcoded server-side). Falls back to Supabase Storage.
    /// Returns the public URL of the stored file.
    func uploadPostImage(image: UIImage, userId: UUID) async throws -> String {
        let resized = resize(image: image, maxDimension: 1920)
        guard let data = resized.jpegData(compressionQuality: 0.8) else {
            throw MediaError.encodingFailed
        }

        // Try Mac mini — requires the device to be on Tailscale network
        if let session = try? await supabase.auth.session,
           let miniURL = try? await uploadToMini(data: data, mimeType: "image/jpeg", category: "posts", token: session.accessToken) {
            return miniURL
        }

        // Fall back to Supabase Storage
        let path = "\(userId.uuidString)/\(UUID().uuidString).jpg"
        _ = try await supabase.storage
            .from("post-photos")
            .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        return try publicURL(bucket: "post-photos", path: path)
    }

    /// Upload a post video (mp4) to the Mac mini, which transcodes server-side.
    /// Video requires the mini (no Supabase Storage fallback for size/transcode).
    func uploadPostVideo(data: Data, userId: UUID) async throws -> String {
        guard let session = try? await supabase.auth.session else {
            throw MediaError.miniServerError
        }
        return try await uploadToMini(
            data: data, mimeType: "video/mp4", category: "posts", token: session.accessToken)
    }

    // MARK: - Site images (admin-managed: logo, fest cover, …)

    /// Upload an admin-managed site image to the public `site-assets` bucket and
    /// return its public URL. A fresh filename per upload busts any CDN/AsyncImage
    /// cache so the new image shows immediately. Resized to a reasonable max.
    func uploadSiteImage(image: UIImage, key: String) async throws -> String {
        let resized = resize(image: image, maxDimension: 2048)
        guard let data = resized.jpegData(compressionQuality: 0.85) else {
            throw MediaError.encodingFailed
        }
        let path = "\(key)/\(UUID().uuidString).jpg"
        _ = try await supabase.storage
            .from("site-assets")
            .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
        return try publicURL(bucket: "site-assets", path: path)
    }

    // MARK: - Mac mini upload

    /// POST multipart/form-data to the Mac mini's /upload endpoint.
    /// Returns the public URL on success; throws on any failure so the caller
    /// can fall back to Supabase Storage.
    private func uploadToMini(data: Data, mimeType: String, category: String, token: String) async throws -> String {
        guard let url = URL(string: "\(Self.miniServerURL)/upload?category=\(category)") else {
            throw MediaError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let ext = mimeType.hasSuffix("jpeg") ? "jpg" : "mp4"
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"upload.\(ext)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MediaError.miniServerError
        }
        let json = try JSONDecoder().decode(MiniUploadResponse.self, from: responseData)
        return json.url
    }

    // MARK: - Avatars

    /// Resize to 400×400, upload to "avatars/<userId>.jpg",
    /// update profiles.avatar_url, return the public URL.
    func uploadAvatar(image: UIImage, userId: UUID) async throws -> String {
        let resized = resizeSquare(image: image, side: 400)
        guard let data = resized.jpegData(compressionQuality: 0.85) else {
            throw MediaError.encodingFailed
        }
        let path = "\(userId.uuidString).jpg"
        _ = try await supabase.storage
            .from("avatars")
            .upload(
                path,
                data: data,
                options: FileOptions(
                    contentType: "image/jpeg",
                    upsert: true           // overwrite the previous avatar
                )
            )

        let url = try publicURL(bucket: "avatars", path: path)

        // Persist the new URL on the profile row
        try await supabase
            .from("profiles")
            .update(["avatar_url": url])
            .eq("id", value: userId.uuidString)
            .execute()

        return url
    }

    // MARK: - Delete

    /// Parse the bucket and path from a Supabase Storage public URL and remove the object.
    func deleteMedia(url: String) async throws {
        guard let (bucket, path) = parseBucketAndPath(from: url) else {
            throw MediaError.invalidURL
        }
        try await supabase.storage
            .from(bucket)
            .remove(paths: [path])
    }

    // MARK: - Image helpers

    private func resize(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return redraw(image: image, to: newSize)
    }

    private func resizeSquare(image: UIImage, side: CGFloat) -> UIImage {
        // First crop to square using the shorter dimension, then scale.
        let size = image.size
        let shortest = min(size.width, size.height)
        let cropRect = CGRect(
            x: (size.width  - shortest) / 2,
            y: (size.height - shortest) / 2,
            width: shortest,
            height: shortest
        )
        // Crop
        let cropped: UIImage
        if let cgCrop = image.cgImage?.cropping(to: cropRect.applying(
            CGAffineTransform(scaleX: image.scale, y: image.scale)
        )) {
            cropped = UIImage(cgImage: cgCrop, scale: image.scale, orientation: image.imageOrientation)
        } else {
            cropped = image
        }
        return redraw(image: cropped, to: CGSize(width: side, height: side))
    }

    private func redraw(image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - URL helpers

    /// Build the public URL from the Supabase project URL + bucket + path.
    private func publicURL(bucket: String, path: String) throws -> String {
        try supabase.storage.from(bucket).getPublicURL(path: path).absoluteString
    }

    /// Extract bucket and object path from a Supabase Storage public URL.
    /// URL pattern: …/storage/v1/object/public/<bucket>/<path>
    private func parseBucketAndPath(from urlString: String) -> (bucket: String, path: String)? {
        guard let url = URL(string: urlString) else { return nil }
        let components = url.pathComponents
        // Find "public" marker in path
        guard let publicIdx = components.firstIndex(of: "public"),
              components.count > publicIdx + 2
        else { return nil }
        let bucket = components[publicIdx + 1]
        let path   = components[(publicIdx + 2)...].joined(separator: "/")
        return (bucket, path)
    }
}

// MARK: - Errors

enum MediaError: LocalizedError {
    case encodingFailed
    case invalidURL
    case miniServerError

    var errorDescription: String? {
        switch self {
        case .encodingFailed:  return "Couldn't process the image. Please try a different photo."
        case .invalidURL:      return "The media URL is not valid."
        case .miniServerError: return "Couldn't reach the media server. Check your Tailscale connection."
        }
    }
}

// MARK: - Response types

private struct MiniUploadResponse: Decodable {
    let url: String
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
