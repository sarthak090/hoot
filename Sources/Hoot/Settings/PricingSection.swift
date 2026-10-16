import AppKit
import SwiftUI

struct PricingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            LabeledContent("Pricing file") {
                Text(verbatim: model.usage.pricingFile.path)
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            HStack {
                Button("Choose…", action: choose)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.usage.pricingFile]) }
                if !settings.pricingPath.isEmpty {
                    Button("Use Default") {
                        settings.pricingPath = ""
                        model.usage.pricingPathChanged()
                    }
                }
                Spacer()
                Button("Reset Prices…", role: .destructive) { confirmReset = true }
            }
            if let problem = model.usage.pricingProblem {
                WarningRow(text: problem)
            } else if let asOf = model.usage.pricing.pricesAsOf {
                Text("Prices as of \(asOf), \(model.usage.pricing.models.count) models.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Cost Estimate")
        } footer: {
            Text("USD per million tokens at API list prices. This estimates what your tokens would cost on the API. It isn't what a Pro/Max plan charges. Edits apply automatically.")
        }
        .confirmationDialog("Overwrite the pricing file with Hoot's built-in prices?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.usage.resetPricingFile() }
        }
    }

    @State private var confirmReset = false

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.usage.pricingFile.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.pricingPath = url.path
        model.usage.pricingPathChanged()
    }
}
