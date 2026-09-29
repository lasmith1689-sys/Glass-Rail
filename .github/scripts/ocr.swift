// Prints the text visible in screenshots (top to bottom) so CI logs show what each screen rendered.
//   swift ocr.swift screenshot1.png screenshot2.png ...
import AppKit
import Foundation
import Vision

for path in CommandLine.arguments.dropFirst() {
    let name = URL(fileURLWithPath: path).lastPathComponent
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("===== \(name): could not load =====")
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

    // Group observations into rows by vertical position.
    var rows: [(y: Double, items: [(x: Double, text: String)])] = []
    for observation in observations {
        guard let text = observation.topCandidates(1).first?.string else { continue }
        let y = 1 - Double(observation.boundingBox.midY)
        let x = Double(observation.boundingBox.minX)
        if let index = rows.firstIndex(where: { abs($0.y - y) < 0.008 }) {
            rows[index].items.append((x, text))
        } else {
            rows.append((y, [(x, text)]))
        }
    }
    print("===== \(name) =====")
    for row in rows.sorted(by: { $0.y < $1.y }) {
        let line = row.items.sorted { $0.x < $1.x }.map(\.text).joined(separator: "  |  ")
        print(String(format: "%3.0f%%  ", row.y * 100) + line)
    }
}
