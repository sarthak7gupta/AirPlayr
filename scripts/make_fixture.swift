import Foundation
import AVFoundation
import CoreVideo

// Synthetic, silent H.264 video: no user media is read.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/airplayr-fixture.mp4")
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
writer.add(input)
guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Fixture", code: 1) }
writer.startSession(atSourceTime: .zero)
let frameCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 900 : 900
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
    var optional: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else { fatalError("Cannot allocate test frame") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<360 { for x in 0..<640 {
            let i = y * stride + x * 4
            bytes[i] = 255; bytes[i+1] = UInt8(frame / 4 % 255); bytes[i+2] = UInt8(x * 255 / 640); bytes[i+3] = UInt8(y * 255 / 360)
        } }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? NSError(domain: "Fixture", code: 2) }
}
input.markAsFinished()
await writer.finishWriting()
guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Fixture", code: 3) }
print(output.path)
