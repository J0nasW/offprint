import OffprintCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ConversionLibrary.self) private var library
    @State private var isTargeted = false

    var body: some View {
        Group {
            if library.jobs.isEmpty {
                DropZone(isTargeted: isTargeted)
            } else {
                HSplitView {
                    QueueList()
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                    DocumentView(job: library.selectedJob)
                        .frame(minWidth: 380)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { ControlBar() }
        // The whole window is the drop target, not just the inner rectangle —
        // that is what people expect from a Mac utility, and it keeps working
        // once the queue has filled the window.
        .dropDestination(for: URL.self) { urls, _ in
            library.add(urls)
            return true
        } isTargeted: { hovering in
            withAnimation(.snappy(duration: 0.15)) { isTargeted = hovering }
        }
        .overlay {
            if isTargeted && !library.jobs.isEmpty { DropOverlay() }
        }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
