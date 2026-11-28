//
//  EPUBHighlight+Presets.swift
//  Glossa
//
//  The colours a mark offers, from Settings. Kept apart from the highlight
//  model so that the model has no dependency on the settings object.
//

import Foundation

extension EPUBHighlightStyle {
    /// The colours this kind of mark offers.
    @MainActor var presets: [SettingsManager.ColorPreset] {
        switch self {
        case .tint: SettingsManager.shared.highlightPresets
        case .underline: SettingsManager.shared.underlinePresets
        }
    }
}

extension EPUBHighlight {
    /// The colours this mark offers: a note's are Settings' comment colours,
    /// as a PDF comment's are.
    @MainActor func presets(asNote: Bool) -> [SettingsManager.ColorPreset] {
        asNote && style == .tint ? SettingsManager.shared.commentPresets : style.presets
    }
}
