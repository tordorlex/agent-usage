import AppKit
import Foundation
import Vision

// OCR a PNG and print every recognised string with its bounding box, so layout
// problems can be diagnosed without seeing the image.

func pad(_ s: String, _ n: Int) -> String {
    let count = s.count
    return count >= n ? s : s + String(repeating: " ", count: n - count)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ocr <image.png>")
    exit(2)
}
guard let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("cannot load \(args[1])")
    exit(1)
}

let widthPt = CGFloat(cg.width) / 2
let heightPt = CGFloat(cg.height) / 2

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do {
    try handler.perform([request])
} catch {
    print("vision failed: \(error)")
    exit(1)
}

let observations = request.results ?? []
print("image \(cg.width)x\(cg.height)px = \(Int(widthPt))x\(Int(heightPt))pt — \(observations.count) text runs")
print("(y measured from the TOP of the image)\n")
print(pad("text", 32) + pad("x0", 8) + pad("x1", 8) + pad("y0", 8) + pad("y1", 8) + "conf")
print(String(repeating: "-", count: 72))

for obs in observations {
    guard let candidate = obs.topCandidates(1).first else { continue }
    let box = obs.boundingBox
    let x0 = box.minX * widthPt
    let x1 = box.maxX * widthPt
    let y0 = (1 - box.maxY) * heightPt
    let y1 = (1 - box.minY) * heightPt
    let text = candidate.string.replacingOccurrences(of: "\n", with: "⏎")
    print(pad(text, 32)
        + pad(String(format: "%.1f", x0), 8)
        + pad(String(format: "%.1f", x1), 8)
        + pad(String(format: "%.1f", y0), 8)
        + pad(String(format: "%.1f", y1), 8)
        + String(format: "%.2f", candidate.confidence))
}
