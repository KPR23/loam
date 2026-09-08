#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Tile {
    let size: CGFloat
    let point: CGPoint
    let rotationDegrees: Double
}

/// Two concentric rows of rounded squares on a convex-up arc (bridge / rainbow).
func makeArcTiles(
    canvasSize: CGFloat,
    columnCount: Int,
    innerSize: CGFloat,
    outerSize: CGFloat,
    rowGap: CGFloat,
    startDegrees: Double,
    endDegrees: Double,
    centerYRatio: CGFloat
) -> [Tile] {
    let size = CGSize(width: canvasSize, height: canvasSize)
    let center = CGPoint(x: size.width / 2, y: size.height * centerYRatio)
    let sweep = startDegrees - endDegrees
    let rowPitch = (innerSize + outerSize) / 2 + rowGap
    let tileReach = outerSize * sqrt(2) / 2

    let horizontalInset = canvasSize * 0.16
    let bottomInset = canvasSize * 0.10
    let widthLimited = (size.width / 2) - horizontalInset - tileReach
    let heightLimited = center.y - bottomInset - tileReach
    let outerRadius = min(widthLimited, heightLimited)
    let innerRadius = outerRadius - rowPitch

    var tiles: [Tile] = []

    for column in 0..<columnCount {
        let t = columnCount == 1 ? 0.5 : Double(column) / Double(columnCount - 1)
        let degrees = startDegrees - sweep * t
        let angle = degrees * .pi / 180

        for row in 0..<2 {
            let tileSize = row == 1 ? outerSize : innerSize
            let radius = innerRadius + CGFloat(row) * rowPitch
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y - radius * sin(angle)
            )
            tiles.append(
                Tile(
                    size: tileSize,
                    point: point,
                    rotationDegrees: 90 - degrees
                )
            )
        }
    }

    return tiles
}

func drawRoundedSquare(
    context: CGContext,
    center: CGPoint,
    size: CGFloat,
    rotationDegrees: Double,
    cornerRatio: CGFloat,
    fill: CGColor
) {
    let half = size / 2
    let corner = max(4, size * cornerRatio)
    let rect = CGRect(x: -half, y: -half, width: size, height: size)

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: rotationDegrees * .pi / 180)

    let path = CGPath(
        roundedRect: rect,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()
    context.restoreGState()
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"

let canvas: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create graphics context\n", stderr)
    exit(1)
}

let background = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let tileColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let tiles = makeArcTiles(
    canvasSize: canvas,
    columnCount: 7,
    innerSize: 54,
    outerSize: 74,
    rowGap: 18,
    startDegrees: 204,
    endDegrees: -24,
    centerYRatio: 0.76
)

for tile in tiles {
    drawRoundedSquare(
        context: context,
        center: tile.point,
        size: tile.size,
        rotationDegrees: tile.rotationDegrees,
        cornerRatio: 0.14,
        fill: tileColor
    )
}

guard let image = context.makeImage() else {
    fputs("Failed to make image\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fputs("Failed to create image destination\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("Failed to write PNG\n", stderr)
    exit(1)
}

print("Wrote \(outputPath)")
