import AppKit
import AVFoundation
import Combine

/// UI-owned, like SearchViewModel. All mutations and completions run on main.
final class WordLookupViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate, NSSpeechSynthesizerDelegate {
    @Published var query = ""
    @Published private(set) var entry: WordEntry?
    @Published private(set) var isLoading = false
    @Published private(set) var errorKey: L10nKey?
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioStatus: L10nKey?
    @Published var focusRequest = UUID()

    private let service: WordLookingUp
    private var lookupTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var generation = UUID()
    private var audioGeneration = UUID()
    private var player: AVAudioPlayer?
    private var synthesizer: NSSpeechSynthesizer?

    init(service: WordLookingUp = WordLookupService()) { self.service = service }

    func prepareForPresentation(clipboardText: String?) {
        if let word = WordQuery.clipboardWord(clipboardText), word != query {
            // A pending response for the previous input must not appear under
            // the newly prefilled word. Prefill never starts a network request.
            clearLookup()
            query = word
        }
        focusRequest = UUID()
    }

    func search() {
        lookupTask?.cancel()
        stopSpeaking()
        let token = UUID()
        generation = token
        entry = nil
        errorKey = nil
        isLoading = false
        let term: String
        do { term = try WordQuery.normalize(query) }
        catch { errorKey = .wordInvalidQuery; return }
        query = term
        isLoading = true
        let service = self.service
        lookupTask = Task { @MainActor [weak self] in
            do {
                let result = try await service.lookup(term)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.entry = result
                self.isLoading = false
                self.lookupTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.errorKey = (error as? WordLookupError) == .notFound ? .wordNotFound : .wordNetworkError
                self.isLoading = false
                self.lookupTask = nil
            }
        }
    }

    func pronounce() {
        if isSpeaking { stopSpeaking(); return }
        guard let entry else { return }
        stopSpeaking()
        isSpeaking = true
        audioStatus = .wordAudioLoading
        let token = audioGeneration
        let service = self.service
        audioTask = Task { @MainActor [weak self] in
            do {
                let data = try await service.americanAudio(entry.word)
                guard !Task.isCancelled, let self, self.audioGeneration == token else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                guard player.play() else { throw WordLookupError.unavailable }
                self.audioStatus = .wordRecordedAudio
                self.audioTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.audioGeneration == token else { return }
                self.audioTask = nil
                self.speakWithSystemVoice(entry.word)
            }
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        player = nil
        // Never silently fall back to the system's default (possibly British) voice.
        guard let voice = NSSpeechSynthesizer.availableVoices.first(where: {
            let locale = NSSpeechSynthesizer.attributes(forVoice: $0)[.localeIdentifier] as? String
            return locale?.replacingOccurrences(of: "-", with: "_") == "en_US"
        }), let speech = NSSpeechSynthesizer(voice: voice) else {
            audioStatus = .wordAudioUnavailable
            isSpeaking = false
            return
        }
        synthesizer = speech
        speech.delegate = self
        speech.rate = 165
        audioStatus = .wordSystemAudio
        if !speech.startSpeaking(text) {
            audioStatus = .wordAudioUnavailable
            isSpeaking = false
            synthesizer = nil
        }
    }

    func stopSpeaking() {
        audioGeneration = UUID()
        audioTask?.cancel()
        audioTask = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking()
        synthesizer = nil
        isSpeaking = false
        audioStatus = nil
    }

    func prepareForClose() {
        clearLookup()
        query = ""
    }

    private func clearLookup() {
        generation = UUID()
        lookupTask?.cancel()
        lookupTask = nil
        stopSpeaking()
        entry = nil
        isLoading = false
        errorKey = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        self.player = nil
        isSpeaking = false
        if !flag { audioStatus = .wordAudioUnavailable }
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard synthesizer === sender else { return }
        synthesizer = nil
        isSpeaking = false
    }
}
