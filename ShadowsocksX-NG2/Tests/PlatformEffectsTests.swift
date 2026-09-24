import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class TextClipboardTests: XCTestCase {
  func testMissingTextIsNormalEmptyState() {
    let clipboard = InMemoryTextClipboard()

    XCTAssertNil(clipboard.read())
  }

  func testPlainTextCanBeWrittenAndReadBack() throws {
    let clipboard = InMemoryTextClipboard()

    try clipboard.write("ss://example")

    XCTAssertEqual(clipboard.read(), "ss://example")
  }

  func testWriteFailureIsTypedAndDoesNotExposePlatformDetails() {
    let clipboard = InMemoryTextClipboard(writeFailure: .writeFailed)

    XCTAssertThrowsError(try clipboard.write("secret")) { error in
      XCTAssertEqual(error as? TextClipboardFailure, .writeFailed)
    }
  }
}

@MainActor
final class DiagnosticReportExportActionTests: DiagnosticsWorkflowTestCase {
  func testCancelledExportDoesNotRecordCompletion() {
    let workflow = makeWorkflow(catalog: { DiagnosticCatalogFacts() })
    let exporter = InMemoryDiagnosticReportExporter(result: .cancelled)

    let outcome = DiagnosticReportExportAction(
      diagnostics: workflow, exporter: exporter
    ).perform()

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(exporter.drafts.count, 1)
    XCTAssertTrue(events.snapshot.isEmpty)
  }

  func testFailedExportDoesNotRecordCompletion() {
    let workflow = makeWorkflow(catalog: { DiagnosticCatalogFacts() })
    let exporter = InMemoryDiagnosticReportExporter(result: .failed(.writeFailed))

    let outcome = DiagnosticReportExportAction(
      diagnostics: workflow, exporter: exporter
    ).perform()

    XCTAssertEqual(outcome, .exportFailed(.writeFailed))
    XCTAssertEqual(exporter.drafts.count, 1)
    XCTAssertTrue(events.snapshot.isEmpty)
  }

  func testSuccessfulExportReturnsSelectedURLBeforeCompletionIsRecorded() throws {
    let workflow = makeWorkflow(catalog: { DiagnosticCatalogFacts() })
    let url = workDir.appendingPathComponent("diagnostics.txt")
    let exporter = InMemoryDiagnosticReportExporter(result: .saved(url))

    let outcome = DiagnosticReportExportAction(
      diagnostics: workflow, exporter: exporter
    ).perform()

    XCTAssertEqual(outcome, .saved(url))
    XCTAssertTrue(events.snapshot.isEmpty)

    workflow.noteExportCompleted()

    let exportedEvents = events.snapshot.filter { entry in
      if case .diagnosticsExported = entry.event { return true }
      return false
    }
    XCTAssertEqual(exportedEvents.count, 1)
  }

  func testReportPreparationFailureDoesNotOpenExporterOrRecordCompletion() {
    let workflow = makeWorkflow(
      catalog: { DiagnosticCatalogFacts() },
      render: { _ in nil })
    let exporter = InMemoryDiagnosticReportExporter(result: .cancelled)

    let outcome = DiagnosticReportExportAction(
      diagnostics: workflow, exporter: exporter
    ).perform()

    XCTAssertEqual(outcome, .preparationFailed(.encodingFailed))
    XCTAssertTrue(exporter.drafts.isEmpty)
    XCTAssertTrue(events.snapshot.isEmpty)
  }
}

final class PlatformEffectsArchitectureTests: XCTestCase {
  func testClipboardAndDiagnosticExportAppKitSymbolsStayInFocusedAdapters() throws {
    let appDirectory = Self.testTargetRoot.appendingPathComponent("App")
    let sourceFiles = try Self.swiftSourceFiles(in: appDirectory)

    let pasteboardUsers = try Self.files(containing: "NSPasteboard", in: sourceFiles)
    XCTAssertEqual(
      pasteboardUsers.map(\.lastPathComponent), ["AppKitTextClipboard.swift"],
      "纯文本 pasteboard 访问必须集中在 AppKitTextClipboard adapter")

    let savePanelUsers = try Self.files(containing: "NSSavePanel", in: sourceFiles)
    XCTAssertEqual(
      savePanelUsers.map(\.lastPathComponent), ["AppKitDiagnosticReportExporter.swift"],
      "保存面板访问必须集中在 AppKitDiagnosticReportExporter adapter")

    let reportWriterUsers = try Self.files(containing: ".data.write(to:", in: sourceFiles)
    XCTAssertEqual(
      reportWriterUsers.map(\.lastPathComponent), ["AppKitDiagnosticReportExporter.swift"],
      "诊断报告文件写入必须集中在 AppKitDiagnosticReportExporter adapter")
  }

  private static let testTargetRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

  private static func swiftSourceFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil)
    else {
      XCTFail("无法枚举 App 源码目录：\(directory.path)")
      return []
    }
    return enumerator.compactMap { item in
      guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
      return url
    }
  }

  private static func files(containing token: String, in files: [URL]) throws -> [URL] {
    var matches: [URL] = []
    for file in files where (try? String(contentsOf: file, encoding: .utf8).contains(token)) == true
    {
      matches.append(file)
    }
    return matches
  }
}
