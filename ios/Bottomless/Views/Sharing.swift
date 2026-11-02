import SwiftUI
import UIKit
import BottomlessCore

/// The standard iOS share sheet (Messages, WhatsApp, AirDrop, Mail, Save to Files...).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Creates an expiring web link to some photos.
struct ShareLinkSheet: View {
    let ids: [String]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var days = 7
    @State private var allowOriginal = false
    @State private var link: SharedLink?
    @State private var working = false
    @State private var error: String?
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            Form {
                if let link {
                    Section("Link ready") {
                        Text(link.url.absoluteString).textSelection(.enabled).font(.footnote.monospaced())
                        Button { UIPasteboard.general.url = link.url } label: { Label("Copy link", systemImage: "doc.on.doc") }
                        Button { sharing = true } label: { Label("Send link…", systemImage: "square.and.arrow.up") }
                        Text("Expires \(Date(ms: link.expiresAt).formatted(date: .abbreviated, time: .shortened)).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("Title (optional)", text: $title)
                        Stepper("Expires in \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...30)
                        Toggle("Allow downloading originals", isOn: $allowOriginal)
                    } footer: {
                        Text("Anyone with the link can see these \(ids.count) item\(ids.count == 1 ? "" : "s") until it expires.")
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    Button {
                        Task {
                            working = true
                            defer { working = false }
                            do { link = try await model.createShareLink(ids, title: title, days: days, allowOriginal: allowOriginal) }
                            catch { self.error = "\(error)" }
                        }
                    } label: { if working { ProgressView() } else { Text("Create link") } }
                    .disabled(working || model.isOffline)
                }
            }
            .navigationTitle("Share link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $sharing) { if let link { ShareSheet(items: [link.url]) } }
        }
    }
}
