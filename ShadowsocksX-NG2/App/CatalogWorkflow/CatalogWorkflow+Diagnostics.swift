import Foundation

/// 诊断导出的目录事实（issue #34/#41，story 40）：目录计数经 module 内部填充，
/// 原始目录与凭据不出 module；快照只含脱敏数量元数据（D5）。
extension CatalogWorkflow {
  /// 把目录数量事实填入诊断快照（服务器/分组/来源/插件计数与已知无效数）。
  func fillDiagnosticCatalogFacts(into snapshot: inout DiagnosticSnapshot) {
    snapshot.catalog = coordinator.committedCatalog
    snapshot.knownInvalidServerCount = tree.invalidServerCount
  }
}
