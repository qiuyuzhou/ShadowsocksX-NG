/// 状态机对运行时的效应，由 #27 的运行时接线消费。
enum ActivationEffect: Equatable, Sendable {
  /// 原子更新运行时（首次激活、重激活或子树编辑重展开成功）。
  case deployed(RuntimeConfiguration)
  /// 清除活动目标并停止代理（点名原因，无静默回退）。
  case clearedAndStopped(ActivationFailure)
}

/// 激活状态机（spec #21 D3 激活族）：持久化活动目标（服务器或分组的节点身份）。
/// 激活是单缝原子操作——成功替换目标并产出派生文档，失败点名原因且状态不动；
/// 目录提交后立即重展开，目标失效即清除并发出停止意图。运行时文件写入与
/// 进程启停由 #27 消费本层产出。
struct ActivationStateMachine: Equatable, Sendable {
  /// 当前活动目标；`nil` 即无目标（代理不应运行）。
  private(set) var activeTargetID: NodeID?

  /// 从持久化恢复（`ActivationStateFileStore`）；恢复后的有效性由下一次
  /// `catalogDidCommit` 重校验同步（D5「GUI 下次启动重新校验同步」）。
  init(activeTargetID: NodeID? = nil) {
    self.activeTargetID = activeTargetID
  }

  /// 显式激活。成功：目标替换、返回派生文档；失败：抛点名原因，状态完全不动
  /// （保留原目标与运行状态，无静默回退）。
  mutating func activate(
    _ target: NodeID,
    in catalog: ConfigurationCatalog,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding,
    listen: SslocalListenSettings
  ) throws -> RuntimeConfiguration {
    let outcome = derive(
      target: target, in: catalog, credentials: credentials, plugins: plugins, listen: listen)
    switch outcome {
    case .success(let configuration):
      activeTargetID = target
      return configuration
    case .failure(let failure):
      throw failure
    }
  }

  /// 目录已提交变更后的立即重展开。返回 `nil` 表示无事可做（无活动目标）；
  /// 有效非空 → `.deployed`（原子更新）；目标被删除/禁用/变空/含无效叶子 →
  /// 清除目标并返回 `.clearedAndStopped`（点名原因）。任何目录提交（含与活动
  /// 目标无关的编辑）都整体重校验重展开：产出对相同输入幂等，由 #27 决定是否
  /// 跳过相同内容的运行时写入。
  mutating func catalogDidCommit(
    _ catalog: ConfigurationCatalog,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding,
    listen: SslocalListenSettings
  ) -> ActivationEffect? {
    guard let target = activeTargetID else { return nil }
    let outcome = derive(
      target: target, in: catalog, credentials: credentials, plugins: plugins, listen: listen)
    switch outcome {
    case .success(let configuration):
      return .deployed(configuration)
    case .failure(let failure):
      activeTargetID = nil
      return .clearedAndStopped(failure)
    }
  }

  // MARK: - 展开、校验与派生

  /// 单缝派生：目标存在 → 有效启用 → 显式子序深度优先展开叶子 → 非空 →
  /// 逐叶校验并解析凭据。任何一步失败都返回点名原因，不产出部分结果。
  private func derive(
    target: NodeID,
    in catalog: ConfigurationCatalog,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding,
    listen: SslocalListenSettings
  ) -> Result<RuntimeConfiguration, ActivationFailure> {
    guard catalog.contains(target) else { return .failure(.targetNotFound(target)) }
    if let disabledNode = firstDisabledNode(from: target, in: catalog) {
      return .failure(.targetDisabled(disabledNode))
    }
    var leaves: [NodeID] = []
    if case .server = catalog.entry(for: target)?.kind {
      leaves = [target]
    } else {
      collectEnabledLeaves(of: target, in: catalog, into: &leaves)
    }
    guard !leaves.isEmpty else { return .failure(.targetExpandsToNothing(target)) }

    var servers: [SslocalServerDocument] = []
    for leafID in leaves {
      switch derivedServer(leafID, in: catalog, credentials: credentials, plugins: plugins) {
      case .success(let server):
        servers.append(server)
      case .failure(let failure):
        return .failure(failure)
      }
    }
    return .success(
      RuntimeConfiguration(
        targetID: target,
        document: SslocalRuntimeDocument(
          servers: servers,
          listen: listen)))
  }

  /// 目标→根路径上第一个禁用节点；全部启用返回 `nil`。
  private func firstDisabledNode(from target: NodeID, in catalog: ConfigurationCatalog) -> NodeID? {
    ([target] + catalog.ancestors(of: target)).first {
      catalog.entry(for: $0)?.enabled == false
    }
  }

  /// 按显式子序深度优先收集有效启用的服务器叶子；禁用分组整棵跳过。
  /// 目录结构不变量（子引用必存在、目标必为分组）由构造校验保证，失约即程序错误。
  private func collectEnabledLeaves(
    of groupID: NodeID,
    in catalog: ConfigurationCatalog,
    into leaves: inout [NodeID]
  ) {
    guard case .group(let fields) = catalog.entry(for: groupID)?.kind else {
      preconditionFailure("展开目标已先行校验为分组")
    }
    for child in fields.children {
      guard let entry = catalog.entry(for: child) else {
        preconditionFailure("目录结构不变量：子引用必存在")
      }
      guard entry.enabled else { continue }
      switch entry.kind {
      case .server:
        leaves.append(child)
      case .group:
        collectEnabledLeaves(of: child, in: catalog, into: &leaves)
      }
    }
  }

  /// 校验单个有效启用叶子并解析为上游条目；凭据在派生时从凭据存储解析（D5）。
  private func derivedServer(
    _ leafID: NodeID,
    in catalog: ConfigurationCatalog,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding
  ) -> Result<SslocalServerDocument, ActivationFailure> {
    guard let entry = catalog.entry(for: leafID), case .server(let fields) = entry.kind else {
      preconditionFailure("展开结果只含服务器叶子")
    }
    let password: String
    switch resolveCredential(fields.passwordRef, of: leafID, credentials: credentials) {
    case .success(let resolved):
      password = resolved
    case .failure(let failure):
      return .failure(failure)
    }
    var pluginPath: String?
    var pluginOpts: String?
    if let program = fields.pluginProgram {
      guard let path = plugins.executablePath(forProgram: program) else {
        return .failure(.invalidLeaf(node: leafID, reason: .pluginNotProvided(program: program)))
      }
      pluginPath = path
      if let optionsRef = fields.pluginOptionsRef {
        switch resolveCredential(optionsRef, of: leafID, credentials: credentials) {
        case .success(let resolved):
          pluginOpts = resolved
        case .failure(let failure):
          return .failure(failure)
        }
      }
    }
    return .success(
      SslocalServerDocument(
        id: leafID.rawValue,
        remarks: fields.remark,
        server: fields.address,
        serverPort: fields.port,
        password: password,
        method: fields.encryptionMethod,
        plugin: pluginPath,
        pluginOpts: pluginOpts))
  }

  /// 凭据解析：无条目与读取失败分别点名（D5「凭据不可解析 → 停止并清理」）。
  private func resolveCredential(
    _ reference: CredentialReference,
    of leafID: NodeID,
    credentials: CredentialStoring
  ) -> Result<String, ActivationFailure> {
    do {
      guard let secret = try credentials.secret(for: reference) else {
        return .failure(.invalidLeaf(node: leafID, reason: .credentialUnresolved(reference)))
      }
      return .success(secret)
    } catch {
      return .failure(.invalidLeaf(node: leafID, reason: .credentialReadFailed(reference)))
    }
  }
}
