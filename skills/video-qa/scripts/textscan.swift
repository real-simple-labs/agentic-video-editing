// textscan — sample a video's frames and OCR the burned-in text with Apple Vision, keeping WHERE each line sits.
// Outputs boxes so video-qa can check the safe zone, the hook overlay and captions on any export (ASS text, PNG overlays or a human edit).
//
//   textscan <video> [--fps 4] [--min-conf 0.3] [--lang en-US]   > scan.jsonl
//
// One JSON object per sampled frame on stdout:
//   {"t": 1.25, "w": 1080, "h": 1920, "lines": [{"text": "...", "conf": 0.98, "box": [x0, y0, x1, y1]}]}
// box is in output pixels with a top-left origin. usesLanguageCorrection is OFF so misspellings stay visible.
// Build: swiftc -O textscan.swift -o textscan
import Foundation
import AVFoundation
import Vision
import CoreGraphics

func fail(_ s: String) -> Never { FileHandle.standardError.write(("textscan: " + s + "\n").data(using: .utf8)!); exit(1) }

var fps = 4.0, minConf: Float = 0.3, langs = ["en-US"], path = ""
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--fps": fps = Double(args.removeFirst()) ?? fps
    case "--min-conf": minConf = Float(args.removeFirst()) ?? minConf
    case "--lang": langs = args.removeFirst().split(separator: ",").map(String.init)
    default: if a.hasPrefix("-") { fail("unknown option \(a)") }; path = a
    }
}
if path.isEmpty { fail("usage: textscan <video> [--fps 4] [--min-conf 0.3] [--lang en-US]") }
if !FileManager.default.fileExists(atPath: path) { fail("no such file: \(path)") }

func esc(_ s: String) -> String {
    var o = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n", "\r", "\t": o += " "
        default: o.unicodeScalars.append(ch)
        }
    }
    return o
}

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

do {
    let total = CMTimeGetSeconds(try await asset.load(.duration))
    if !(total > 0) { fail("could not read duration") }
    var t = 0.0
    while t < total - 0.01 {
        let (img, actual) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
        let W = Double(img.width), H = Double(img.height)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = langs
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        var parts: [String] = []
        for obs in req.results ?? [] {
            guard let c = obs.topCandidates(1).first, c.confidence >= minConf else { continue }
            let b = obs.boundingBox   // normalised, bottom-left origin
            let x0 = Int(b.minX * W), x1 = Int(b.maxX * W), y0 = Int((1 - b.maxY) * H), y1 = Int((1 - b.minY) * H)
            parts.append("{\"text\": \"\(esc(c.string))\", \"conf\": \(String(format: "%.2f", c.confidence)), \"box\": [\(x0), \(y0), \(x1), \(y1)]}")
        }
        print("{\"t\": \(String(format: "%.3f", CMTimeGetSeconds(actual))), \"w\": \(Int(W)), \"h\": \(Int(H)), \"lines\": [\(parts.joined(separator: ", "))]}")
        t += 1.0 / fps
    }
} catch { fail("\(error)") }
