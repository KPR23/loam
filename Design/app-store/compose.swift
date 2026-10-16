import SwiftUI
import AppKit

// App Store 6.9" canvas.
let W: CGFloat = 1320, H: CGFloat = 2868

let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
let muted = Color(red: 0.42, green: 0.42, blue: 0.44)
let canvas = Color(red: 0.949, green: 0.949, blue: 0.969)

// Category colors from Loam/Core/Category.swift, used for the brand tile arc.
let tileColors: [Color] = [
    Color(red: 0.88, green: 0.45, blue: 0.18), Color(red: 0.98, green: 0.24, blue: 0.58),
    Color(red: 102/255, green: 194/255, blue: 64/255), Color(red: 0.15, green: 0.50, blue: 0.98),
    Color(red: 0.96, green: 0.68, blue: 0.18), Color(red: 0.96, green: 0.40, blue: 0.32),
    Color(red: 0.68, green: 0.24, blue: 0.96), Color(red: 0.12, green: 0.78, blue: 0.88),
]

struct Shot { let file: String; let title: String; let subtitle: String; let accent: Int }

let shots = [
    Shot(file: "01-home", title: "See what you\nreally spent", subtitle: "Your month at a glance, including your share of everything you split", accent: 0),
    Shot(file: "02-add", title: "Add an expense\nin seconds", subtitle: "Amount, category, done", accent: 5),
    Shot(file: "03-detail", title: "Split bills,\nfairly", subtitle: "Equally, by percentage or exact amounts", accent: 1),
    Shot(file: "tab-Balances", title: "Always know\nwho owes whom", subtitle: "Balances per person, settled with a tap", accent: 3),
    Shot(file: "tab-Activity", title: "Nothing counts\nuntil they accept", subtitle: "Every split, change and repayment in one place", accent: 2),
]

/// A small arc of rounded tiles echoing the app icon and the Home spend arc.
struct TileArc: View {
    let accent: Int
    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height)
            let count = 9
            for i in 0..<count {
                let t = Double(i) / Double(count - 1)
                let angle = Double.pi * (1 - t)
                let r: CGFloat = size.height - 22
                let p = CGPoint(x: center.x + r * cos(angle), y: center.y - r * sin(angle))
                let s: CGFloat = 30
                var tile = Path(roundedRect: CGRect(x: -s/2, y: -s/2, width: s, height: s), cornerRadius: 8)
                tile = tile.applying(CGAffineTransform(rotationAngle: .pi / 2 - angle))
                    .applying(CGAffineTransform(translationX: p.x, y: p.y))
                let color = tileColors[(accent + i / 3) % tileColors.count]
                ctx.fill(tile, with: .color(color))
            }
        }
        .frame(width: 220, height: 120)
    }
}

struct Frame: View {
    let shot: Shot
    let image: NSImage
    var body: some View {
        let phoneW: CGFloat = 940
        let phoneH = phoneW * H / W
        let bezel: CGFloat = 22
        let screenRadius: CGFloat = 120
        ZStack(alignment: .top) {
            canvas
            // Soft wash of the accent behind the device.
            Circle()
                .fill(tileColors[shot.accent].opacity(0.16))
                .frame(width: 1500, height: 1500)
                .blur(radius: 160)
                .offset(y: 1500)
            VStack(spacing: 0) {
                TileArc(accent: shot.accent)
                    .padding(.top, 120)
                Text(shot.title)
                    .font(.system(size: 100, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-6)
                    .padding(.top, 34)
                Text(shot.subtitle)
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .foregroundStyle(muted)
                    .multilineTextAlignment(.center)
                    .frame(width: 1060)
                    .padding(.top, 28)
                Spacer(minLength: 0)
            }
            Image(nsImage: image)
                .resizable()
                .frame(width: phoneW, height: phoneH)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                .padding(bezel)
                .background(
                    RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 3)
                )
                .shadow(color: .black.opacity(0.16), radius: 60, y: 30)
                .offset(y: 756)
        }
        .frame(width: W, height: H)
        .clipped()
    }
}

@MainActor func render() {
    let dir = "/tmp/loam-shots"
    let out = "\(dir)/final"
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for (index, shot) in shots.enumerated() {
        guard let image = NSImage(contentsOfFile: "\(dir)/keep/\(shot.file).png") else { fatalError(shot.file) }
        let renderer = ImageRenderer(content: Frame(shot: shot, image: image))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("render") }
        // Flatten to opaque RGB: App Store Connect rejects screenshots with alpha.
        let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let data = rep.representation(using: .png, properties: [:])!
        let path = "\(out)/\(index + 1)-\(shot.file).png"
        try! data.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

MainActor.assumeIsolated { render() }
