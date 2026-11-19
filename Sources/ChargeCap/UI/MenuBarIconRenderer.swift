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
    // MARK: - Readout

    public static func readoutText(snapshot: BatterySnapshot, prefs: Prefs) -> String {
        readoutText(snapshot: snapshot, prefs: prefs, mode: prefs.menuBarReadoutMode)
    }

    public static func readoutText(snapshot: BatterySnapshot, prefs: Prefs, mode: MenuBarReadoutMode) -> String {
        let netW = snapshot.isPluggedIn ? snapshot.systemLoadWatts : abs(snapshot.batteryPowerWatts)
        switch mode {
        case .percentage:
            return "\(snapshot.osPercentage)%"
        case .hardwarePercentage:
            return String(format: "%.0f%%", snapshot.hardwarePercentage)
        case .powerWatts:
            return String(format: "%.0fW", netW)
        case .temperature:
            return prefs.formatTemperature(snapshot.batteryTemperatureC)
        case .percentAndPower:
            return String(format: "%d%% · %.0fW", snapshot.osPercentage, netW)
        case .timeRemaining:
            guard let minutes = snapshot.timeRemainingMinutes, minutes > 0, minutes < 24 * 60 else { return "--:--" }
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        case .health:
            return String(format: "%.0f%%", snapshot.healthPercentage)
        case .cycles:
            return "\(snapshot.cycleCount) cycles"
        case .none:
            return ""
        }
    }

    // MARK: - Image

    /// Renders the status item image. Always a template image (adapts to the menu bar appearance),
    /// except when Low Power Mode tinting applies, in which case it is a yellow, non-template image.
    public static func renderStatusBarImage(
        snapshot: BatterySnapshot,
        mode: OperatingMode,
        prefs: Prefs,
        style: MenuBarIconStyle? = nil
    ) -> NSImage {
        let style = style ?? prefs.menuBarIconStyle
        let pct = CGFloat(min(100, max(0, snapshot.osPercentage))) / 100.0
        let limitPct = CGFloat(min(100, max(10, prefs.chargeLimit))) / 100.0

        let base: NSImage
        switch style {
        case .liveStatus:
            base = liveStatusImage(snapshot: snapshot, mode: mode)
        default:
            let width: CGFloat = style == .macOSBattery ? 28 : (style == .batteryCapsule ? 21 : 18)
            let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.setShouldAntialias(true)
                switch style {
                case .ringGauge:
                    drawRingGauge(ctx: ctx, rect: rect, pct: pct, limitPct: limitPct, mode: mode)
                case .batteryCapsule:
                    drawBatteryCapsule(ctx: ctx, pct: pct, limitPct: limitPct)
                case .macOSBattery:
                    drawMacOSBattery(ctx: ctx, rect: rect, pct: pct, limitPct: limitPct, mode: mode, plugged: snapshot.isPluggedIn)
                case .minimalBolt, .textOnly, .liveStatus:
                    drawCenterGlyph(ctx: ctx, center: CGPoint(x: rect.midX, y: rect.midY), mode: mode, scale: 1.35)
                }
                return true
            }
            image.isTemplate = true
            base = image
        }

        if prefs.menuBarLowPowerTint && snapshot.isLowPowerModeEnabled {
            return tinted(base, color: .systemYellow)
        }
        return base
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        result.isTemplate = false
        return result
    }

    // MARK: - Live status

    public static func liveStatusSymbol(snapshot: BatterySnapshot, mode: OperatingMode) -> String {
        switch mode {
        case .chargingToLimit, .topUp: return "bolt.fill"
        case .holdingAtLimit: return "pause.fill"
        case .sailing: return "sailboat.fill"
        case .discharging: return "arrow.down"
        case .heatProtectionPaused: return "thermometer.high"
        case .calibrating: return "arrow.triangle.2.circlepath"
        case .sleepingPaused: return "moon.fill"
        case .onBattery:
            switch snapshot.osPercentage {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }

    private static func liveStatusImage(snapshot: BatterySnapshot, mode: OperatingMode) -> NSImage {
        let name = liveStatusSymbol(snapshot: snapshot, mode: mode)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: mode.badgeText)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        symbol.isTemplate = true
        return symbol
    }

    // MARK: - Drawing

    private static let ink = NSColor.black

    private static func drawRingGauge(ctx: CGContext, rect: NSRect, pct: CGFloat, limitPct: CGFloat, mode: OperatingMode) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 6.6
        let lineWidth: CGFloat = 2.0

        ctx.saveGState()
        ctx.setStrokeColor(ink.withAlphaComponent(0.26).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        let startAngle: CGFloat = .pi / 2
        let clampedPct = min(0.999, max(0.02, pct))
        let endAngle: CGFloat = startAngle - (.pi * 2 * clampedPct)
        ctx.saveGState()
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(pct >= 0.99 ? .butt : .round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        if limitPct < 0.99 {
            let limitAngle: CGFloat = startAngle - (.pi * 2 * limitPct)
            let inner = CGPoint(x: center.x + cos(limitAngle) * (radius - 1.5), y: center.y + sin(limitAngle) * (radius - 1.5))
            let outer = CGPoint(x: center.x + cos(limitAngle) * (radius + 1.5), y: center.y + sin(limitAngle) * (radius + 1.5))
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.8)
            ctx.move(to: inner)
            ctx.addLine(to: outer)
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawCenterGlyph(ctx: ctx, center: center, mode: mode, scale: 0.92)
    }

    private static func drawBatteryCapsule(ctx: CGContext, pct: CGFloat, limitPct: CGFloat) {
        let bodyRect = CGRect(x: 1.5, y: 4.2, width: 15.5, height: 9.6)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.5, yRadius: 2.5)
        bodyPath.lineWidth = 1.35
        ink.setStroke()
        bodyPath.stroke()

        ink.setFill()
        NSBezierPath(roundedRect: CGRect(x: 17.8, y: 6.8, width: 1.6, height: 4.4), xRadius: 0.8, yRadius: 0.8).fill()

        let insetRect = bodyRect.insetBy(dx: 1.9, dy: 1.9)
        let fillRect = CGRect(x: insetRect.minX, y: insetRect.minY, width: max(1.5, insetRect.width * pct), height: insetRect.height)
        ink.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.2, yRadius: 1.2).fill()

        if limitPct < 0.99 {
            let limitX = insetRect.minX + insetRect.width * limitPct
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: limitX, y: insetRect.minY - 0.5))
            ctx.addLine(to: CGPoint(x: limitX, y: insetRect.maxY + 0.5))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Faithful macOS-style battery: dim outline, solid fill, knocked-out bolt when charging, limit tick.
    private static func drawMacOSBattery(ctx: CGContext, rect: NSRect, pct: CGFloat, limitPct: CGFloat, mode: OperatingMode, plugged: Bool) {
        let body = CGRect(x: 1.5, y: 3.75, width: 22, height: 10.5)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.2, yRadius: 3.2)
        outline.lineWidth = 1.0
        ink.withAlphaComponent(0.45).setStroke()
        outline.stroke()

        // Terminal cap.
        ink.withAlphaComponent(0.45).setFill()
        let cap = NSBezierPath()
        cap.appendArc(withCenter: CGPoint(x: 24.2, y: 9), radius: 2.2, startAngle: -50, endAngle: 50)
        cap.line(to: CGPoint(x: 24.2, y: 9))
        cap.close()
        cap.fill()

        // Fill.
        let inner = body.insetBy(dx: 2.0, dy: 2.0)
        let fillW = max(2.0, inner.width * pct)
        ink.setFill()
        NSBezierPath(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height), xRadius: 1.6, yRadius: 1.6).fill()

        // Limit tick: small notch cut just below the outline's inner edge.
        if limitPct < 0.99 {
            let x = inner.minX + inner.width * limitPct
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.1)
            ctx.move(to: CGPoint(x: x, y: inner.minY - 0.2))
            ctx.addLine(to: CGPoint(x: x, y: inner.maxY + 0.2))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Bolt overlay while charging (or on adapter and charging toward a target).
        let charging: Bool
        switch mode {
        case .chargingToLimit, .topUp: charging = true
        case .calibrating(let phase): charging = (phase == .chargeToFullFirst || phase == .chargeToFullSecond)
        default: charging = false
        }
        if charging {
            let path = boltPath(center: CGPoint(x: body.midX, y: body.midY), scale: 1.25)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setFillColor(ink.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private static func boltPath(center: CGPoint, scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x + 0.7 * scale, y: center.y + 3.5 * scale))
        path.addLine(to: CGPoint(x: center.x - 2.1 * scale, y: center.y - 0.2 * scale))
        path.addLine(to: CGPoint(x: center.x + 0.1 * scale, y: center.y - 0.2 * scale))
        path.addLine(to: CGPoint(x: center.x - 0.7 * scale, y: center.y - 3.5 * scale))
        path.addLine(to: CGPoint(x: center.x + 2.1 * scale, y: center.y + 0.2 * scale))
        path.addLine(to: CGPoint(x: center.x - 0.1 * scale, y: center.y + 0.2 * scale))
        path.closeSubpath()
        return path
    }

    private static func drawCenterGlyph(ctx: CGContext, center: CGPoint, mode: OperatingMode, scale: CGFloat = 1.0) {
        ctx.saveGState()
        ctx.setFillColor(ink.cgColor)
        ctx.setStrokeColor(ink.cgColor)

        switch mode {
        case .chargingToLimit, .topUp:
            ctx.addPath(boltPath(center: center, scale: scale))
            ctx.fillPath()

        case .discharging:
            ctx.setLineWidth(1.4 * scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: center.x, y: center.y + 2.6 * scale))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y - 2.2 * scale))
            ctx.move(to: CGPoint(x: center.x - 2.0 * scale, y: center.y - 0.4 * scale))
            ctx.addLine(to: CGPoint(x: center.x, y: center.y - 2.4 * scale))
            ctx.addLine(to: CGPoint(x: center.x + 2.0 * scale, y: center.y - 0.4 * scale))
            ctx.strokePath()

        case .holdingAtLimit, .sailing:
            let barW = 1.25 * scale
            let barH = 4.4 * scale
            let left = CGRect(x: center.x - 1.85 * scale, y: center.y - barH / 2, width: barW, height: barH)
            let right = CGRect(x: center.x + 0.6 * scale, y: center.y - barH / 2, width: barW, height: barH)
            ctx.addPath(CGPath(roundedRect: left, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
            ctx.addPath(CGPath(roundedRect: right, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
            ctx.fillPath()

        case .heatProtectionPaused:
            let stem = CGRect(x: center.x - 0.65 * scale, y: center.y - 0.3 * scale, width: 1.3 * scale, height: 3.1 * scale)
            ctx.addPath(CGPath(roundedRect: stem, cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.fillPath()
            ctx.fillEllipse(in: CGRect(x: center.x - 0.75 * scale, y: center.y - 2.6 * scale, width: 1.5 * scale, height: 1.5 * scale))

        case .calibrating:
            ctx.fillEllipse(in: CGRect(x: center.x - 1.7 * scale, y: center.y - 1.7 * scale, width: 3.4 * scale, height: 3.4 * scale))

        case .onBattery, .sleepingPaused:
            ctx.fillEllipse(in: CGRect(x: center.x - 1.4 * scale, y: center.y - 1.4 * scale, width: 2.8 * scale, height: 2.8 * scale))
        }
        ctx.restoreGState()
    }
}
