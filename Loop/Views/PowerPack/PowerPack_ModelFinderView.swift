//
//  PowerPack_ModelFinderView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  PowerPack — Provider buttons and results sheet for finding a compatible AI model.
//  Placed under the Model field in FoodFinder, LoopInsights and AutoPresets settings.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import SwiftUI

/// Four provider buttons. Tapping one opens a Google search, inside Loop, for that provider's
/// current models that accept what PowerPack sends. It changes no settings: the user reads the
/// results, closes the page, and types the model into the Model field.
struct PowerPack_ModelFinderBar: View {
    let purpose: PowerPack_ModelPurpose

    @State private var activeProvider: PowerPack_AIProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Search for models that work with PowerPack:", comment: "Model finder bar label"))
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                ForEach(PowerPack_AIProvider.allCases) { provider in
                    Button {
                        activeProvider = provider
                    } label: {
                        Text(provider.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundColor(.white)
                            .background(RoundedRectangle(cornerRadius: 8).fill(provider.color))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(NSLocalizedString("Copy a model name from the results into the Model field, then tap Test Connection. PowerPack sets a low temperature for models that accept one, so results stay consistent, and leaves it out for models that do not.", comment: "Model finder bar footer"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .sheet(item: $activeProvider) { provider in
            LoopInsights_SafariView(url: provider.searchURL(purpose: purpose))
        }
    }
}

extension PowerPack_AIProvider {
    /// Same colors as the existing "get an API key" links in the AI settings screens.
    var color: Color {
        switch self {
        case .openAI: return .green
        case .claude: return .orange
        case .gemini: return .blue
        case .grok: return .red
        }
    }
}
