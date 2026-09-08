import OffprintCore
import SwiftUI

/// The empty state. Deliberately the whole window: one instruction, one action.
struct DropZone: View {
    @Environment(ConversionLibrary.self) private var library
    var isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "document.badge.arrow.up")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text("Drop PDFs here")
                    .font(.title2.weight(.medium))
                Text("Everything is converted on this Mac. Nothing is uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Choose Files…") { library.add(FilePicker.chooseFiles()) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(isTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5,
                                               dash: isTargeted ? [] : [7, 6])
                        )
                }
                .padding(20)
        }
        .scaleEffect(isTargeted ? 1.01 : 1)
        .animation(.snappy(duration: 0.15), value: isTargeted)
    }
}
