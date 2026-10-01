import Foundation
import SystemConfiguration

// MARK: - 命令地址投影（issue #72）

/// 首页命令地址候选（CONTEXT.md「Terminal command address」）。身份 = BSD
/// 接口身份 + 规范化 IP；本地化名称仅用于呈现，不参与身份。`Hashable` 供
/// SwiftUI Picker 标签匹配使用，选择校验一律走 `identity`。
struct TerminalCommandAddress: Equatable, Hashable, Sendable {
  /// BSD 接口名；回环固定为 lo0。
  let bsdName: String
  /// 规范化 IP 文本。
  let address: String
  /// `{IP} - {name}` 中的名称：系统本地化接口名称，缺失回退 BSD 名。
  let displayName: String

  /// 跨刷新匹配既有选择的身份（不含显示名；显示名变化不使选择失效）。
  var identity: TerminalCommandAddressIdentity {
    TerminalCommandAddressIdentity(bsdName: bsdName, address: address)
  }

  /// 候选标签：`{IP} - {name}`。
  var label: String { "\(address) - \(displayName)" }
}

/// 命令地址身份：BSD 接口名 + 规范化 IP。
struct TerminalCommandAddressIdentity: Equatable, Hashable, Sendable {
  let bsdName: String
  let address: String
}

/// 首页命令地址选择器投影（issue #72）：可见性、候选与生效选择一次观察
/// 产出，所有字段来自同一时间点。
struct TerminalCommandAddressPicker: Equatable, Sendable {
  /// 仅本机监听方式隐藏。
  let isVisible: Bool
  /// 用户可见候选（已过滤、已排序；至少含兼容回环项）。
  let candidates: [TerminalCommandAddress]
  /// 当前生效选择；恒为候选之一（选择失效自动回退默认回环）。
  let selected: TerminalCommandAddress
}

// MARK: - 派生策略

/// 首页命令地址策略（issue #72）：接口原始事实 + 已保存监听方式 → 用户可见
/// 候选与生效选择。纯派生：类型白名单、地址族过滤、链路本地/通配排除、名称
/// 回退、排序合并与失效回退全部在此。测试以原始事实替身驱动本策略，不直接
/// 注入已过滤候选。
enum TerminalCommandAddressPolicy {
  /// 非回环接口的严格类型白名单：仅 SystemConfiguration 的 Wi‑Fi（IEEE80211）
  /// 与 Ethernet 类型；不以接口名前缀或通用链路类型代替，无法确认属于允许
  /// 类型的非回环接口排除。
  private static let allowedInterfaceTypes: Set<String> = [
    kSCNetworkInterfaceTypeIEEE80211 as String,
    kSCNetworkInterfaceTypeEthernet as String,
  ]

  /// 通配绑定地址不能用作命令目标。
  private static let wildcardAddresses: Set<String> = ["0.0.0.0", "::"]

  /// 一次观察的完整选择器事实。`selection` 不在候选中（地址消失、地址族
  /// 不兼容或枚举失败）时回退当前监听方式的默认回环地址。
  static func picker(
    mode: ListenerMode,
    interfaces: [LocalInterfaceFacts]?,
    selection: TerminalCommandAddressIdentity?
  ) -> TerminalCommandAddressPicker {
    let candidates = candidates(for: mode, interfaces: interfaces)
    let selected = candidates.first { $0.identity == selection } ?? defaultLoopback(for: mode)
    return TerminalCommandAddressPicker(
      isVisible: mode != .localhost,
      candidates: candidates,
      selected: selected)
  }

  /// 候选列表：回环项置顶（双栈 127.0.0.1 先于 ::1），其余来自白名单接口；
  /// 仅本机方式监听器只绑定 127.0.0.1，候选不含接口地址。枚举失败（nil）
  /// 仅提供兼容回环候选。
  static func candidates(
    for mode: ListenerMode,
    interfaces: [LocalInterfaceFacts]?
  ) -> [TerminalCommandAddress] {
    let loopbacks = loopbackCandidates(for: mode)
    guard mode != .localhost, let interfaces else { return loopbacks }
    return loopbacks + interfaceCandidates(mode: mode, interfaces: interfaces)
  }

  /// 当前监听方式的默认回环地址（与 ListenerMode.proxyLoopbackAddress 一致）。
  static func defaultLoopback(for mode: ListenerMode) -> TerminalCommandAddress {
    TerminalCommandAddress(bsdName: "lo0", address: mode.proxyLoopbackAddress, displayName: "lo0")
  }

  // MARK: - 派生细节

  private static func loopbackCandidates(for mode: ListenerMode) -> [TerminalCommandAddress] {
    let addresses: [String]
    switch mode {
    case .localhost, .allIPv4Interfaces:
      addresses = ["127.0.0.1"]
    case .allIPv4AndIPv6Interfaces:
      addresses = ["127.0.0.1", "::1"]
    case .allIPv6Interfaces:
      addresses = ["::1"]
    }
    return addresses.map { TerminalCommandAddress(bsdName: "lo0", address: $0, displayName: "lo0") }
  }

  /// 待排序的接口分组：显示名 + BSD 名 + 该接口的地址候选。
  private struct InterfaceGroup {
    let name: String
    let bsdName: String
    let addresses: [TerminalCommandAddress]
  }

  private static func interfaceCandidates(
    mode: ListenerMode,
    interfaces: [LocalInterfaceFacts]
  ) -> [TerminalCommandAddress] {
    var groups: [InterfaceGroup] = []
    for interface in interfaces where !interface.isLoopback {
      guard let type = interface.interfaceType, allowedInterfaceTypes.contains(type) else {
        continue
      }
      // 显示名缺失回退 BSD 名；回退不放宽类型过滤。
      let name = interface.localizedName ?? interface.bsdName
      var seen = Set<String>()
      let accepted = interface.addresses
        .filter { isAcceptable($0, mode: mode) }
        .filter { seen.insert($0.address).inserted }  // 同一接口重复 IP 合并
      let addresses =
        accepted
        .sorted { lhs, rhs in
          // 同一接口先 IPv4 后 IPv6，再按地址稳定排序。
          if lhs.family != rhs.family { return lhs.family == .ipv4 }
          return lhs.address < rhs.address
        }
        .map {
          TerminalCommandAddress(bsdName: interface.bsdName, address: $0.address, displayName: name)
        }
      if !addresses.isEmpty {
        groups.append(InterfaceGroup(name: name, bsdName: interface.bsdName, addresses: addresses))
      }
    }
    return
      groups
      .sorted { lhs, rhs in
        // 其余项按接口名称排序（大小写不敏感，BSD 回退名与本地化名混排）；
        // 同显示名以 BSD 名保持稳定。
        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        return lhsName == rhsName ? lhs.bsdName < rhs.bsdName : lhsName < rhsName
      }
      .flatMap(\.addresses)
  }

  private static func isAcceptable(
    _ address: LocalInterfaceAddress, mode: ListenerMode
  ) -> Bool {
    guard !wildcardAddresses.contains(address.address) else { return false }
    // IPv6 链路本地需要额外接口作用域，不作为命令目标；IPv4 链路本地允许。
    if address.family == .ipv6, address.isIPv6LinkLocal { return false }
    switch (mode, address.family) {
    case (.allIPv4Interfaces, .ipv4):
      return true
    case (.allIPv4AndIPv6Interfaces, _):
      return true
    case (.allIPv6Interfaces, .ipv6):
      return true
    default:
      return false
    }
  }
}
