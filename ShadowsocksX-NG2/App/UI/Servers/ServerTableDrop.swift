import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let serverCatalogNode = UTType(exportedAs: "com.qiuyuzhou.ShadowsocksX-NG2.catalog-node")
}

/// 行和列表空白使用同一个落点判定，避免拒绝的行退回根落点。
@MainActor
final class ServerTableDropState {
  weak var reader: ServerTableDropReaderView?
  private(set) var draggedID: NodeID?

  func provider(for id: NodeID, payload: String) -> NSItemProvider {
    draggedID = id
    let provider = NSItemProvider()
    let data = Data(payload.utf8)
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.serverCatalogNode.identifier, visibility: .ownProcess
    ) { completion in
      completion(data, nil)
      return nil
    }
    return provider
  }
}

/// SwiftUI TableRowContent 的 dropDestination 不能返回拒绝结果。
/// 此 Adapter 仅借用 NSTableView 的行命中检测，不替换 Table 或其 delegate。
struct ServerTableDropReader: NSViewRepresentable {
  let state: ServerTableDropState

  func makeNSView(context: Context) -> ServerTableDropReaderView {
    let view = ServerTableDropReaderView()
    state.reader = view
    return view
  }

  func updateNSView(_ nsView: ServerTableDropReaderView, context: Context) {
    state.reader = nsView
  }
}

final class ServerTableDropReaderView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// nil 表示尚未挂载、表头或行数不同步；-1 表示列表空白。
  func row(at point: CGPoint, expectedCount: Int) -> Int? {
    guard bounds.contains(point), let table = tableView(), table.numberOfRows == expectedCount
    else {
      return nil
    }
    if let header = table.headerView,
      header.bounds.contains(header.convert(point, from: self))
    {
      return nil
    }
    return table.row(at: table.convert(point, from: self))
  }

  private func tableView() -> NSTableView? {
    func find(in view: NSView) -> NSTableView? {
      if view === self { return nil }
      if let table = view as? NSTableView,
        bounds.intersects(convert(table.visibleRect, from: table))
      {
        return table
      }
      for child in view.subviews {
        if let table = find(in: child) { return table }
      }
      return nil
    }
    var ancestor = superview
    while let view = ancestor {
      if let table = find(in: view) { return table }
      ancestor = view.superview
    }
    return nil
  }
}

struct ServerTableDropDelegate: DropDelegate {
  let state: ServerTableDropState
  let rows: [CatalogTreeRow]
  let source: NodeSource
  let workflow: CatalogWorkflow
  let onDrop: ([String], NodeID?) -> Bool

  private enum Target {
    case root
    case group(NodeID)

    var id: NodeID? {
      switch self {
      case .root: nil
      case .group(let id): id
      }
    }
  }

  private func target(info: DropInfo) -> Target? {
    guard source == .manual, info.hasItemsConforming(to: [.serverCatalogNode]),
      let dragged = state.draggedID,
      let row = state.reader?.row(at: info.location, expectedCount: rows.count)
    else { return nil }
    let target: Target
    if row < 0 {
      target = .root
    } else {
      guard rows.indices.contains(row), rows[row].node.isGroup else { return nil }
      target = .group(rows[row].id)
    }
    return workflow.canMove(dragged, to: target.id) ? target : nil
  }

  func validateDrop(info: DropInfo) -> Bool { target(info: info) != nil }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: target(info: info) == nil ? .forbidden : .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let target = target(info: info), let expected = state.draggedID else { return false }
    let providers = info.itemProviders(for: [.serverCatalogNode])
    guard providers.count == 1, let provider = providers.first else { return false }
    provider.loadDataRepresentation(
      forTypeIdentifier: UTType.serverCatalogNode.identifier
    ) { data, _ in
      guard let data, String(data: data, encoding: .utf8) == expected.rawValue else { return }
      Task { @MainActor in
        _ = onDrop([expected.rawValue], target.id)
      }
    }
    return true
  }
}
