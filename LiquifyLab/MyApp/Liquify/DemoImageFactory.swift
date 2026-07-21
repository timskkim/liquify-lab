import UIKit

/// Produces demo artwork so the interaction is useful immediately after launch
enum DemoImageFactory {
    static func makeImage() -> UIImage {
        let size = CGSize(width: 1600, height: 1100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let colors = [
                UIColor(red: 0.08, green: 0.11, blue: 0.19, alpha: 1).cgColor,
                UIColor(red: 0.24, green: 0.13, blue: 0.31, alpha: 1).cgColor,
                UIColor(red: 0.06, green: 0.35, blue: 0.36, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.52, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            context.setBlendMode(.screen)
            for index in 0..<9 {
                let diameter = CGFloat(130 + index * 34)
                let x = CGFloat(120 + index * 155)
                let y = CGFloat(120 + (index % 3) * 270)
                context.setFillColor(UIColor(
                    hue: CGFloat(index) / 12 + 0.43,
                    saturation: 0.7,
                    brightness: 0.95,
                    alpha: 0.16
                ).cgColor)
                context.fillEllipse(in: CGRect(x: x, y: y, width: diameter, height: diameter))
            }
            context.setBlendMode(.normal)

            context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(3)
            for offsetValue in stride(from: -300, through: 1700, by: 92) {
                let offset = CGFloat(offsetValue)
                context.move(to: CGPoint(x: offset, y: 0))
                context.addCurve(
                    to: CGPoint(x: offset + 240, y: size.height),
                    control1: CGPoint(x: offset + 420, y: 300),
                    control2: CGPoint(x: offset - 220, y: 760)
                )
            }
            context.strokePath()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 112, weight: .black),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .kern: 9,
                .paragraphStyle: paragraph
            ]
            NSString(string: "FLOW\nSTUDY 01").draw(
                in: CGRect(x: 150, y: 365, width: 1300, height: 300),
                withAttributes: attributes
            )

            let captionAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.54),
                .kern: 4,
                .paragraphStyle: paragraph
            ]
            NSString(string: "DRAG WITH PENCIL TO DEFORM").draw(
                in: CGRect(x: 200, y: 760, width: 1200, height: 50),
                withAttributes: captionAttributes
            )
        }
    }
}
