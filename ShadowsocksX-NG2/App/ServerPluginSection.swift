import SwiftUI

/// 服务器详情的插件区（issue #38/D10，地图 #52 票 #55）：受管选择器——
/// 「无」+ 受管列表；集外引用（Legacy 导入/订阅带入）追加显式「本版本未
/// 提供」项使当前状态可见并原样保留。选中受管项才显示参数编辑区与可用性
/// 警告。订阅只读面无可编辑入口，但仍可切换参数查看模式（issue #81）。
struct ServerPluginSection: View {
  @Binding var selection: PluginSelection
  @ObservedObject var options: PluginOptionsDraft
  let plugin: PluginSectionState?
  let isEditable: Bool
  /// 参数字段的行内校验错误（issue #81：字节超限或未完成行）。
  let optionsError: ServerFormFieldError?
  let optionsFocus: FocusState<ServerFormField?>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      picker
      detail
    }
  }

  @ViewBuilder
  private var picker: some View {
    if let plugin {
      Picker("插件", selection: $selection) {
        Text("无").tag(PluginSelection.none)
        ForEach(plugin.managed, id: \.program) { info in
          Text(info.program).tag(PluginSelection.managed(program: info.program))
        }
        if case .unknown(let program) = plugin.selection {
          Text("\(program)（本版本未提供）").tag(PluginSelection.unknown(program: program))
        }
      }
      .labelsHidden()
      .accessibilityLabel("插件")
      .disabled(!isEditable)
    } else {
      Text("不可用").foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let plugin {
      switch selection {
      case .none:
        EmptyView()
      case .managed(let program):
        managedDetails(program: program, plugin: plugin)
      case .unknown(let program):
        unknownNotice(program: program, plugin: plugin)
      }
    }
  }

  /// 选中受管项：参数编辑区与可用性警告。
  @ViewBuilder
  private func managedDetails(program: String, plugin: PluginSectionState) -> some View {
    if plugin.managed.contains(where: { $0.program == program }) {
      VStack(alignment: .leading, spacing: 8) {
        if !plugin.provided {
          Label(
            "受管插件可执行文件缺失：激活会被点名拒绝；请重新安装本 app。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.footnote)
          .foregroundStyle(.orange)
        }
        Text("插件参数")
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
        PluginOptionsEditor(
          draft: options,
          isEditable: isEditable,
          fieldError: optionsError,
          fieldFocus: optionsFocus)
      }
    }
  }

  /// 集外引用：原样保留并明确指出当前 app 无法提供该插件。
  @ViewBuilder
  private func unknownNotice(program: String, plugin: PluginSectionState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "本版本未提供「\(program)」：引用原样保留，激活包含该服务器会被点名拒绝；可改选「无」或受管插件。",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.footnote)
      .foregroundStyle(.orange)
      if plugin.optionsPresent {
        Text("插件参数已配置（存于钥匙串，原样保留）。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// 插件参数编辑区（issue #81）：参数列表 ⇄ 原始文本双模式、底部空行快速
/// 添加、行内编辑与删除、长值独立编辑；切换查看模式不触发表单变更检测。
private struct PluginOptionsEditor: View {
  @ObservedObject var draft: PluginOptionsDraft
  let isEditable: Bool
  let fieldError: ServerFormFieldError?
  let fieldFocus: FocusState<ServerFormField?>.Binding

  struct EditingValue: Identifiable {
    let id: UUID
    let text: String
  }

  /// 模式选择器的显示态：切换被未完成行拒绝时回弹到当前模式。
  @State private var displayedMode = PluginOptionsDraft.Mode.table
  @State private var editingValue: EditingValue?
  @FocusState private var focusedRowID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("查看模式", selection: modeBinding) {
        Text("参数列表").tag(PluginOptionsDraft.Mode.table)
        Text("原始文本").tag(PluginOptionsDraft.Mode.rawText)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch draft.mode {
      case .table:
        tableView
      case .rawText:
        rawTextView
      }
      fieldErrorLabel
    }
    .onChange(of: draft.mode) { _, mode in
      displayedMode = mode
    }
    .onChange(of: fieldError) { _, error in
      // 首错定位：未完成行时聚焦第一行的参数名。
      if case .unfinishedPluginOptionRow = error,
        let first = draft.rows.first(where: \.isUnfinished)
      {
        focusedRowID = first.id
      }
    }
    .sheet(item: $editingValue) { value in
      PluginOptionValueEditorSheet(initialText: value.text) { newValue in
        draft.updateValue(newValue, of: value.id)
      }
    }
  }

  private var modeBinding: Binding<PluginOptionsDraft.Mode> {
    Binding(
      get: { displayedMode },
      set: { requested in
        let succeeded =
          requested == .rawText ? draft.switchToRawText() : draft.switchToTable()
        displayedMode = succeeded ? requested : draft.mode
      })
  }

  // MARK: - 参数列表

  private var tableView: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(draft.rows) { row in
        rowView(row)
      }
      if isEditable {
        Button {
          focusedRowID = draft.quickAddRowID
        } label: {
          Label("添加参数", systemImage: "plus")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  private func rowView(_ row: PluginOptionsDraft.Row) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        keyField(row)
        valueField(row)
        kindPicker(row)
        if isEditable {
          rowActions(row)
        }
      }
      if row.isUnfinished {
        Text("缺少参数名")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func keyField(_ row: PluginOptionsDraft.Row) -> some View {
    if isEditable {
      TextField(
        "参数名",
        text: Binding(
          get: { row.keyText },
          set: { draft.updateKey($0, of: row.id) })
      )
      .textFieldStyle(.roundedBorder)
      .focused($focusedRowID, equals: row.id)
    } else {
      Text(row.keyText)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func valueField(_ row: PluginOptionsDraft.Row) -> some View {
    if isEditable {
      TextField(
        "值",
        text: Binding(
          get: { row.valueText },
          set: { draft.updateValue($0, of: row.id) })
      )
      .textFieldStyle(.roundedBorder)
      .disabled(row.kind == .flag)
    } else {
      // 值单元格单行展示、尾部省略；完整内容保留在草稿与无障碍读取中。
      Text(row.valueText)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(row.kind == .flag ? "无值开关" : "值")
    }
  }

  private func kindPicker(_ row: PluginOptionsDraft.Row) -> some View {
    Picker(
      "类型",
      selection: Binding(
        get: { row.kind },
        set: { draft.setKind($0, of: row.id) })
    ) {
      Text("值").tag(PluginOptionsDraft.Kind.keyValue)
      Text("无值开关").tag(PluginOptionsDraft.Kind.flag)
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .frame(width: 96)
    .disabled(!isEditable)
  }

  @ViewBuilder
  private func rowActions(_ row: PluginOptionsDraft.Row) -> some View {
    Button {
      editingValue = EditingValue(id: row.id, text: row.valueText)
    } label: {
      Label("编辑值…", systemImage: "square.and.pencil")
    }
    .buttonStyle(.borderless)
    .disabled(row.kind == .flag)

    Button {
      draft.deleteRow(row.id)
    } label: {
      Label("删除参数行", systemImage: "trash")
    }
    .buttonStyle(.borderless)
  }

  // MARK: - 原始文本

  private var rawTextView: some View {
    Group {
      if isEditable {
        TextEditor(text: $draft.rawText)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 76, maxHeight: 152)
          .autocorrectionDisabled()
          .focused(fieldFocus, equals: .pluginOptions)
      } else {
        ScrollView {
          Text(draft.rawText)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minHeight: 76, maxHeight: 152)
      }
    }
  }

  // MARK: - 字段错误

  @ViewBuilder
  private var fieldErrorLabel: some View {
    switch fieldError {
    case .tooManyBytes(let limit):
      Text("插件参数最多 \(limit) 个字节")
        .font(.footnote)
        .foregroundStyle(.red)
    case .unfinishedPluginOptionRow:
      Text("存在未完成的参数行：请补全参数名、清空该行或删除它")
        .font(.footnote)
        .foregroundStyle(.red)
    case .missingName, .tooManyCharacters, .invalidPort, nil:
      EmptyView()
    }
  }
}

/// 长值独立编辑（issue #81）：等宽多行、初始约四行最多约八行后内部纵向
/// 滚动；只有「确认」写回父表单草稿，取消保留之前的值。
private struct PluginOptionValueEditorSheet: View {
  let initialText: String
  let onConfirm: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var text: String

  init(initialText: String, onConfirm: @escaping (String) -> Void) {
    self.initialText = initialText
    self.onConfirm = onConfirm
    _text = State(initialValue: initialText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("值")
        .font(.headline)
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 76, maxHeight: 152)
        .autocorrectionDisabled()
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("确认") {
          onConfirm(text)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(minWidth: 380, minHeight: 220)
  }
}
