#!/usr/bin/env swift
// Génère app/AppIcon.png (1024 px) : bulle de conversation et X sur fond pétrole.
// Usage : swift scripts/make-icon.swift [chemin de sortie]
// Même dessin que AppIconArt (app/Sources/DistiX/Theme.swift), sur une grille de 140 points.
import AppKit
import CoreGraphics

let size = 1024
let inset: CGFloat = 100          // marge de la grille d'icônes macOS
let artSize = CGFloat(size) - inset * 2
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/AppIcon.png"

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("contexte") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rotation(_ degrees: CGFloat, around c: CGPoint) -> CGAffineTransform {
    CGAffineTransform(translationX: c.x, y: c.y).rotated(by: degrees * .pi / 180).translatedBy(x: -c.x, y: -c.y)
}

// Repère : origine en haut à gauche, grille de 140 points.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.translateBy(x: inset, y: inset)
ctx.scaleBy(x: artSize / 140, y: artSize / 140)

let square = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 140, height: 140), cornerWidth: 32, cornerHeight: 32, transform: nil)

// Ombre portée discrète sous l'icône.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10 * artSize / 140 / 6), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(square)
ctx.setFillColor(color(0x0B5761))
ctx.fillPath()
ctx.restoreGState()

// Fond en dégradé.
ctx.saveGState()
ctx.addPath(square)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0x14808C), color(0x0B5761)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 70, y: 0), end: CGPoint(x: 70, y: 140), options: [])
ctx.restoreGState()

// Bulle et queue.
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: 28, y: 22, width: 84, height: 84))
let tail = CGMutablePath()
var tailTransform = rotation(18, around: CGPoint(x: 35.5, y: 98))
tail.move(to: CGPoint(x: 27, y: 86), transform: tailTransform)
tail.addLine(to: CGPoint(x: 44, y: 86), transform: tailTransform)
tail.addLine(to: CGPoint(x: 27, y: 110), transform: tailTransform)
tail.closeSubpath()
ctx.addPath(tail)
ctx.fillPath()

// Le X : deux barres arrondies.
for (angle, hex) in [(CGFloat(45), UInt32(0x0E6873)), (CGFloat(-45), UInt32(0x4FA3AD))] {
    var t = rotation(angle, around: CGPoint(x: 70, y: 64))
    let bar = CGPath(roundedRect: CGRect(x: 49, y: 59, width: 42, height: 10), cornerWidth: 5, cornerHeight: 5, transform: &t)
    ctx.addPath(bar)
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}
_ = tailTransform

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: output))
print("OK : \(output) (\(size) px)")
