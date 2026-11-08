//
//  CatchFromPhotosViewModel.swift
//  EnglishHelper — Presentation
//
//  Caught → "From photos": the picked photos are prepared (downscaled), then each one is turned into
//  cards by the model; the sheet shows a progress bar and how many cards were caught.
//

import Foundation
import Domain

@MainActor
@Observable
public final class CatchFromPhotosViewModel: Identifiable {
    public enum Phase: Equatable { case preparing, processing, done, failed }

    public let id = UUID()
    public private(set) var phase: Phase = .preparing
    public private(set) var progress: CatchProgress
    public private(set) var errorMessage: String?
    /// The free plan's limit stopped the batch: offer the subscription.
    public private(set) var needsSubscription = false

    private let catchCards: any CatchCardsFromPhotosUseCase
    private let studiedLanguage: () -> String
    private let nativeLanguage: () -> String
    private var task: Task<Void, Never>?

    public init(photoCount: Int, catchCards: any CatchCardsFromPhotosUseCase,
                studiedLanguage: @escaping () -> String = { StudiedLanguage.current.promptName },
                nativeLanguage: @escaping () -> String = { TargetLanguage.current.promptName }) {
        self.progress = CatchProgress(processed: 0, total: photoCount, added: 0, failed: 0)
        self.catchCards = catchCards
        self.studiedLanguage = studiedLanguage
        self.nativeLanguage = nativeLanguage
    }

    /// Start on the prepared photos (nil = a photo that couldn't be read — counted as failed).
    public func run(_ photos: [Data?]) {
        guard task == nil else { return }
        let images = photos.compactMap { $0 }.map { RecognizableImage(data: $0) }
        let unreadable = photos.count - images.count
        progress = CatchProgress(processed: unreadable, total: photos.count, added: 0, failed: unreadable)
        phase = .processing
        let studied = studiedLanguage(), native = nativeLanguage()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await step in self.catchCards(images, studiedLanguage: studied, nativeLanguage: native) {
                    self.progress = CatchProgress(processed: step.processed + unreadable, total: unreadable + step.total,
                                                  added: step.added, failed: step.failed + unreadable)
                }
                self.phase = .done
            } catch is CancellationError {
                self.phase = .done
            } catch LLMError.cancelled {
                self.phase = .done
            } catch {
                let presentable = presentableError(error)
                self.errorMessage = presentable.message
                self.needsSubscription = presentable.needsSubscription
                self.phase = .failed
            }
        }
    }

    /// Stop after the current photo; the cards caught so far stay.
    public func cancel() {
        task?.cancel()
    }
}
