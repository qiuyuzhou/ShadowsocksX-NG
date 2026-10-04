import Foundation

// MARK: - 分享与 URI → 服务器叶子

extension CatalogWorkflow {
  /// 服务器 → ss://（SIP002，story 22）：凭据从存储解析；无凭据即点名失败
  /// （不分享空档）。仅在用户明确请求分享时调用。
  func shareURI(for id: NodeID) throws -> String {
    guard let entry = dependencies.coordinator.committedCatalog.entry(for: id),
      case .server(let fields) = entry.kind
    else { throw CatalogError.notAServer(id) }
    guard let password = try dependencies.credentials.secret(for: fields.passwordRef) else {
      throw CredentialStoreError.keychainStatus(errSecItemNotFound)
    }
    var pluginOptions: String?
    if let optionsRef = fields.pluginOptionsRef {
      pluginOptions = try dependencies.credentials.secret(for: optionsRef) ?? ""
    }
    return SsUri(
      method: fields.encryptionMethod,
      password: password,
      host: fields.address,
      port: fields.port,
      pluginProgram: fields.pluginProgram,
      pluginOptions: pluginOptions,
      remark: fields.remark.isEmpty ? nil : fields.remark
    ).encode()
  }

  // MARK: - URI 批量导入与叶子字段

  /// ss:// 批量导入（URL 表单和二维码识别入口的共同落点，story 20/21）。
  /// 逐行解码，可解析行全部添加（每次新建身份，不按内容去重）；每条失败行以
  /// 行号 + 类型化原因点名，已成功记录不被局部失败回滚。
  func createServers(fromURIs text: String, into parent: NodeID?) async throws
    -> BatchImportOutcome
  {
    var prepared: [(uri: SsUri, fields: ServerFields)] = []
    var failures: [ImportLineFailure] = []
    for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
      do {
        let uri = try SsUri.decode(String(line))
        let fields = try Self.serverFields(from: uri, credentials: dependencies.credentials)
        prepared.append((uri: uri, fields: fields))
      } catch {
        let reason: ImportLineFailureReason
        if let uriError = error as? SsUriError {
          reason = .decode(uriError)
        } else if let credentialError = error as? CredentialStoreError {
          reason = .credential(credentialError)
        } else {
          reason = .decode(.malformed(detail: String(describing: error)))
        }
        failures.append(ImportLineFailure(lineIndex: index, reason: reason))
      }
    }
    guard !prepared.isEmpty else { return BatchImportOutcome(addedCount: 0, failures: failures) }
    do {
      try commit { catalog in
        for item in prepared {
          try catalog.addServer(item.fields, to: parent)
        }
      }
    } catch {
      for item in prepared {
        Self.deleteCredentialRefs(for: item.fields, credentials: dependencies.credentials)
      }
      throw error
    }
    return BatchImportOutcome(addedCount: prepared.count, failures: failures)
  }

  /// URI → 服务器叶子字段：密码与插件参数入凭据存储、目录只持引用。
  static func serverFields(
    from uri: SsUri, credentials: CredentialStoring
  ) throws -> ServerFields {
    let passwordRef = CredentialReference.fresh()
    var pluginOptionsRef: CredentialReference?
    do {
      try credentials.save(uri.password, for: passwordRef)
      if uri.pluginProgram != nil, let options = uri.pluginOptions {
        let ref = CredentialReference.fresh()
        try credentials.save(options, for: ref)
        pluginOptionsRef = ref
      }
    } catch {
      try? credentials.delete(passwordRef)
      if let pluginOptionsRef { try? credentials.delete(pluginOptionsRef) }
      throw error
    }
    return ServerFields(
      address: uri.host,
      port: uri.port,
      encryptionMethod: uri.method,
      passwordRef: passwordRef,
      remark: uri.remark ?? "",
      pluginProgram: uri.pluginProgram,
      pluginOptionsRef: pluginOptionsRef)
  }

  static func serverFields(of entry: CatalogEntry) -> ServerFields? {
    if case .server(let fields) = entry.kind { return fields }
    return nil
  }

  /// 条目集合 → 待清理凭据引用（密码 + 可选插件参数）。
  static func credentialRefs(of entries: [CatalogEntry]) -> [CredentialReference] {
    entries.flatMap { entry -> [CredentialReference] in
      guard let fields = serverFields(of: entry) else { return [] }
      return [fields.passwordRef] + (fields.pluginOptionsRef.map { [$0] } ?? [])
    }
  }

  static func deleteCredentialRefs(
    for fields: ServerFields, credentials: CredentialStoring
  ) {
    try? credentials.delete(fields.passwordRef)
    if let optionsRef = fields.pluginOptionsRef { try? credentials.delete(optionsRef) }
  }

  /// 插件选择落盘（issue #38，D10/GLOSSARY.md 不变量）：「无」整体清除引用与
  /// 参数秘密；受管程序写引用、参数按空/非空经 journal 写删钥匙串；集外引用
  /// 原样保留（不因打开或保存表单而漂移，激活语义由状态机点名拒绝）。
  /// 受管集校验已由 `updateServer` 的表单校验完成。
  static func applyPluginSelection(
    _ selection: PluginSelection,
    options: String?,
    to fields: inout ServerFields,
    credentials: CredentialStoring,
    journal: inout CredentialWriteJournal
  ) throws {
    switch selection {
    case .none:
      if let reference = fields.pluginOptionsRef {
        journal.delete(reference)
      }
      fields.pluginProgram = nil
      fields.pluginOptionsRef = nil
    case .managed(let program):
      fields.pluginProgram = program
      let trimmedOptions = (options ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedOptions.isEmpty {
        if let reference = fields.pluginOptionsRef {
          journal.delete(reference)
        }
        fields.pluginOptionsRef = nil
      } else if let reference = fields.pluginOptionsRef {
        try journal.save(trimmedOptions, for: reference)
      } else {
        let reference = CredentialReference.fresh()
        try journal.save(trimmedOptions, for: reference)
        fields.pluginOptionsRef = reference
      }
    case .unknown:
      // Imported manual records may contain an unsupported plugin. Keep the opaque
      // reference unchanged while the user repairs another field or selects a
      // supported plugin explicitly.
      break
    }
  }
}
