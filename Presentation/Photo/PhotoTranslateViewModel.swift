//
//  PhotoTranslateViewModel.swift
//  EnglishHelper — Presentation
//
//  "See it". Two modes over a photo, mirroring Get-it: EXPLAIN (default) — explain WHAT the photo
//  shows + its local/cultural context; TRANSLATE — recognize the text and translate it into blocks
//  (each a card with play + save). The mode selector sits at the top, like Get-it.
//

import Foundation
import Domain

@MainActor
@Observable
public final class PhotoTranslateViewModel {
    public enum Phase: Equatable { case idle, processing, result, failed }

    /// What pressing through a photo does: EXPLAIN its scene/context, or TRANSLATE its text. Order
    /// drives the on-screen segment order (Explain first); Explain is the default.
    public enum Mode: String, CaseIterable, Sendable {
        case explain, translate
        public var title: String {
            switch self {
            case .explain: Loc.t("Объяснение", "Explain")
            case .translate: Loc.t("Перевод", "Translate")
            }
        }
        /// Last-used mode, persisted so the screen comes back the way the user left it.
        static let storageKey = "seeItMode"
        static var current: Mode {
            Mode(rawValue: Prefs.store.string(forKey: storageKey) ?? "") ?? .explain
        }
    }

    public private(set) var phase: Phase = .idle
    /// Mutated only via `selectMode`/`routeMode` so the re-run logic isn't bypassed. Persisted ONLY
    /// by `selectMode` (an explicit tap on the on-screen selector) — a routed change (shared-in
    /// image, widget deep link) is session-only, so it can never silently overwrite the user's
    /// saved preference.
    public private(set) var mode: Mode = Mode.current
    public private(set) var imageData: Data?
    /// Per-mode results for the CURRENT photo — both can be non-nil at once (each mode's run is
    /// cached so Explain ↔ Translate switches restore the earlier result instead of re-running
    /// the request). The view picks which one to render by `mode`, not by which exists.
    public private(set) var blocks: [TranslatedBlock] = []          // Translate mode result
    public private(set) var explanation: SceneExplanation?          // Explain mode result
    public private(set) var errorMessage: String?
    /// A SAVE failure shown independently of `phase` (the result stays on screen); `errorMessage`
    /// only renders in `.failed`.
    public private(set) var saveError: String?
    public private(set) var isOffline = false
    /// The free plan's limit stopped the request — the screen offers the subscription instead of Retry.
    public private(set) var needsSubscription = false

    public var showCameraPriming = false
    public var presentCamera = false

    private var savedBlockIDs: Set<UUID> = []          // optimistic "saved" flag (instant UI)
    private var savedExpressionIDs: [UUID: UUID] = [:]  // block.id → stored Expression.id
    /// Bumped whenever `blocks` are REPLACED (a translate run completing) so an in-flight save can
    /// tell "user un-saved" from "a new result replaced the blocks" and not silently delete a
    /// just-bookmarked expression. An explain run doesn't bump it — the cached blocks survive it.
    private var resultsGeneration = 0
    private var playingBlockID: UUID?
    /// True when the last failure could plausibly succeed on a re-run of the SAME photo (network /
    /// transient / server, and recognition errors — recognition is LLM-run, so non-deterministic),
    /// so a "Retry" affordance is offered. False where re-running the same request can't help
    /// (no key, response too long, undecodable image).
    private var lastErrorRetryable = false

    private let photoTranslate: any PhotoTranslateUseCase
    private let photoExplain: any PhotoExplainUseCase
    private let pronounce: any PlayPronunciationUseCase
    private let saveExpression: any SaveExpressionUseCase
    private let studyList: any StudyListUseCase
    private let isConfigured: Bool
    /// Keeps a slow OCR/translate job alive briefly after backgrounding + notifies on completion. Nil in
    /// tests/previews (then it's a transparent pass-through).
    private let longTask: (any LongTaskCoordinating)?

    private var requestTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private let primingDefaultsKey = "didPrimeCamera"

    public init(
        photoTranslate: any PhotoTranslateUseCase,
        photoExplain: any PhotoExplainUseCase,
        pronounce: any PlayPronunciationUseCase,
        saveExpression: any SaveExpressionUseCase,
        studyList: any StudyListUseCase,
        isConfigured: Bool,
        longTask: (any LongTaskCoordinating)? = nil
    ) {
        self.photoTranslate = photoTranslate
        self.photoExplain = photoExplain
        self.pronounce = pronounce
        self.saveExpression = saveExpression
        self.studyList = studyList
        self.isConfigured = isConfigured
        self.longTask = longTask
    }

    /// Switch Explain/Translate from the ON-SCREEN selector — remembered across launches.
    public func selectMode(_ newMode: Mode) { applyMode(newMode, persist: true) }

