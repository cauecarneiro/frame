import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Escrita de imagens em disco e na área de transferência.
enum ImageExport {

    /// Codifica um `CGImage` no formato pedido.
    static func encode(_ image: CGImage, format: ImageFormat, jpegQuality: Double = 0.9) throws -> Data {
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        }

        if format == .pdf { return try encodePDF(image) }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else {
            throw ExportError.encodingFailed(format.displayName)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImagePropertyDPIWidth: 144,
            kCGImagePropertyDPIHeight: 144,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed(format.displayName)
        }
        return data as Data
    }

    private static func encodePDF(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw ExportError.encodingFailed("PDF") }

        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Grava no diretório escolhido, resolvendo colisões com um sufixo.
    @discardableResult
    static func write(
        _ image: CGImage,
        to directory: URL,
        filename: String,
        format: ImageFormat,
        jpegQuality: Double = 0.9
    ) throws -> URL {
        let data = try encode(image, format: format, jpegQuality: jpegQuality)
        let url = uniqueURL(in: directory, filename: filename, fileExtension: format.fileExtension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Acha um nome livre acrescentando ` 2`, ` 3`… ao final.
    static func uniqueURL(in directory: URL, filename: String, fileExtension: String) -> URL {
        var candidate = directory.appending(path: "\(filename).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(filename) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    /// Coloca a imagem na área de transferência como PNG e TIFF, para que
    /// tanto apps modernos quanto legados consigam colar.
    static func copyToPasteboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)

        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }

    static func copyToPasteboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Lê uma imagem da área de transferência, se houver.
    static func imageFromPasteboard() -> CGImage? {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage],
              let first = image.first
        else { return nil }
        return first.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    enum ExportError: LocalizedError {
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let format):
                String(localized: "Não foi possível codificar a imagem em \(format).")
            }
        }
    }
}

extension CGImage {
    var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// Envolve num `NSImage` com o tamanho lógico correto, assumindo 2×.
    func nsImage(scale: CGFloat = 2) -> NSImage {
        NSImage(cgImage: self, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}
