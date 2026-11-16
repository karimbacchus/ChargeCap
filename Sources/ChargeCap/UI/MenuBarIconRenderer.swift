//
// MenuBarIconRenderer.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import SwiftUI

@MainActor
public enum MenuBarIconRenderer {
    public static func readoutText(
        snapshot: BatterySnapshot,
        prefs: Prefs
    ) -> String {
        switch prefs.menuBarReadoutMode {
        case .percentage:
            return "\(snapshot.osPercentage)%"
        case .hardwarePercentage:
            return String(format: "%.0f%%", snapshot.hardwarePercentage)
        case .powerWatts:
            let netW = snapshot.isPluggedIn ? snapshot.systemLoadWatts : abs(snapshot.batteryPowerWatts)
            return String(format: "%.0fW", netW)
        case .temperature:
            return prefs.formatTemperature(snapshot.batteryTemperatureC)
        case .percentAndPower:
            let netW = snapshot.isPluggedIn ? snapshot.systemLoadWatts : abs(snapshot.batteryPowerWatts)
            return String(format: "%d%% · %.0fW", snapshot.osPercentage, netW)
        case .none:
            return ""
        }
    }

    public static func renderStatusBarImage(
        snapshot: BatterySnapshot,
        mode: OperatingMode,
        prefs: Prefs
    ) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)

            let pct = CGFloat(min(100, max(0, snapshot.osPercentage))) / 100.0
            let limitPct = CGFloat(min(100, max(10, prefs.chargeLimit))) / 100.0

            switch prefs.menuBarIconStyle {
            case .ringGauge:
                drawRingGauge(ctx: ctx, rect: rect, pct: pct, limitPct: limitPct, mode: mode)
            case .batteryCapsule:
                drawBatteryCapsule(ctx: ctx, rect: rect, pct: pct, limitPct: limitPct, mode: mode)
            case .minimalBolt, .textOnly:
                drawMinimalSymbol(ctx: ctx, rect: rect, mode: mode)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawRingGauge(
        ctx: CGContext,
        rect: NSRect,
        pct: CGFloat,
        limitPct: CGFloat,
        mode: OperatingMode
    ) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 7.0
        let lineWidth: CGFloat = 2.1

        // Background track ring
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // Active battery progress arc (starts at top = pi/2, goes clockwise)
        let startAngle: CGFloat = .pi / 2
        let endAngle: CGFloat = startAngle - (.pi * 2 * pct)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        // Charge limit tick mark on outer rim
        let limitAngle: CGFloat = startAngle - (.pi * 2 * limitPct)
        let innerTick = CGPoint(
            x: center.x + cos(limitAngle) * (radius - 2.3),
            y: center.y + sin(limitAngle) * (radius - 2.3)
        )
        let outerTick = CGPoint(
            x: center.x + cos(limitAngle) * (radius + 2.3),
            y: center.y + sin(limitAngle) * (radius + 2.3)
        )
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.3)
        ctx.move(to: innerTick)
        ctx.addLine(to: outerTick)
        ctx.strokePath()
        ctx.restoreGState()

        // Center glyph indicating mode
        drawCenterGlyph(ctx: ctx, center: center, mode: mode)
    }

    private static func drawBatteryCapsule(
        ctx: CGContext,
        rect: NSRect,
        pct: CGFloat,
        limitPct: CGFloat,
        mode: OperatingMode
    ) {
        let bodyRect = CGRect(x: 1.5, y: 4.0, width: 14.5, height: 10.0)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
        bodyPath.lineWidth = 1.4
        NSColor.labelColor.setStroke()
        bodyPath.stroke()

        // Battery terminal nub
        let nubRect = CGRect(x: 16.8, y: 6.8, width: 1.6, height: 4.4)
        let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: 0.8, yRadius: 0.8)
        NSColor.labelColor.setFill()
        nubPath.fill()

        // Fill level
        let insetRect = bodyRect.insetBy(dx: 2.0, dy: 2.0)
        let fillRect = CGRect(
            x: insetRect.minX,
            y: insetRect.minY,
            width: max(1.5, insetRect.width * pct),
            height: insetRect.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.2, yRadius: 1.2)
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        fillPath.fill()

        // Limit line inside battery
        let limitX = insetRect.minX + insetRect.width * limitPct
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: limitX, y: bodyRect.minY - 1.2))
        ctx.addLine(to: CGPoint(x: limitX, y: bodyRect.maxY + 1.2))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawMinimalSymbol(ctx: CGContext, rect: NSRect, mode: OperatingMode) {
        drawCenterGlyph(ctx: ctx, center: CGPoint(x: rect.midX, y: rect.midY), mode: mode, scale: 1.4)
    }

    private static func drawCenterGlyph(
        ctx: CGContext,
        center: CGPoint,
        mode: OperatingMode,
        scale: CGFloat = 1.0
    ) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.setStrokeColor(NSColor.labelColor.cgColor)

        switch mode {
        case .chargingToLimit, .topUp:
            // Lightning bolt
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + 0.8 * scale, y: center.y + 3.6 * scale))
            path.addLine(to: CGPoint(x: center.x - 2.2 * scale, y: center.y - 0.3 * scale))
            path.addLine(to: CGPoint(x: center.x + 0.1 * scale, y: center.y - 0.3 * scale))
            path.addLine(to: CGPoint(x: center.x - 0.8 * scale, y: center.y - 3.6 * scale))
            path.addLine(to: CGPoint(x: center.x + 2.2 * scale, y: center.y + 0.3 * scale))
            path.addLine(to: CGPoint(x: center.x - 0.1 * scale, y: center.y + 0.3 * scale))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()

        case .discharging:
            // Down arrow
            ctx.setLineWidth(1.4 * scale)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: center.x, y: center.y + 2.8 * scale))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y - 2.4 * scale))
            ctx.move(to: CGPoint(x: center.x - 2.1 * scale, y: center.y - 0.5 * scale))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y - 2.6 * scale))
            ctx.addLine(to: CGPoint(x: center.x + 2.1 * scale, y: center.y - 0.5 * scale))
            ctx.strokePath()

        case .holdingAtLimit, .sailing:
            // Pause / shield bars
            let barW = 1.2 * scale
            let barH = 4.6 * scale
            ctx.fill(CGRect(x: center.x - 1.9 * scale, y: center.y - barH / 2, width: barW, height: barH))
            ctx.fill(CGRect(x: center.x + 0.7 * scale, y: center.y - barH / 2, width: barW, height: barH))

        case .heatProtectionPaused:
            // Exclamation / thermal dot
            ctx.fill(CGRect(x: center.x - 0.7 * scale, y: center.y - 0.5 * scale, width: 1.4 * scale, height: 3.4 * scale))
            ctx.fillEllipse(in: CGRect(x: center.x - 0.8 * scale, y: center.y - 2.8 * scale, width: 1.6 * scale, height: 1.6 * scale))

        case .calibrating:
            // Sync dot
            ctx.fillEllipse(in: CGRect(x: center.x - 1.8 * scale, y: center.y - 1.8 * scale, width: 3.6 * scale, height: 3.6 * scale))

        case .onBattery, .sleepingPaused:
            ctx.fillEllipse(in: CGRect(x: center.x - 1.4 * scale, y: center.y - 1.4 * scale, width: 2.8 * scale, height: 2.8 * scale))
        }
        ctx.restoreGState()
    }
}
