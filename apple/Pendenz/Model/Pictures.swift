import Foundation
import ImageIO
import UniformTypeIdentifiers

// Pictures: scaled for sending, and drawn small for a thumbnail. Their files are kept as any other
// file (`AttachmentFiles`).
nonisolated enum Pictures {
    // The long side of a photo as it is sent.
    static let sentSize = 2048
    // The name a photo is sent under. It is shown where a picture is shared.
    static let sentName = "Image.jpg"

    // The image as it is sent: at most 2048 pixels on its long side, upright, as a JPEG. The
    // copy is drawn anew, so nothing of the original's EXIF data, such as the place it was
    // taken at, travels with it.
    @concurrent
    static func scaled(_ data: Data) async -> (jpeg: Data, width: Int, height: Int)? {
        guard let picture = downsampled(CGImageSourceCreateWithData(data as CFData, nil), to: sentSize) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, picture, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, picture.width, picture.height)
    }

    // A small picture of a file for a thumbnail, without reading the whole image into memory.
    @concurrent
    static func thumbnail(of file: URL, side: Int) async -> CGImage? {
        downsampled(CGImageSourceCreateWithURL(file as CFURL, nil), to: side)
    }

    private static func downsampled(_ source: CGImageSource?, to side: Int) -> CGImage? {
        guard let source else { return nil }
        let options = [
            // From the image itself, never from a preview embedded in the file.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Turned upright, as the orientation in the file says.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