    /// Programmatic mode change (shared-in image, widget deep link). Same behavior, but
    /// SESSION-ONLY: a routed action must never overwrite the user's saved selector choice.
    public func routeMode(_ newMode: Mode) { applyMode(newMode, persist: false) }

    /// If a photo is already loaded, show the new mode's CACHED result when this photo already ran
    /// in it, else re-run; otherwise just remember the choice for the next photo.
    private func applyMode(_ newMode: Mode, persist: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        if persist { Prefs.store.set(newMode.rawValue, forKey: Mode.storageKey) }
        guard imageData != nil, phase == .result || phase == .processing || phase == .failed else { return }
        if hasCachedResult(for: newMode) {
            // The SAME photo already ran in this mode → restore that result, NO repeat request:
            // hopping Explain ↔ Translate over an unchanged photo must not re-bill the model.
            requestTask?.cancel()   // an in-flight run of the OTHER mode must not overwrite phase/error
            errorMessage = nil
            isOffline = false
            needsSubscription = false
            lastErrorRetryable = false
            phase = .result
        } else if let data = imageData {
            // First visit to this mode for this photo — and after a FAILURE (e.g. the model was
            // unavailable in the previous mode), so switching mode retries instead of staying stuck.
            process(data)
        }
    }

    /// Whether the CURRENT photo already has this mode's completed result cached.
    private func hasCachedResult(for mode: Mode) -> Bool {
        switch mode {
        case .translate: !blocks.isEmpty
        case .explain: explanation != nil
        }
    }

    public var needsAPIKey: Bool { !isConfigured }
    public func isSaved(_ block: TranslatedBlock) -> Bool { savedBlockIDs.contains(block.id) }
    public func isPlaying(_ block: TranslatedBlock) -> Bool { playingBlockID == block.id }

    // MARK: Camera priming

    public func cameraTapped() {
        if Prefs.store.bool(forKey: primingDefaultsKey) {
            presentCamera = true
        } else {
            showCameraPriming = true
        }
    }

    public func confirmCameraPriming() {
        Prefs.store.set(true, forKey: primingDefaultsKey)
        showCameraPriming = false
        presentCamera = true
    }

    public func cancelCameraPriming() { showCameraPriming = false }
    public func cameraCancelled() { presentCamera = false }

    public func didCapture(_ data: Data) {
        presentCamera = false
        startNewPhoto(data)
    }

    public func didPickFromLibrary(_ data: Data) {
        startNewPhoto(data)
    }

    /// A NEW photo invalidates BOTH modes' cached results (they belong to the previous image).
    /// `process` itself only clears the mode it re-runs, so retries and mode switches keep the
    /// other mode's cache — this wrapper is the only place both go at once.
    private func startNewPhoto(_ data: Data) {
        blocks = []
        explanation = nil
        savedBlockIDs = []
        savedExpressionIDs = [:]
        process(data)
    }

    /// Auto-retry after the network returns (RootView calls this on reconnect): re-run OCR+translate on
    /// the last image, but ONLY when we're showing an offline failure (other errors would just repeat).
    public func retryOnReconnect() {
        guard phase == .failed, isOffline, let data = imageData else { return }
        process(data)
    }

    /// Whether the failed photo can be retried — we still hold the image and the error was transient.
    public var canRetry: Bool { imageData != nil && lastErrorRetryable }

    /// Manually re-run the LAST photo after a failure (the image is never lost on an error).
    public func retry() {
        guard let data = imageData else { return }
        process(data)
    }

    /// The picked library photo couldn't be loaded/decoded — surface it instead of silently doing nothing.
    public func imageLoadFailed() {
        requestTask?.cancel()
        isOffline = false
        needsSubscription = false
        // `imageData` (if any) still holds the PREVIOUS photo — never offer to "retry" that one
        // when it's the newly picked image that failed to load.
        lastErrorRetryable = false
        errorMessage = Loc.t("Не удалось загрузить изображение. Попробуйте другое фото.",
                             "Couldn't load the image. Try another photo.",
                             "Impossible de charger l'image. Essayez une autre photo.",
                             "No se pudo cargar la imagen. Prueba con otra foto.",
                             "Bild konnte nicht geladen werden. Versuche ein anderes Foto.",
                             "Impossibile caricare l'immagine. Prova un'altra foto.")
        phase = .failed
    }

    // MARK: Pipeline

