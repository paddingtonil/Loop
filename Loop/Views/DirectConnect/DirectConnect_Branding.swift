//
//  DirectConnect_Branding.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Dexcom green used to mark DirectConnect everywhere it appears.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI
import UIKit
import ObjectiveC

enum DirectConnect_Branding {
    /// DirectConnect green, #74A52E: the same In Range green LoopInsights uses (`clarityGreen` in
    /// LoopInsights_DashboardView.swift), so PowerPack shows one Dexcom-style green.
    static let uiColor = UIColor(red: 116/255, green: 165/255, blue: 46/255, alpha: 1)
    static let color = Color(uiColor)

    /// PowerPack purple, kept only for the "PowerPack Exclusive" badge, which names PowerPack.
    static let powerPackPurple = Color(red: 107/255, green: 47/255, blue: 160/255)

    /// PowerPack purple for the "Add CGM" list entry. Lighter in dark mode: the base purple is too
    /// dark to read on a dark action sheet.
    static let pickerUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 180/255, green: 130/255, blue: 235/255, alpha: 1)
            : UIColor(red: 107/255, green: 47/255, blue: 160/255, alpha: 1)
    }

    static let iconName = "sensor.tag.radiowaves.forward.fill"

    /// Drawn into a bitmap: Loop's Settings row shows device images with SwiftUI `.resizable()`,
    /// which drops the tint of an SF Symbol and showed this icon black.
    static let tintedIcon: UIImage? = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        guard let symbol = UIImage(systemName: iconName, withConfiguration: configuration)?
            .withTintColor(uiColor, renderingMode: .alwaysOriginal) else { return nil }
        return UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.draw(in: CGRect(origin: .zero, size: symbol.size))
        }
    }()

    /// Colors the DirectConnect entry purple in Loop's "Add CGM" action sheets. UIAlertAction has no
    /// public text-color API; the private `titleTextColor` key is set only after confirming the
    /// backing ivar exists, so a future iOS without it shows the default color instead of crashing.
    static func style(_ action: UIAlertAction) {
        guard action.title == DirectConnect_G7CGMManager.pickerTitle, alertActionIvars.contains("_titleTextColor") else { return }
        action.setValue(pickerUIColor, forKey: "titleTextColor")
        // A custom title color leaves the entry left-aligned; the other entries are centered.
        if alertActionIvars.contains("_titleTextAlignment") {
            action.setValue(NSTextAlignment.center.rawValue, forKey: "titleTextAlignment")
        }
    }

    private static let alertActionIvars: Set<String> = {
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(UIAlertAction.self, &count) else { return [] }
        defer { free(ivars) }
        return Set((0..<Int(count)).compactMap { ivar_getName(ivars[$0]).map { String(cString: $0) } })
    }()
}
