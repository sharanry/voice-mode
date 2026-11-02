import SwiftUI

/// People and organisations that have appeared so far, from the reader's top bar.
struct EntityListSheet: View {
    let store: EntityStore
    let limit: ReadingPosition
    let jump: (ReadingPosition) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .idle, .extracting:
                    ProgressView("Finding people and organizations…")
                case .ready:
                    let seen = store.appearances(through: limit)
                    if seen.isEmpty {
                        ContentUnavailableView("Nobody yet", systemImage: "person.2",
                                               description: Text("Named people and organizations show up here once they appear in the text."))
                    } else {
                        List {
                            ForEach(Entity.Kind.allCases, id: \.self) { kind in
                                let entries = seen.filter { $0.entity.kind == kind }
                                if !entries.isEmpty {
                                    Section(kind.title) {
                                        ForEach(entries, id: \.entity.id) { entry in row(entry.entity, count: entry.count) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Who’s Who")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ entity: Entity, count: Int) -> some View {
        NavigationLink {
            EntityCardView(store: store, entity: entity, limit: limit, jump: jump)
        } label: {
            HStack(spacing: 12) {
                EntityImage(kind: entity.kind, data: store.images[entity.id], isPainting: false)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name).font(.body.weight(.medium))
                    if let role = store.cards[entity.id]?.role {
                        Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// An entity's card: free facts from the text at once, then the researched card and picture.
struct EntityCardView: View {
    let store: EntityStore
    let entity: Entity
    let limit: ReadingPosition
    let jump: (ReadingPosition) -> Void

    @State private var showImage = false

    private var card: EntityCard? { store.cards[entity.id] }
    private var isResearching: Bool { store.researching.contains(entity.id) }
    /// The card was written earlier in the book than where the reader is now.
    private var isStale: Bool { card.map { $0.through.chapter < limit.chapter } ?? false }

    var body: some View {
        let positions = store.positions(of: entity, through: limit)
        List {
            Section {
                if store.images[entity.id] != nil || store.painting.contains(entity.id) || (card != nil && store.canPaint) {
                    Button { showImage = true } label: {
                        EntityImage(kind: entity.kind, data: store.images[entity.id], isPainting: store.painting.contains(entity.id))
                            .frame(width: 140, height: 140)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !entity.aliases.isEmpty {
                        Text("Also “\(entity.aliases.joined(separator: "”, “"))”").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Mentioned \(positions.count) \(positions.count == 1 ? "time" : "times") so far").font(.subheadline).foregroundStyle(.secondary)
                }
                if let first = positions.first {
                    Button { jump(first) } label: {
                        Label("First appears in \(store.chapterTitle(first.chapter))", systemImage: "arrow.uturn.backward")
                    }
                }
            }

            cardSection

            if !positions.isEmpty {
                Section("Recent mentions") {
                    ForEach(positions.suffix(3).reversed(), id: \.self) { position in
                        Button { jump(position) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.chapterTitle(position.chapter)).font(.caption).foregroundStyle(.secondary)
                                Text("…\(store.snippet(at: position))…").font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(entity.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showImage) { EntityImageViewer(store: store, entity: entity) }
        .onAppear {
            // Lazy: the LLM only runs the first time a card is opened.
            if card == nil, !store.failures.contains(entity.id) { store.research(entity, through: limit) }
        }
    }

    @ViewBuilder private var cardSection: some View {
        if let card {
            Section {
                if let role = card.role { Text(role.capitalizedFirst).font(.headline) }
                Text(card.summary)
                if !card.traits.isEmpty {
                    Text(card.traits.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
            } footer: {
                if isResearching {
                    Text("Updating with what you've read since…")
                } else if isStale {
                    Button("Written at \(store.chapterTitle(card.through.chapter)). Update to where you are") {
                        store.research(entity, through: limit)
                    }
                    .font(.footnote)
                }
            }
            if !card.relationships.isEmpty {
                Section(entity.kind == .person ? "Relationships" : "People and connections") {
                    ForEach(card.relationships, id: \.self) { relation in
                        if let other = store.entity(named: relation.name), other != entity {
                            NavigationLink {
                                EntityCardView(store: store, entity: other, limit: limit, jump: jump)
                            } label: { relationRow(relation) }
                        } else {
                            relationRow(relation)
                        }
                    }
                }
            }
            if !card.moments.isEmpty {
                Section("Key moments") {
                    ForEach(card.moments, id: \.self) { moment in
                        Button { jump(ReadingPosition(chapter: moment.chapter, offset: moment.offset)) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.chapterTitle(moment.chapter)).font(.caption).foregroundStyle(.secondary)
                                Text(moment.note).font(.subheadline).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
        } else if isResearching {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the book so far…").foregroundStyle(.secondary)
                }
            }
        } else if store.failures.contains(entity.id) {
            Section {
                Button("Couldn't write a card. Try again") { store.research(entity, through: limit) }
            }
        } else if !store.canResearch {
            Section {
                Text("Add an OpenRouter key to .env to generate cards.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func relationRow(_ relation: EntityCard.Relationship) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(relation.name).font(.subheadline.weight(.medium))
            Spacer()
            Text(relation.relation).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// The picture full screen, with controls to redraw it in another style or with extra details.
struct EntityImageViewer: View {
    let store: EntityStore
    let entity: Entity
    @Environment(\.dismiss) private var dismiss
    /// nil draws an organisation's default emblem.
    @State private var style: ImageStyle?
    @State private var details = ""

    init(store: EntityStore, entity: Entity) {
        self.store = store
        self.entity = entity
        _style = State(initialValue: entity.kind == .person ? .photo : nil)
    }

    private var isPainting: Bool { store.painting.contains(entity.id) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    if let data = store.images[entity.id], let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .opacity(isPainting ? 0.4 : 1)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(.quaternary).aspectRatio(1, contentMode: .fit)
                    }
                    if isPainting { ProgressView().controlSize(.large) }
                }
                .frame(maxHeight: .infinity)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if entity.kind == .org { chip("Emblem", selected: style == nil) { style = nil } }
                        ForEach(ImageStyle.allCases) { option in
                            chip(option.label, selected: style == option) { style = option }
                        }
                    }
                }

                TextField(entity.kind == .person ? "Add details, e.g. “smiling, red jacket, city at night”" : "Add details, e.g. “gold on navy, a star”",
                          text: $details, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)

                Button {
                    store.paint(entity, style: style, details: details)
                } label: {
                    Label(store.images[entity.id] == nil ? "Generate" : "Regenerate", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ReaderTheme.accent)
                .disabled(isPainting || !store.canPaint || store.cards[entity.id] == nil)

                Text("Each picture costs about $0.007 and replaces the current one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationTitle(entity.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(selected ? AnyShapeStyle(ReaderTheme.accent.opacity(0.25)) : AnyShapeStyle(.quaternary)))
                .overlay(Capsule().strokeBorder(selected ? ReaderTheme.accent : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// A round portrait for a person or a rounded-square emblem for an organisation, with a placeholder.
struct EntityImage: View {
    let kind: Entity.Kind
    let data: Data?
    let isPainting: Bool

    private var shape: AnyShape { kind == .person ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)) }

    var body: some View {
        ZStack {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                shape.fill(.quaternary)
                if isPainting {
                    ProgressView()
                } else {
                    Image(systemName: kind == .person ? "person.fill" : "building.2.fill")
                        .resizable().scaledToFit().padding(10).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(shape)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
