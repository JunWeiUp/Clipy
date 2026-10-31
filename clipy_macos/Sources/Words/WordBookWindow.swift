import SwiftUI

final class WordBookWindow {
    static let shared = WordBookWindow()
    func showWindow() {
        WordLookupWindow.shared.showWindow(showBook: true)
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.t(.wordBook)).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { showChineseMeanings.toggle() } label: {
                    Label(L10n.t(showChineseMeanings ? .wordHideChinese : .wordShowChinese),
                          systemImage: showChineseMeanings ? "eye.slash" : "eye")
                }
                .buttonStyle(AppToolbarButtonStyle())
                .accessibilityIdentifier("wordBookToggleChinese")
                .accessibilityValue(L10n.t(showChineseMeanings ? .wordChineseVisible : .wordChineseHidden))
            }
            .padding(.leading, 20).padding(.trailing, 14)
            .frame(height: 52)
            .background(WordsV3Style.content)
            Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.t(.wordBookStatus), selection: $familiar) {
                        Text("\(L10n.t(.wordUnfamiliar)) (\(store.words.filter { !$0.isFamiliar }.count))").tag(false)
                        Text("\(L10n.t(.wordFamiliar)) (\(store.words.filter { $0.isFamiliar }.count))").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("wordBookStatus")
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(WordsV3Style.text3)
                        TextField(L10n.t(.wordBookFilter), text: $filter)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("wordBookFilter")
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(WordsV3Style.content, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WordsV3Style.line, lineWidth: 0.5))
                    Text(L10n.t(.wordBookCheckHelp)).font(.system(size: 14))
                        .foregroundStyle(WordsV3Style.text3).frame(maxWidth: .infinity, alignment: .leading)
                    if filteredWords.isEmpty {
                        Text(L10n.t(.wordBookEmpty)).font(.system(size: 16)).foregroundStyle(WordsV3Style.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.top, 48)
                        Spacer()
                    } else {
                        List(selection: $selection) {
                            ForEach(filteredWords) { word in
                                HStack(alignment: .top, spacing: 10) {
                                    Toggle(L10n.t(.wordFamiliar), isOn: Binding(
                                        get: { word.isFamiliar },
                                        set: { store.setFamiliar($0, id: word.id) }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                        .padding(.top, 5)
                                        .help(L10n.t(.wordBookCheckHelp))
                                        .accessibilityLabel("\(word.entry.word) · \(L10n.t(.wordFamiliar))")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(word.entry.word).font(.system(size: 20, weight: .semibold))
                                        if showChineseMeanings {
                                            Text(word.entry.meanings.map {
                                                "\($0.partOfSpeech) \($0.definition)"
                                            }.joined(separator: "；"))
                                                .font(.system(size: 16)).foregroundStyle(WordsV3Style.text2)
                                                .lineLimit(3)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 4)
                                .listRowSeparator(.hidden)
                                .tag(word.id)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                .padding(12)
                .frame(width: 310)
                .background(WordsV3Style.secondaryContent)
                WordsV3Style.line.frame(width: 1)
                if let word = store.words.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Toggle(L10n.t(.wordFamiliar), isOn: Binding(
                                get: { word.isFamiliar },
                                set: { store.setFamiliar($0, id: word.id) }))
                                .toggleStyle(.checkbox)
                            Spacer()
                            Text("\(L10n.t(.wordBookLookups)): \(word.lookupCount)")
                        }
                        .font(.system(size: 16)).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                        Text("\(L10n.t(.wordBookLastLookup)): \(word.lastLookedUpAt.formatted(date: .long, time: .shortened))")
                            .font(.system(size: 14)).foregroundStyle(WordsV3Style.text3)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                        Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
                        WordEntryDetailView(viewModel: model, entry: word.entry,
                            onLookupPhrase: { WordLookupWindow.shared.showWindow(query: $0) },
                            showChineseMeanings: showChineseMeanings)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical").font(.system(size: 40, weight: .light))
                            .foregroundStyle(WordsV3Style.text3)
                        Text(L10n.t(.wordBookSelect)).font(.system(size: 20, weight: .medium))
                        Text(L10n.t(.wordBookHint)).font(.system(size: 16))
                            .multilineTextAlignment(.center).foregroundStyle(WordsV3Style.text2)
                            .frame(maxWidth: 520)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if let error = store.errorKey {
                Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
                Text(L10n.t(error)).foregroundStyle(.red).padding(12)
            }
        }
        .background(WordsV3Style.content)
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
