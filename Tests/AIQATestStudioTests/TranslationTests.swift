import XCTest
@testable import AIQATestStudio

@MainActor
final class TranslationTests: XCTestCase {
    func testNeedsTranslation() {
        XCTAssertTrue(TranslationStore.needsTranslation("画面タイトル「Shop注文履歴」が表示されることの確認"))
        XCTAssertTrue(TranslationStore.needsTranslation("Order details page"))
        XCTAssertFalse(TranslationStore.needsTranslation("Kiểm tra tiêu đề màn hình"))
        XCTAssertFalse(TranslationStore.needsTranslation("TC-001"))
        XCTAssertFalse(TranslationStore.needsTranslation("  "))
    }

    /// Opt-in: needs Ollama running with the model in AIQA_MODEL.
    func testLocalModelTranslatesAndKeepsQuotedLabels() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = try XCTUnwrap(env["AIQA_MODEL"], "set AIQA_MODEL to run")
        UserDefaults.standard.set(model, forKey: "ollamaModel")
        let source = "画面タイトル「Shop注文履歴」が表示されることの確認"
        TranslationStore.shared.request([source, "「現在の注文」「過去の注文」の2タブが表示されること"])
        for _ in 0..<120 where TranslationStore.shared.cache[source] == nil { try await Task.sleep(nanoseconds: 1_000_000_000) }
        let translated = try XCTUnwrap(TranslationStore.shared.cache[source])
        print("TRANSLATED:", translated)
        XCTAssertTrue(translated.contains("「Shop注文履歴」"), translated)
        XCTAssertNotEqual(translated, source)
    }
}
