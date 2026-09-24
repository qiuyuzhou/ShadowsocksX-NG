import Foundation

/// The single application presentation edge. Domain and workflow modules expose
/// typed errors/facts; this file is the only place that turns them into text.
extension Error {
  var presentableMessage: String {
    AppPresentation.message(for: self)
  }
}

enum AppPresentation {
  static let unknownError = "操作失败，请重试或检查设置"
}

extension AppPresentation {
  // The presentation edge deliberately dispatches across the app's typed
  // failure families; keeping this switch explicit makes the whitelist auditable.
  // swiftlint:disable:next cyclomatic_complexity
  static func message(for error: Error) -> String {
    switch error {
    case let error as CatalogError:
      return catalog(error)
    case let error as ActivationFailure:
      return activation(error)
    case let error as ServerFormError:
      return serverForm(error)
    case let error as SsUriError:
      return ssURI(error)
    case let error as CredentialStoreError:
      return credential(error)
    case let error as SubscriptionFormError:
      return subscriptionForm(error)
    case let error as SubscriptionFetchError:
      return subscriptionFetch(error)
    case let error as SubscriptionParseError:
      return subscriptionParse(error)
    case let error as SubscriptionRefreshCommitError:
      return message(
        for: .commit(
          category: error.category,
          rollback: SubscriptionRefreshFailure.rollbackStatus(for: error.rollback)))
    case let error as SettingsWorkflowFailure:
      return message(for: error)
    case let error as RuntimeFailureFacts:
      return message(for: error)
    case let error as ImportLineFailureReason:
      return importLine(error)
    case let error as CommitError:
      return commit(error)
    case let error as ProxyModeError:
      return proxyMode(error)
    case let error as PortSettingError:
      return port(error)
    case let error as ProxySettingsValidationError:
      return settingsValidation(error)
    case let error as ProxySettingsStoreError:
      return settingsStore(error)
    case let error as ListenSettingsStoreError:
      return listenStore(error)
    case let error as LegacyImportError:
      return legacyImport(error)
    case let error as PACServerError:
      return pacServer(error)
    case let error as SystemProxyError:
      return systemProxy(error)
    case let error as SystemProxyOwnershipStoreError:
      return ownershipStore(error)
    case let error as TextClipboardFailure:
      return textClipboard(error)
    case let error as DiagnosticReportFailure:
      return diagnosticReport(error)
    case let error as DiagnosticReportExportFailure:
      return diagnosticReportExport(error)
    default:
      return unknownError
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func message(for failure: SubscriptionRefreshFailure) -> String {
    switch failure {
    case .invalidURL:
      return "订阅地址无效"
    case .unsupportedScheme:
      return "订阅地址必须是 HTTPS"
    case .insecureRedirect:
      return "订阅地址重定向到了非 HTTPS 站点，已拒绝"
    case .transport(let category):
      switch category {
      case .timedOut: return "订阅获取超时"
      case .tls: return "订阅安全连接失败"
      case .connection: return "订阅连接失败"
      case .unknown: return "订阅获取失败"
      }
    case .httpStatus(let code):
      return "订阅服务器返回 HTTP \(code)"
    case .contentType(let category):
      return category == .missing
        ? "订阅响应缺少 JSON Content-Type"
        : "订阅响应类型不是 JSON"
    case .decodingFailure:
      return "订阅内容不是合法的 SIP-008 JSON 文档"
    case .unsupportedSchemaVersion:
      return "订阅文档版本不受支持"
    case .missingServers:
      return "订阅文档缺少 servers 列表"
    case .recordValidation(let index, let field):
      return "订阅第 \(index + 1) 条服务器记录的\(recordFieldName(field))无效"
    case .duplicateIdentity:
      return "订阅包含重复的服务器身份"
    case .credential(let category):
      switch category {
      case .missing: return "订阅凭据不存在"
      case .read: return "订阅凭据读取失败"
      case .write: return "订阅凭据写入失败"
      }
    case .commit(let category, let rollback):
      let commitMessage = category == .credentials ? "订阅凭据提交失败" : "订阅快照保存失败"
      switch rollback {
      case .notNeeded: return commitMessage
      case .restored: return "\(commitMessage)，旧凭据已恢复"
      case .incomplete: return "\(commitMessage)，凭据恢复不完整；最后一次成功快照仍保留"
      }
    case .legacy:
      return "订阅刷新失败（旧版失败记录）"
    case .unknown:
      return unknownError
    }
  }

  static func message(for confirmation: SettingsConfirmation) -> String {
    switch confirmation {
    case .pacInvalidation(let previousPort, let nextPort):
      return "PAC 端口将从 \(previousPort) 改为 \(nextPort)，已分享的 PAC URL 将失效，保存后需要重新分享"
    case .resetPreferences:
      return "端口、监听范围和 PAC 设置等全部偏好都会恢复为出厂值，运行中的代理会停止。"
    }
  }

  static func message(for issue: SettingsFieldIssue) -> String {
    switch issue {
    case .port(_, let error), .advertisedAddress(let error), .timeoutSeconds(let error),
      .gfwListURL(let error):
      return message(for: error)
    }
  }

  static func message(for reason: LegacySkippedRecord.Reason) -> String {
    switch reason {
    case .notDictionary: return "记录不是字典"
    case .invalidAddress: return "服务器地址缺失或无效"
    case .invalidPort: return "服务器端口缺失或无效"
    case .invalidEncryptionMethod: return "加密方式缺失或无效"
    case .missingPassword: return "密码缺失或为空"
    }
  }

  static func message(for failure: SettingsWorkflowFailure) -> String {
    switch failure {
    case .store(let error): return settingsStore(error)
    case .mode(let error): return proxyMode(error)
    case .runtime(let runtimeFailure):
      return runtimeFailure.map { message(for: $0) } ?? unknownError
    case .unknown: return unknownError
    }
  }

  static func message(for failure: RuntimeFailureFacts) -> String {
    switch failure {
    case .firewallBlocked(let facts):
      return
        "macOS 防火墙已阻止 \(facts.executableName) 接受传入连接。请在系统设置中允许传入连接。"
    case .launch(let facts): return launchFailure(facts)
    case .service(let facts): return serviceFailure(facts)
    case .activation(let error): return activation(error)
    case .requiresApproval: return "请在系统设置的登录项中允许代理后台服务"
    case .systemProxy(let facts): return systemProxyFailure(facts)
    }
  }

  static func message(for state: ProxyRuntimeController.ProxyState) -> String {
    switch state {
    case .off: return "代理未运行"
    case .starting: return "代理正在启动"
    case .running: return "代理运行中"
    case .firewallBlocked(let facts):
      return message(for: RuntimeFailureFacts.firewallBlocked(facts))
    case .launchFailed(let facts): return message(for: RuntimeFailureFacts.launch(facts))
    case .activationFailed(let failure):
      return message(for: RuntimeFailureFacts.activation(failure))
    case .requiresApproval: return message(for: RuntimeFailureFacts.requiresApproval)
    case .serviceFailed(let facts): return message(for: RuntimeFailureFacts.service(facts))
    case .systemProxyFailed(let facts):
      return message(for: RuntimeFailureFacts.systemProxy(facts))
    }
  }

  private static func catalog(_ error: CatalogError) -> String {
    switch error {
    case .nodeNotFound: return "节点不存在（可能已被删除）"
    case .parentNotFound: return "目标分组不存在"
    case .parentNotAGroup: return "目标位置不是分组"
    case .notAServer: return "该节点不是服务器"
    case .notAGroup: return "该节点不是分组"
    case .duplicateID: return "节点身份冲突"
    case .crossSourcePlacement(_, let container):
      return container == .subscription ? "不能把手动节点移入订阅子树" : "不能把订阅节点移入手动子树"
    case .subscriptionNodeImmutable: return "订阅节点由远端管理：结构、连接字段与名称只读"
    case .subscriptionServerAtRoot: return "订阅服务器不能移出其订阅分组"
    case .cycleDetected: return "不能把分组移动进它自己的子树"
    case .indexOutOfRange: return "插入位置超出范围"
    case .invalidStructure: return "配置目录结构不一致"
    }
  }

  private static func activation(_ error: ActivationFailure) -> String {
    switch error {
    case .noActiveTarget: return "尚未激活任何服务器或分组，请先选择一个目标"
    case .targetNotFound: return "活动目标不存在，代理已停止"
    case .targetExpandsToNothing: return "目标没有可激活的服务器"
    case .invalidLeaf(let node, let reason):
      return "服务器不可用：\(leaf(reason))（\(shortNodeID(node))）"
    }
  }

  private static func leaf(_ reason: LeafInvalidationReason) -> String {
    switch reason {
    case .invalidAddress: return "地址无效"
    case .invalidPort: return "端口无效"
    case .missingEncryptionMethod: return "缺少加密方法"
    case .unsupportedEncryptionMethod: return "加密方法不受支持"
    case .pluginNotProvided: return "插件未提供"
    case .credentialUnresolved: return "凭据不存在"
    case .credentialReadFailed: return "凭据读取失败"
    }
  }

  private static func serverForm(_ error: ServerFormError) -> String {
    switch error {
    case .invalidAddress: return "服务器地址不能为空"
    case .invalidPort: return "端口必须是 1–65535 之间的整数"
    case .missingEncryptionMethod: return "必须选择加密方法"
    case .unsupportedEncryptionMethod: return "当前 sslocal 不支持该加密方法"
    case .invalidPassword: return "密码不能为空"
    case .emptyName: return "名称不能为空"
    case .pluginNotManaged: return "本版本未提供所选插件"
    }
  }

  private static func ssURI(_ error: SsUriError) -> String {
    switch error {
    case .notSsUri: return "不是 ss:// 链接"
    case .malformed: return "无法解析 ss:// 链接"
    }
  }

  private static func credential(_ error: CredentialStoreError) -> String {
    switch error {
    case .keychainStatus: return "钥匙串操作失败"
    case .secretNotUTF8: return "钥匙串中的凭据不是文本"
    }
  }

  private static func subscriptionForm(_ error: SubscriptionFormError) -> String {
    switch error {
    case .invalidURL: return "订阅地址必须是有效的 HTTPS URL"
    case .notFound: return "订阅不存在（可能已被删除）"
    }
  }

  private static func subscriptionFetch(_ error: SubscriptionFetchError) -> String {
    message(for: SubscriptionRefreshFailure.from(fetchError: error))
  }

  private static func subscriptionParse(_ error: SubscriptionParseError) -> String {
    message(for: SubscriptionRefreshFailure.from(parseError: error))
  }

  private static func importLine(_ error: ImportLineFailureReason) -> String {
    switch error {
    case .decode(let error): return ssURI(error)
    case .credential(let error): return credential(error)
    }
  }

  private static func commit(_ error: CommitError) -> String {
    switch error.credentialRollback {
    case .partial:
      return "\(message(for: error.underlying))；凭据恢复不完整，请检查配置后重试"
    case .nothingToRestore, .restored:
      return message(for: error.underlying)
    }
  }

  private static func proxyMode(_ error: ProxyModeError) -> String {
    switch error {
    case .invalidLocalPACURL: return "本地 PAC URL 无效"
    case .invalidSOCKSPort: return "SOCKS 端口无效"
    }
  }

  private static func port(_ error: PortSettingError) -> String {
    switch error {
    case .portOutOfRange(let endpoint, let portNumber):
      return "\(endpoint.displayName) 端口 \(portNumber) 无效，必须是 1–65535 之间的整数"
    case .duplicatePort(let endpoint, let otherEndpoint, let portNumber):
      return
        "\(endpoint.displayName) 端口与 \(otherEndpoint.displayName) 端口冲突（都是 \(portNumber)），请为每个端点配置不同的端口"
    }
  }

  private static func settingsValidation(_ error: ProxySettingsValidationError) -> String {
    switch error {
    case .portOutOfRange(let endpoint, let port):
      return Self.port(.portOutOfRange(endpoint: endpoint, port: port))
    case .duplicatePort(let endpoint, let otherEndpoint, let port):
      return Self.port(.duplicatePort(endpoint: endpoint, otherEndpoint: otherEndpoint, port: port))
    case .invalidTimeout(let seconds):
      return "超时 \(seconds) 秒无效，必须是 1–86400 之间的整数"
    case .invalidHostAddress: return "主机地址无效，必须是非回环 IPv4 地址"
    case .invalidGFWListURL: return "GFW List URL 无效"
    }
  }

  private static func settingsStore(_ error: ProxySettingsStoreError) -> String {
    switch error {
    case .corrupt: return "偏好文件损坏"
    case .invalid(let errors): return errors.map(settingsValidation).joined(separator: "；")
    case .ioFailure: return "偏好文件读写失败"
    case .missingCredential: return "偏好中的敏感 URL 无法从钥匙串读取"
    case .credentialFailure: return "偏好中的敏感 URL 无法写入钥匙串"
    case .rollbackFailed: return "偏好保存失败，旧设置或凭据未能完整恢复"
    case .legacyListenSettings(let error): return "旧版监听设置无法读取：\(listenStore(error))"
    }
  }

  private static func listenStore(_ error: ListenSettingsStoreError) -> String {
    switch error {
    case .corrupt: return "监听设置文件损坏"
    case .invalidPorts(let errors): return errors.map(port).joined(separator: "；")
    case .ioFailure: return "监听设置文件读取失败"
    }
  }

  private static func legacyImport(_ error: LegacyImportError) -> String {
    switch error {
    case .noSnapshot: return "没有发现可导入的 Legacy 配置"
    case .alreadyCompleted: return "Legacy 配置已经导入；如需再次导入，请明确选择再次导入"
    case .malformedSnapshot: return "Legacy 快照无效"
    case .commitFailed: return "Legacy 导入未完成，2.0 写入未完成"
    }
  }

  private static func pacServer(_ error: PACServerError) -> String {
    switch error {
    case .invalidPort: return "PAC 端口无效"
    case .startFailed: return "PAC 服务启动失败"
    case .startTimedOut: return "PAC 服务启动超时"
    }
  }

  private static func systemProxy(_ error: SystemProxyError) -> String {
    switch error {
    case .authorizationFailed: return "没有获得修改系统代理所需的授权"
    case .preferencesUnavailable: return "系统网络配置不可用"
    case .preferencesBusy: return "系统网络配置正被其他设置操作占用"
    case .noCurrentNetworkSet: return "没有当前网络位置"
    case .noProxyServices: return "当前网络位置没有可写入的网络服务"
    case .unreadableService: return "无法读取网络服务的代理配置"
    case .ownershipConflict: return "系统代理配置已被其他设置改动，未覆盖"
    case .invalidStoredConfiguration: return "保存的系统代理配置无效"
    case .cannotWriteService: return "无法写入网络服务的代理配置"
    case .commitFailed: return "系统代理提交失败"
    case .applyFailed: return "系统代理应用失败"
    case .ownershipStoreFailed: return "系统代理所有权记录失败"
    }
  }

  private static func ownershipStore(_ error: SystemProxyOwnershipStoreError) -> String {
    switch error {
    case .readFailed: return "系统代理所有权记录读取失败"
    case .writeFailed: return "系统代理所有权记录写入失败"
    case .invalidRecord: return "系统代理所有权记录无效"
    }
  }

  private static func textClipboard(_ error: TextClipboardFailure) -> String {
    switch error {
    case .writeFailed: return "剪贴板写入失败，请重试"
    }
  }

  private static func diagnosticReport(_ error: DiagnosticReportFailure) -> String {
    switch error {
    case .encodingFailed: return "诊断报告无法安全构造，请重试"
    }
  }

  private static func diagnosticReportExport(_ error: DiagnosticReportExportFailure) -> String {
    switch error {
    case .writeFailed: return "诊断报告写入失败，请选择其他位置或重试"
    }
  }

  private static func launchFailure(_ facts: LaunchFailureFacts) -> String {
    switch facts {
    case .missingRuntimeDocument: return "缺少运行时文档"
    case .localEndpoint(let endpoint, let host, let port, let cause):
      return "本地代理 \(endpoint.uppercased()) 端点 \(host):\(port) 未就绪（\(endpointFailure(cause))）"
    case .pacEndpoint(let port, let cause):
      return "PAC 端点端口 \(port) 未就绪（\(endpointFailure(cause))）"
    case .unreadableSettings: return "本地代理配置无法读取，已停止代理以避免静默改用出厂端口"
    }
  }

  private static func serviceFailure(_ facts: ServiceFailureFacts) -> String {
    switch facts {
    case .runtimeFile: return "运行时文件读写失败"
    case .agent: return "代理后台服务管理失败"
    case .missingDocument: return "缺少运行时文档"
    case .persistence: return "代理运行状态保存失败"
    case .unknown: return unknownError
    }
  }

  private static func systemProxyFailure(_ facts: SystemProxyFailureFacts) -> String {
    switch facts {
    case .operation(let failure): return systemProxy(failure)
    case .mode(let error): return proxyMode(error)
    case .ownershipConflict: return "系统代理配置已被其他设置改动，未覆盖"
    case .unknown: return "系统代理未能应用"
    }
  }

  private static func systemProxy(_ failure: SystemProxyOperationFailure) -> String {
    switch failure {
    case .authorizationFailed: return "没有获得修改系统代理所需的授权"
    case .preferencesUnavailable: return "系统网络配置不可用"
    case .preferencesBusy: return "系统网络配置正被其他设置操作占用"
    case .noCurrentNetworkSet: return "没有当前网络位置"
    case .noProxyServices: return "当前网络位置没有可写入的网络服务"
    case .unreadableService: return "无法读取网络服务的代理配置"
    case .invalidStoredConfiguration: return "保存的系统代理配置无效"
    case .cannotWriteService: return "无法写入网络服务的代理配置"
    case .commitFailed: return "系统代理提交失败"
    case .applyFailed: return "系统代理应用失败"
    case .ownershipStoreFailed: return "系统代理所有权记录失败"
    }
  }

  private static func endpointFailure(_ outcome: RuntimeEndpointFailure) -> String {
    switch outcome {
    case .refused: return "连接被拒绝"
    case .timedOut: return "连接超时"
    case .invalidResponse: return "响应无效"
    case .unknown: return "状态无法确定"
    }
  }

  private static func recordFieldName(_ field: SubscriptionRefreshFailure.RecordField) -> String {
    switch field {
    case .address: return "服务器地址"
    case .port: return "服务器端口"
    case .method: return "加密方法"
    case .password: return "密码"
    case .identity: return "身份"
    }
  }

  private static func shortNodeID(_ id: NodeID) -> String {
    String(id.rawValue.suffix(8))
  }
}
