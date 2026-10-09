// Renders the app icon's single layer, Siphon.icon/Assets/sign.png, from the
// same SF Symbol the menu bar uses. Run from the repo root with:
//
//     swift Tools/render-icon-glyph.swift
//
// Default monochrome rendering keeps the symbol's knockout (the arrow inside
// the filled diamond) as true transparency; a .sourceIn fill then recolours
// only the opaque pixels, so the hole survives and shows the gradient behind.
// The symbol's bounds include padding: 800pt wide puts the visible diamond at
// about 62% of the 1024pt canvas, which is where Apple's own glyph icons sit.
import AppKit

let symbol = "arrow.triangle.turn.up.right.diamond.fill"
let canvasSize: CGFloat = 1024
let glyphWidth: CGFloat = 800
let output = "Siphon.icon/Assets/sign.png"

let cfg = NSImage.SymbolConfiguration(pointSize: 600, weight: .regular)
guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) else { fatalError("missing symbol \(symbol)") }
let scale = glyphWidth / sym.size.width
let drawn = NSSize(width: sym.size.width * scale, height: sym.size.height * scale)

// Draw into an explicit 1x bitmap so the result is 1024 px regardless of the
// display's backing scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasSize), pixelsHigh: Int(canvasSize),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: canvasSize, height: canvasSize)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let origin = NSPoint(x: (canvasSize - drawn.width) / 2, y: (canvasSize - drawn.height) / 2)
sym.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize).fill(using: .sourceIn)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
