import SwiftUI
import BottomlessCore

/// The People row in Collections: everyone the Mac's face indexer found, as round face pictures, named people first.
struct PeopleSection: View {
    @Environment(AppModel.self) private var model
    private let shown = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("People").font(.title2.weight(.bold))
            Spacer()
            if model.people.count > shown {
                NavigationLink(value: CollectionsView.Route.allPeople) { Text("See All") }
                    .accessibilityIdentifier("people-see-all")
            } else if !model.people.isEmpty {
                Text(model.people.count.formatted()).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 22).padding(.bottom, 2)
        if model.people.isEmpty {
            Text("People in your photos appear here once your Mac has looked through them (scripts/faces.py runs every 30 minutes).")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.people.prefix(shown)) { p in
                        NavigationLink(value: CollectionsView.Route.person(id: p.id)) { PersonTile(person: p, size: 78) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("person-\(p.id)")
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }
}

/// A round face with the person's name (or "Add Name") and how many photos they are in.
struct PersonTile: View {
    let person: Catalog.PersonSummary
    let size: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            FaceAvatar(box: person.cover, size: size)
            Text(person.name ?? "Add Name")
                .font(.footnote.weight(.medium))
                .foregroundStyle(person.name == nil ? Color.accentColor : .primary)
                .lineLimit(1)
            Text(person.count.formatted()).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(width: size + 14)
    }
}

struct FaceAvatar: View {
    let box: FaceBox?
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color(.secondarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                }
            }
            .clipShape(Circle())
            .task(id: box?.faceId) {
                guard let box else { image = nil; return }
                let img = await ImageLoader.shared.face(box)
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
    }
}

/// Everyone, in a grid.
struct AllPeopleView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.people) { p in
                    NavigationLink(value: CollectionsView.Route.person(id: p.id)) { PersonTile(person: p, size: 88) }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("People")
    }
}

/// One person's photos, with naming, merging (two groups that are the same person) and hiding.
struct PersonView: View {
    let personId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var draftName = ""
    @State private var merging = false
    @State private var confirmHide = false
    @State private var busy = false

    private var person: Catalog.PersonSummary? { model.people.first { $0.id == personId } }

    var body: some View {
        AssetGridView(title: person?.name ?? "Unnamed", emptyText: "No photos of this person yet.") { [personId] in $0.personAssets(personId) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { draftName = person?.name ?? ""; naming = true } label: {
                            Label(person?.name == nil ? "Add Name" : "Rename", systemImage: "character.cursor.ibeam")
                        }
                        Button { merging = true } label: { Label("Same Person As…", systemImage: "person.2") }
                        Button(role: .destructive) { confirmHide = true } label: { Label("Hide from People", systemImage: "eye.slash") }
                    } label: {
                        if busy { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                    }
                    .accessibilityIdentifier("person-menu")
                }
            }
            .alert("Name", isPresented: $naming) {
                TextField("Name", text: $draftName).textInputAutocapitalization(.words)
                Button("Save") { run { [personId, draftName] in try await $0.api.renamePerson(id: personId, name: draftName) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Who is this?") }
            .confirmationDialog("Hide this person from People?", isPresented: $confirmHide, titleVisibility: .visible) {
                Button("Hide", role: .destructive) {
                    run { [personId] in try await $0.api.setPersonHidden(id: personId, hidden: true) }
                    dismiss()
                }
            } message: { Text("Their photos stay in your library.") }
            .sheet(isPresented: $merging) {
                MergePeopleSheet(personId: personId) { others in
                    run { [personId] in try await $0.api.mergePeople(into: personId, from: others) }
                }
            }
    }

    /// Sends a change to the server, then brings the people list back down so every screen shows it.
    private func run(_ change: @escaping @Sendable (AppServices) async throws -> Void) {
        guard let s = model.services else { return }
        busy = true
        Task {
            do {
                try await change(s)
                try await s.sync.pullPeople()
            } catch {
                model.message = "Could not save that change: \(error)"
            }
            model.reload()
            busy = false
        }
    }
}

/// Pick the other groups that are this same person (the face indexer sometimes splits someone in two).
struct MergePeopleSheet: View {
    let personId: String
    let merge: ([String]) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.people.filter { $0.id != personId }) { p in
                        Button { if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) } } label: {
                            PersonTile(person: p, size: 80)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: picked.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(picked.contains(p.id) ? Color.accentColor : .secondary)
                                        .background(Circle().fill(.background))
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Same person as…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { merge(Array(picked)); dismiss() }.disabled(picked.isEmpty)
                }
            }
        }
    }
}

/// Who a face really is: someone already in People, or a new person by name.
struct PersonPickerSheet: View {
    let excluding: String
    let pick: (_ personId: String, _ newName: String?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section("Someone new") {
                    HStack {
                        TextField("Name", text: $newName).textInputAutocapitalization(.words).submitLabel(.done)
                            .onSubmit { addNew() }
                        Button("Add") { addNew() }.disabled(trimmed.isEmpty)
                    }
                }
                Section("People") {
                    ForEach(model.people.filter { $0.id != excluding }) { p in
                        Button { pick(p.id, nil); dismiss() } label: {
                            HStack(spacing: 12) {
                                FaceAvatar(box: p.cover, size: 40)
                                Text(p.name ?? "Unnamed").foregroundStyle(.primary)
                                Spacer()
                                Text(p.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func addNew() {
        guard !trimmed.isEmpty else { return }
        pick("p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(), trimmed)
        dismiss()
    }
}
