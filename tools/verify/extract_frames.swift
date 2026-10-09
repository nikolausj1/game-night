// Fallback frame extractor when ffmpeg is missing.
//   swift tools/verify/extract_frames.swift <video.mp4> <outDir> <N>
// Writes frame_01.png ... frame_NN.png, evenly spaced across the clip.
import AVFoundation
import AppKit

let a = CommandLine.arguments
guard a.count == 4, let n = Int(a[3]), n > 0 else { print("usage: extract_frames <video> <outDir> <N>"); exit(2) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let dur = CMTimeGetSeconds(asset.duration)
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
for i in 0..<n {
    let t = n == 1 ? 0 : dur * 0.98 * Double(i) / Double(n - 1)
    do {
        let cg = try gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cg)
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: String(format: "%@/frame_%02d.png", a[2], i + 1)))
    } catch { FileHandle.standardError.write("frame \(i) failed: \(error)\n".data(using: .utf8)!) }
}
