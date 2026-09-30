// Prints the mean sRGB colour ("r g b", 0-255) of one region of a screenshot, so the smoke test
// can check things OCR can't read, such as which theme drew the backdrop.
//   pixels <png> <x0> <y0> <x1> <y1>      region corners as fractions of the width and height
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 6,
      let x0 = Double(args[2]), let y0 = Double(args[3]),
      let x1 = Double(args[4]), let y1 = Double(args[5]),
      x0 < x1, y0 < y1 else {
    FileHandle.standardError.write(Data("usage: pixels <png> <x0> <y0> <x1> <y1>\n".utf8))
    exit(2)
}
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB) else {
    FileHandle.standardError.write(Data("could not read \(args[1])\n".utf8))
    exit(1)
}
let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drawn else { exit(1) }

let left = max(0, Int(x0 * Double(width)))
let right = min(width, max(left + 1, Int(x1 * Double(width))))
let top = max(0, Int(y0 * Double(height)))
let bottom = min(height, max(top + 1, Int(y1 * Double(height))))
var sums = [0, 0, 0]
for y in top..<bottom {
    for x in left..<right {
        let offset = (y * width + x) * 4
        for channel in 0..<3 { sums[channel] += Int(pixels[offset + channel]) }
    }
}
let count = max(1, (right - left) * (bottom - top))
print(sums.map { String($0 / count) }.joined(separator: " "))
