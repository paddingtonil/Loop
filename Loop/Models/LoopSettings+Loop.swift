//
//  LoopSettings+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopCore

// MARK: - Static configuration
extension LoopSettings {
    var enabledEffects: PredictionInputEffect {
        var inputs = PredictionInputEffect.all
        if !LoopConstants.retrospectiveCorrectionEnabled {
            inputs.remove(.retrospection)
        }
        if !LoopSettings.negativeInsulinDamperActive {
            inputs.remove(.damper)
        }
        if !UserDefaults.standard.negativeInsulinClampEnabled {
            inputs.remove(.clamp)
        }
        return inputs
    }

    /// The damper and the negative insulin clamp are mutually exclusive; the clamp takes precedence.
    static var negativeInsulinDamperActive: Bool {
        UserDefaults.standard.negativeInsulinDamperEnabled && !UserDefaults.standard.negativeInsulinClampEnabled
    }
}
