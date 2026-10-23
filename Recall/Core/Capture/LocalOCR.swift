import Foundation
import ImageIO
import Vision

/// Local, on-device OCR using Apple's Vision framework.
/// Runs on the Neural Engine / GPU, completely offline, zero extra download size.
enum LocalOCR {
    /// Extracts text from image data (PNG, TIFF, JPEG). Supports Russian and English.
    static func extractText(from imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return ""
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]

        do {
            try requestHandler.perform([request])
            guard let observations = request.results else { return "" }
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            return recognizedStrings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}
