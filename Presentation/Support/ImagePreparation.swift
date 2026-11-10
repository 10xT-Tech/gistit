//
//  ImagePreparation.swift
//  EnglishHelper — Presentation
//
//  Every photo sent to the model (See it, Caught → From photos) is downscaled and re-encoded first.
//

import UIKit

enum ImagePreparation {
    /// Downscale (max 1536px) and re-encode to JPEG on a background task: keeps the upload small, in a
    /// format Claude accepts, and never hitches the main thread. Nil if the data isn't a decodable image.
    static func prepare(_ data: Data) async -> Data? {
        await Task.detached { prepareSync(data) }.value
    }

    nonisolated static func prepareSync(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 1536
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered: UIImage = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
              }
            : image
        return rendered.jpegData(compressionQuality: 0.8)
    }
}
