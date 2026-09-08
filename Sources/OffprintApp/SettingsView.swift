import OffprintCore
import SwiftUI

struct SettingsView: View {
    @Environment(ConversionLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        Form {
            Section("Conversion") {
                Picker("Quality", selection: $library.tier) {
                    ForEach(QualityTier.allCases, id: \.self) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                Toggle("Extract figures", isOn: $library.extractFigures)
                Text("Figures are cropped from the page and saved next to the Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Export chunks for retrieval", isOn: $library.exportChunks)
                Text("Writes .chunks.jsonl and .outline.json. Chunks are cut by section, carry their heading trail and position, and link to their neighbours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                LabeledContent("Fast") {
                    Text("Built in — no download").foregroundStyle(.secondary)
                }
                LabeledContent("Balanced and Best") {
                    Text("GLM-OCR, not yet installed").foregroundStyle(.secondary)
                }
                Text("Model downloads land in Application Support and can be deleted at any time. The Fast tier never needs the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
