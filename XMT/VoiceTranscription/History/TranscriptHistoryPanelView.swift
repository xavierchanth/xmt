import SwiftUI

/// Searchable newest-first transcript list with per-entry copy, paste, and delete, plus a confirmed
/// clear. Every action is delegated to the view model; the view holds no history state of its own.
struct TranscriptHistoryPanelView: View {
    @ObservedObject var viewModel: TranscriptHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search transcripts", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding([.top, .horizontal], 12)

            Text(targetDescription)
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            if viewModel.results.isEmpty {
                Spacer()
                Text(viewModel.hasEntries ? "No transcripts match this search." : "No transcripts yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(viewModel.results) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(3).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") { viewModel.copy(entry) }
                            Button("Paste") { Task { await viewModel.paste(entry) } }
                            Button("Delete", role: .destructive) { Task { await viewModel.delete(entry) } }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                if let feedback = viewModel.feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
                if let diagnostic = viewModel.diagnostic { Text(diagnostic).font(.footnote).foregroundStyle(.red) }
                Spacer()
                if viewModel.isClearConfirmationPending {
                    Button("Cancel") { viewModel.cancelClear() }
                    Button("Confirm Clear", role: .destructive) { Task { await viewModel.confirmClear() } }
                } else {
                    Button("Clear History…", role: .destructive) { viewModel.requestClear() }
                        .disabled(!viewModel.hasEntries)
                }
            }
            .padding([.bottom, .horizontal], 12)
        }
        .task { await viewModel.loadIfNeeded() }
    }

    private var targetDescription: String {
        guard let target = viewModel.capturedTarget else { return "No paste target captured; actions copy instead." }
        return "Paste goes to \(target.localizedName ?? "the captured app")."
    }
}