    private func process(_ data: Data) {
        requestTask?.cancel()
        imageData = data
        // Only the mode being (re)run is invalidated — the OTHER mode's result for this photo
        // stays cached so a mode switch can restore it without a repeat request.
        switch mode {
        case .translate:
            blocks = []
            savedBlockIDs = []       // the saved flags map onto `blocks` — they go together
            savedExpressionIDs = [:]
        case .explain:
            explanation = nil
        }
        errorMessage = nil
        isOffline = false
        needsSubscription = false
        lastErrorRetryable = false
        phase = .processing
        let studied = StudiedLanguage.current.promptName   // the studied-language place/country context
        let native = TargetLanguage.current.promptName     // explanation / translation rendered in native
        let mode = self.mode
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = RecognizableImage(data: data)
                switch mode {
                case .translate:
                    self.blocks = try await withBackgroundCompletion(self.longTask, .photoTranslate) {
                        try await self.photoTranslate(image, studiedLanguage: studied, nativeLanguage: native)
                    }
                    self.resultsGeneration += 1   // blocks replaced → stale in-flight save mappings
                case .explain:
                    self.explanation = try await withBackgroundCompletion(self.longTask, .photoExplain) {
                        try await self.photoExplain(image, studiedLanguage: studied, nativeLanguage: native)
                    }
                }
                self.phase = .result
            } catch is CancellationError {
                // superseded
            } catch LLMError.cancelled {
                // superseded by a newer photo / a mode switch — the adapter maps task cancellation to
                // LLMError.cancelled, so this (not CancellationError) is what surfaces. Never show it.
            } catch {
                self.handle(error)
            }
        }
    }

    private func handle(_ error: Error) {
        phase = .failed
        if let ocr = error as? TextRecognitionError {
            switch ocr {
            case .noTextFound:
                errorMessage = Loc.t("Не нашёл английский текст на фото. Попробуйте другое изображение.",
                                     "No English text found in the photo. Try another image.")
                lastErrorRetryable = true    // recognition is LLM-run → a re-run can find the text
            case .unsupportedImage:
                errorMessage = Loc.t("Не удалось обработать изображение.", "Couldn't process the image.")
                lastErrorRetryable = false   // decoding the same bytes again can't succeed
            case .cancelled:
                errorMessage = Loc.t("Отменено.", "Cancelled.")
                lastErrorRetryable = false   // superseded by a newer request
            case .underlying:
                errorMessage = Loc.t("Ошибка распознавания текста.", "Text recognition error.")
                lastErrorRetryable = true    // recognizer failures are typically transient
            }
            isOffline = false
            needsSubscription = false
        } else {
            let presented = presentableError(error)
            errorMessage = presented.message
            isOffline = presented.isOffline
            needsSubscription = presented.needsSubscription
            // Offer to retry the SAME photo for network / transient / server failures (the photo is
            // kept). Not for "no key" or "too long", where re-running the same request can't help.
            if let llm = error as? LLMError {
                switch llm {
                case .offline, .timedOut, .overloaded, .requestFailed, .invalidOutput:
                    lastErrorRetryable = true
                case .notConfigured, .responseTooLong, .cancelled, .subscriptionRequired:
                    lastErrorRetryable = false
                }
            } else {
                lastErrorRetryable = true
            }
        }
    }

    // MARK: Per-block actions

    public func play(_ block: TranslatedBlock) {
        if playingBlockID == block.id { stopPlayback(); return }   // tap again = stop
        playTask?.cancel()
        playingBlockID = block.id
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await state in self.pronounce(block.en) where state == .finished { break }
            } catch {}
            if !Task.isCancelled, self.playingBlockID == block.id { self.playingBlockID = nil }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        playingBlockID = nil
    }

    public func toggleSave(_ block: TranslatedBlock) {
        let id = block.id
        if savedBlockIDs.contains(id) {
            savedBlockIDs.remove(id)                       // instant UI
            let storedID = savedExpressionIDs[id]
            savedExpressionIDs[id] = nil
            if let storedID {
                Task { [weak self] in try? await self?.studyList.delete(id: storedID) }
            }
        } else {
            savedBlockIDs.insert(id)                        // instant UI; enrich+store in background
            let generation = resultsGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    let stored = try await self.saveExpression(en: block.en, knownRU: block.ru, context: "")
                    if self.resultsGeneration != generation {
                        // A new photo replaced the result while saving — keep it persisted; drop the mapping.
                    } else if self.savedBlockIDs.contains(id) {
                        self.savedExpressionIDs[id] = stored.id
                    } else {
                        try? await self.studyList.delete(id: stored.id)   // user un-saved while saving
                    }
                } catch {
                    self.savedBlockIDs.remove(id)           // revert
                    self.saveError = Loc.t("Не удалось сохранить в изучаемое.",
                                           "Couldn't save to your study list.")
                }
            }
        }
    }

    public func clearSaveError() { saveError = nil }

    public func reset() {
        requestTask?.cancel(); playTask?.cancel()
        phase = .idle
        imageData = nil
        blocks = []
        explanation = nil
        savedBlockIDs = []
        savedExpressionIDs = [:]
        playingBlockID = nil
        errorMessage = nil
        isOffline = false
        needsSubscription = false
    }
}
