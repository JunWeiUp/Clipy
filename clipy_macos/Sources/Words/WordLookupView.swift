import SwiftUI

struct WordLookupView: View {
  @EnvironmentObject private var languageObserver: AppLanguageObserver
  @ObservedObject var viewModel: WordLookupViewModel
  @ObservedObject var wordBook: WordBookStore

  init(viewModel: WordLookupViewModel) {
    self.viewModel = viewModel
    self.wordBook = viewModel.wordBook
  }
  @FocusState private var queryFocused: Bool

  var body: some View {
    let _ = languageObserver.revision
    AppListWindowLayout {
      AppWindowHeader {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
          HStack {
            Spacer()
            Button { WordBookWindow.shared.showWindow() } label: {
              Label(L10n.t(.wordBook), systemImage: "books.vertical")
            }
            .buttonStyle(AppToolbarButtonStyle())
          }
          HStack(spacing: 10) {
            HStack {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              TextField(L10n.t(.wordPlaceholder), text: $viewModel.query, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 20))
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { viewModel.search() }
                .accessibilityIdentifier("wordQuery")
            }
            .modifier(AppInputSurface())
            Button(L10n.t(.wordSearch)) { viewModel.search() }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .font(.system(size: 16))
              .keyboardShortcut(.return, modifiers: .command)
              .disabled(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityIdentifier("wordSearch")
          }
        }
      }
    } content: {
      VStack(spacing: 0) {
        if !viewModel.suggestions.isEmpty {
          candidateList
            .frame(maxHeight: viewModel.entry == nil && viewModel.translation == nil ? .infinity : 180)
          Divider()
        }
        if viewModel.isLoading {
          ProgressView(L10n.t(.wordLoading)).padding(24)
          if viewModel.suggestions.isEmpty { Spacer() }
        } else if let error = viewModel.errorKey {
          if viewModel.suggestions.isEmpty {
            placeholder(
              symbol: "magnifyingglass", title: L10n.t(error), detail: L10n.t(.wordTryAgain))
          } else {
            Text(L10n.t(error)).font(.system(size: 16)).foregroundStyle(.secondary).padding(16)
          }
        } else if let entry = viewModel.entry {
          WordEntryDetailView(viewModel: viewModel, entry: entry)
        } else if let translation = viewModel.translation {
          WordTranslationView(viewModel: viewModel, translation: translation)
            .id(translation.original)
        } else if viewModel.suggestions.isEmpty {
          placeholder(
            symbol: "character.book.closed", title: L10n.t(.wordWelcome),
            detail: L10n.t(.wordWelcomeDetail))
        }
        if let error = wordBook.errorKey {
          Text(L10n.t(error)).foregroundStyle(.red).padding(AppSpacing.sm)
        }
        Divider()
        Text(L10n.t(.wordPrivacy)).font(.system(size: 14)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(AppSpacing.sm)
          .background(AppColor.groupedBackground)
      }
    }
    .onAppear { queryFocused = true }
    .onChange(of: viewModel.focusRequest) { _ in queryFocused = true }
    .onExitCommand { NSApp.keyWindow?.close() }
    .background(
      Button("") { queryFocused = true }.keyboardShortcut("l", modifiers: .command).hidden())
  }

  private var candidateList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.t(.wordCandidates)).font(.system(size: 18, weight: .semibold))
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(viewModel.suggestions) { suggestion in
            Button { viewModel.selectSuggestion(suggestion) } label: {
              HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(suggestion.word).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                  if !suggestion.detail.isEmpty {
                    Text(suggestion.detail).font(.system(size: 16)).foregroundStyle(.secondary)
                      .lineLimit(2).lineSpacing(4)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
              }
              .multilineTextAlignment(.leading)
              .padding(.vertical, 12).padding(.horizontal, 8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t(.wordLookupPhrase))
            Divider()
          }
        }
      }
    }
    .padding(16)
    .accessibilityIdentifier("wordCandidates")
  }

  private func placeholder(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 24, weight: .medium))
      Text(detail).font(.system(size: 18)).lineSpacing(6).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Spacer()
    }
    .padding(28)
    .frame(maxWidth: .infinity)
  }
}
