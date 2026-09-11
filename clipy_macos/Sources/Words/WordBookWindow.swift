import SwiftUI

final class WordBookWindow {
    static let shared = WordBookWindow()
    private let session = WindowSession<WordBookView>()
    private var model: WordLookupViewModel?

    func showWindow() {
        session.present(create: { [self] in
            let model = WordLookupViewModel()
            self.model = model
            return HostingWindow(title: L10n.t(.wordBook), size: CGSize(width: 1040, height: 760),
                                 minSize: CGSize(width: 820, height: 500), frameAutosaveName: "WordBookWindow") {
                WordBookView(store: model.wordBook, model: model)
            }
        }, onPrepareForClose: { [weak self] in
            self?.model?.stopSpeaking()
        }, onTeardown: { [weak self] in
            self?.model = nil
            MemoryFootprintReclaimer.reclaimIfIdle()
        }, update: { window in
            window.title = L10n.t(.wordBook)
        })
    }
}

struct WordBookView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var store: WordBookStore
    @ObservedObject var model: WordLookupViewModel
    @AppStorage("wordBookShowChineseMeanings") private var showChineseMeanings = true
    @State private var familiar = false
    @State private var filter = ""
    @State private var selection: String?

    private var filteredWords: [SavedWord] {
        WordSearchMatcher.ranked(store.words.filter { $0.isFamiliar == familiar }, query: filter)
    }

    var body: some View {
        let _ = languageObserver.revision
        AppListWindowLayout {
            AppWindowHeader {
                HStack {
                    Text(L10n.t(.wordBook)).font(AppFont.title)
                    Spacer()
                    Button { showChineseMeanings.toggle() } label: {
                        Label(L10n.t(showChineseMeanings ? .wordHideChinese : .wordShowChinese),
                              systemImage: showChineseMeanings ? "eye.slash" : "eye")
                    }
                    .buttonStyle(AppToolbarButtonStyle())
                    .accessibilityIdentifier("wordBookToggleChinese")
                    .accessibilityValue(L10n.t(showChineseMeanings ? .wordChineseVisible : .wordChineseHidden))
                    Button { WordLookupWindow.shared.showWindow() } label: {
                        Label(L10n.t(.wordLookup), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(AppToolbarButtonStyle())
                }
            }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 12) {
                        Picker(L10n.t(.wordBookStatus), selection: $familiar) {
                            Text("\(L10n.t(.wordUnfamiliar)) (\(store.words.filter { !$0.isFamiliar }.count))").tag(false)
                            Text("\(L10n.t(.wordFamiliar)) (\(store.words.filter { $0.isFamiliar }.count))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("wordBookStatus")
                        TextField(L10n.t(.wordBookFilter), text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("wordBookFilter")
                        Text(L10n.t(.wordBookCheckHelp)).font(.system(size: 14))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if filteredWords.isEmpty {
                            Spacer()
                            Text(L10n.t(.wordBookEmpty)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Spacer()
                        } else {
                            List(selection: $selection) {
                                ForEach(filteredWords) { word in
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle(L10n.t(.wordFamiliar), isOn: Binding(
                                            get: { word.isFamiliar },
                                            set: { store.setFamiliar($0, id: word.id) }))
                                            .toggleStyle(.checkbox).labelsHidden()
                                            .help(L10n.t(.wordBookCheckHelp))
                                            .accessibilityLabel("\(word.entry.word) · \(L10n.t(.wordFamiliar))")
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(word.entry.word).font(.system(size: 20, weight: .semibold))
                                            if let ipa = word.entry.americanIPA {
                                                Text("/\(ipa)/").font(.system(size: 16)).foregroundStyle(.secondary)
                                            }
                                            if showChineseMeanings {
                                                Text(word.entry.meanings.map {
                                                    "\($0.partOfSpeech) \($0.definition)"
                                                }.joined(separator: "；"))
                                                    .font(.system(size: 16)).lineLimit(3)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 8)
                                    .tag(word.id)
                                }
                            }
                            .listStyle(.sidebar)
                        }
                    }
                    .padding(12)
                    .frame(width: 310)
                    .background(AppColor.groupedBackground)
                    Divider()
                    if let word = store.words.first(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Toggle(L10n.t(.wordFamiliar), isOn: Binding(
                                    get: { word.isFamiliar },
                                    set: { store.setFamiliar($0, id: word.id) }))
                                    .toggleStyle(.checkbox)
                                Spacer()
                                Text("\(L10n.t(.wordBookLookups)): \(word.lookupCount)")
                            }
                            .font(.system(size: 16)).padding(16)
                            Text("\(L10n.t(.wordBookLastLookup)): \(word.lastLookedUpAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 14)).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.bottom, 12)
                            Divider()
                            WordEntryDetailView(viewModel: model, entry: word.entry,
                                onLookupPhrase: { WordLookupWindow.shared.showWindow(query: $0) },
                                showChineseMeanings: showChineseMeanings)
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "books.vertical").font(.system(size: 36))
                            Text(L10n.t(.wordBookSelect)).font(.system(size: 20))
                            Text(L10n.t(.wordBookHint)).font(.system(size: 16))
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let error = store.errorKey {
                    Divider()
                    Text(L10n.t(error)).foregroundStyle(.red).padding(12)
                }
            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: familiar) { _ in reconcileSelection() }
        .onChange(of: filter) { _ in reconcileSelection() }
        .onChange(of: store.words) { _ in reconcileSelection() }
        .onChange(of: selection) { _ in loadSelection() }
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    private func reconcileSelection() {
        if !filteredWords.contains(where: { $0.id == selection }) {
            selection = filteredWords.first?.id
        }
        loadSelection()
    }

    private func loadSelection() {
        if let word = store.words.first(where: { $0.id == selection }) {
            if model.entry != word.entry { model.showSaved(word.entry) }
        } else {
            model.prepareForClose()
        }
    }
}
