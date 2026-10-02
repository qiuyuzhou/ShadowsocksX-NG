import SwiftUI

struct RulesSourceDetailsView: View {
  let source: RulesSourceSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if let metadata = source.metadata {
        Text(verbatim: "\(source.id.label) · \(metadata.source.upstreamVersion)")
        Text(verbatim: metadata.upstreamReference)
        Text(verbatim: "\(metadata.license) · \(metadata.attribution)")
        if let report = source.conversionReport {
          DisclosureGroup(RulesCopy.text("快照制作时的转换报告")) {
            Text(
              verbatim:
                "\(RulesCopy.text("已转换")): \(report.convertedCount), \(RulesCopy.text("已吸收")): \(report.absorbedCount)"
            )
            Text(verbatim: "\(RulesCopy.text("已跳过")): \(counts(report.skipped))")
            Text(verbatim: "\(RulesCopy.text("已拒绝")): \(counts(report.rejected))")
            ForEach(report.notes, id: \.self) { Text(verbatim: $0) }
          }
        }
      }
    }.font(.caption).textSelection(.enabled)
  }

  private func counts(_ values: [String: Int]) -> String {
    values.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
  }
}
