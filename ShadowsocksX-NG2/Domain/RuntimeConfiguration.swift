/// 激活产出：活动目标身份 + 完整派生文档。组目标保持组 UUID（CONTEXT.md
/// 「Active target」），不被 sslocal 实际选中的后代替换。
struct RuntimeConfiguration: Equatable, Sendable {
  let targetID: NodeID
  let document: SslocalRuntimeDocument
}
