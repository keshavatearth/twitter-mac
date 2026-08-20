#!/usr/bin/env swift
//
//  make_icon.swift
//  Renders the TwitterMac icon — a filter funnel on an X-blue badge — and writes
//  AppIcon.iconset next to Resources/. build_app.sh turns that into AppIcon.icns.
//
//  Run:  swift scripts/make_icon.swift
//  Deterministic: no fonts, no randomness, same pixels every run.
//
import AppKit

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let blueTop = srgb(0x36A9F5)
let blueBottom = srgb(0x0B6FA8)
let cream = srgb(0xF7F9F9)

let canvas: CGFloat = 1024
let badgeSide: CGFloat = 824
let badgeRect = CGRect(
    x: (canvas - badgeSide) / 2,
    y: (canvas - badgeSide) / 2,
    width: badgeSide,
    height: badgeSide
)
let cornerRadius: CGFloat = 185

func makeContext(_ px: Int) -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil, width: px, height: px,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { fatalError("could not create CGContext (\(px)px)") }
    return ctx
}

func pngData(_ image: CGImage) -> Data {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return data
}

/// Funnel: wide mouth, tapering neck, narrow stem, two drips falling out the bottom.
func funnelPath() -> CGPath {
    let path = CGMutablePath()
    let mouthY: CGFloat = 706
    let neckY: CGFloat = 468
    let stemBottomY: CGFloat = 322
    let halfMouth: CGFloat = 224
    let halfStem: CGFloat = 52
    let cx = canvas / 2

    path.move(to: CGPoint(x: cx - halfMouth, y: mouthY))
    path.addLine(to: CGPoint(x: cx + halfMouth, y: mouthY))
    path.addLine(to: CGPoint(x: cx + halfStem, y: neckY))
    path.addLine(to: CGPoint(x: cx + halfStem, y: stemBottomY))
    path.addLine(to: CGPoint(x: cx - halfStem, y: stemBottomY))
    path.addLine(to: CGPoint(x: cx - halfStem, y: neckY))
    path.closeSubpath()
    return path
}

func renderMaster() -> CGImage {
    let ctx = makeContext(Int(canvas))
    let badgePath = CGPath(
        roundedRect: badgeRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Badge: vertical X-blue gradient.
    ctx.saveGState()
    ctx.addPath(badgePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [blueTop, blueBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvas / 2, y: badgeRect.maxY),
        end: CGPoint(x: canvas / 2, y: badgeRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Funnel + two drips.
    ctx.saveGState()
    ctx.addPath(badgePath)
    ctx.clip()
    ctx.setFillColor(cream)
    ctx.addPath(funnelPath())
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: canvas / 2 - 34, y: 216, width: 68, height: 68))
    ctx.setFillColor(cream.copy(alpha: 0.55)!)
    ctx.fillEllipse(in: CGRect(x: canvas / 2 - 20, y: 130, width: 40, height: 40))
    ctx.restoreGState()

    // 1px inner highlight along the top edge, for a little depth.
    ctx.saveGState()
    ctx.addPath(badgePath)
    ctx.clip()
    ctx.clip(to: CGRect(x: 0, y: badgeRect.maxY - 230, width: canvas, height: 230))
    ctx.addPath(CGPath(
        roundedRect: badgeRect.insetBy(dx: 0.5, dy: 0.5),
        cornerWidth: cornerRadius - 0.5,
        cornerHeight: cornerRadius - 0.5,
        transform: nil
    ))
    ctx.setStrokeColor(cream.copy(alpha: 0.32)!)
    ctx.setLineWidth(1)
    ctx.strokePath()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("makeImage failed") }
    return image
}

func resized(_ master: CGImage, to px: Int) -> CGImage {
    if px == master.width { return master }
    let ctx = makeContext(px)
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let image = ctx.makeImage() else { fatalError("resize to \(px)px failed") }
    return image
}

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetURL = projectRoot.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let master = renderMaster()
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
var cache: [Int: Data] = [:]
for (name, px) in entries {
    let data = cache[px] ?? pngData(resized(master, to: px))
    cache[px] = data
    try data.write(to: iconsetURL.appendingPathComponent(name))
}
print("wrote \(iconsetURL.path)")
