import Combine
import Foundation
import SystemConfiguration

/// 生产本机接口事实来源（issue #72）：getifaddrs 提供当前启用接口、回环
/// 标记与单播地址（族与 IPv6 链路本地判定），SCNetworkInterfaceCopyAll 以
/// BSD 名关联系统接口类型与本地化名称，SCDynamicStore 监视接口状态变化。
/// 所有系统 API 细节封装于此；类型白名单与过滤排序在工作流层策略。
@MainActor
final class SystemInterfaceFactsProvider: LocalInterfaceFactsReading {
  /// getifaddrs 只看得到链路层事实；「当前启用」以 IFF_UP 判定，未启用
  /// 接口不进入事实。
  var interfaces: [LocalInterfaceFacts]? { Self.enumerate() }

  private let changeSubject = PassthroughSubject<Void, Never>()
  private let changesPublisher: AnyPublisher<Void, Never>
  /// SCDynamicStore 过渡期会按变化键连发事件，去抖避免反复枚举。
  var changes: AnyPublisher<Void, Never> { changesPublisher }

  private let observation = InterfaceFactsObservation()

  init() {
    changesPublisher =
      changeSubject
      .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
      .eraseToAnyPublisher()
    startObserving()
  }

  private func startObserving() {
    var context = SCDynamicStoreContext(
      version: 0,
      info: Unmanaged.passUnretained(observation).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil)
    guard
      let store = SCDynamicStoreCreate(
        kCFAllocatorDefault, "ShadowsocksX-NG2.InterfaceFacts" as CFString,
        interfaceFactsDynamicStoreCallback, &context)
    else { return }
    // 接口状态键（State:/Network/Interface/<bsd>/IPv4|IPv6）覆盖地址增删与
    // 接口启停；全局 IPv4/IPv6 键覆盖主服务切换。
    let globalKeys =
      [
        "State:/Network/Global/IPv4" as CFString, "State:/Network/Global/IPv6" as CFString,
      ] as CFArray
    let patterns = ["State:/Network/Interface/.*"] as CFArray
    guard SCDynamicStoreSetNotificationKeys(store, globalKeys, patterns) else { return }
    guard SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main) else { return }
    observation.attach(store)
    observation.setHandler { [weak self] in self?.changeSubject.send() }
  }

  // MARK: - 枚举

  private static func enumerate() -> [LocalInterfaceFacts]? {
    var interfacesPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfacesPtr) == 0, let first = interfacesPtr else { return nil }
    defer { freeifaddrs(first) }

    // 按首次出现顺序逐接口累积；同一接口的多个地址条目归并到同一事实。
    var order: [String] = []
    var loopbackByBSDName: [String: Bool] = [:]
    var addressesByBSDName: [String: [LocalInterfaceAddress]] = [:]
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      pointer = current.pointee.ifa_next
      guard let name = current.pointee.ifa_name, let socketAddress = current.pointee.ifa_addr
      else { continue }
      let bsdName = String(cString: name)
      // Darwin 的 ifaddrs.ifa_flags 是值字段。
      let flags = Int32(current.pointee.ifa_flags)
      guard flags & IFF_UP == IFF_UP else { continue }
      if loopbackByBSDName[bsdName] == nil {
        order.append(bsdName)
        loopbackByBSDName[bsdName] = flags & IFF_LOOPBACK == IFF_LOOPBACK
      }
      if let address = interfaceAddress(socketAddress) {
        addressesByBSDName[bsdName, default: []].append(address)
      }
    }

    let metadata = systemInterfaceMetadata()
    return order.map { bsdName in
      LocalInterfaceFacts(
        bsdName: bsdName,
        isLoopback: loopbackByBSDName[bsdName] ?? false,
        interfaceType: metadata[bsdName]?.type,
        localizedName: metadata[bsdName]?.name,
        addresses: addressesByBSDName[bsdName] ?? [])
    }
  }

  /// 单个地址条目的族与链路本地判定；非 IPv4/IPv6 条目（链路层等）或无法
  /// 规范化的地址为 nil。
  private static func interfaceAddress(
    _ socketAddress: UnsafeMutablePointer<sockaddr>
  ) -> LocalInterfaceAddress? {
    switch socketAddress.pointee.sa_family {
    case sa_family_t(AF_INET):
      let socket = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee
      }
      guard let text = addressText(family: AF_INET, address: socket.sin_addr) else { return nil }
      return LocalInterfaceAddress(address: text, family: .ipv4, isIPv6LinkLocal: false)
    case sa_family_t(AF_INET6):
      let socket = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        $0.pointee
      }
      guard let text = addressText(family: AF_INET6, address: socket.sin6_addr) else { return nil }
      return LocalInterfaceAddress(
        address: text,
        family: .ipv6,
        isIPv6LinkLocal: isIPv6LinkLocal(socket.sin6_addr))
    default:
      return nil
    }
  }

  /// inet_ntop 规范化呈现形；转换失败不产生候选地址。
  private static func addressText<T>(family: Int32, address: T) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let result = withUnsafePointer(to: address) { pointer in
      pointer.withMemoryRebound(
        to: UInt8.self, capacity: MemoryLayout<T>.size
      ) {
        inet_ntop(family, $0, &buffer, socklen_t(INET6_ADDRSTRLEN))
      }
    }
    guard result != nil else { return nil }
    return String(cString: buffer)
  }

  /// IPv6 链路本地判定（fe80::/10；`IN6_IS_ADDR_LINKLOCAL` 宏未导入 Swift）。
  private static func isIPv6LinkLocal(_ address: in6_addr) -> Bool {
    let prefix = withUnsafeBytes(of: address) { Array($0.prefix(2)) }
    return prefix.count == 2 && prefix[0] == 0xFE && prefix[1] & 0xC0 == 0x80
  }

  /// BSD 名 → (系统接口类型, 本地化名称)。回环无 SystemConfiguration 映射，
  /// 类型保持 nil；名称缺失由策略回退 BSD 名。
  private static func systemInterfaceMetadata() -> [String: (type: String?, name: String?)] {
    var metadata: [String: (type: String?, name: String?)] = [:]
    for case let interface as SCNetworkInterface in SCNetworkInterfaceCopyAll() as NSArray {
      guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
      metadata[bsdName] = (
        SCNetworkInterfaceGetInterfaceType(interface) as String?,
        SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
      )
    }
    return metadata
  }
}

/// SCDynamicStore 观察箱：跨 C 回调向 MainActor 发值，并收拢 store 生命周期
/// ——store 的 context 以 unretained 指针回指本箱，本箱释放时先脱离队列再
/// 释放 store，保证 context 指针不悬挂（Swift 6 禁止在 MainActor 类的
/// nonisolated deinit 直接访问非 Sendable 存储）。
private final class InterfaceFactsObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@MainActor @Sendable () -> Void)?
  private var store: SCDynamicStore?

  func attach(_ store: SCDynamicStore) {
    lock.withLock { self.store = store }
  }

  func setHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
    lock.withLock { self.handler = handler }
  }

  func emit() {
    let currentHandler = lock.withLock { handler }
    guard let currentHandler else { return }
    Task { @MainActor in currentHandler() }
  }

  deinit {
    lock.withLock {
      if let store {
        SCDynamicStoreSetDispatchQueue(store, nil)
      }
      handler = nil
    }
  }
}

private let interfaceFactsDynamicStoreCallback: SCDynamicStoreCallBack = { _, _, info in
  guard let info else { return }
  Unmanaged<InterfaceFactsObservation>.fromOpaque(info).takeUnretainedValue().emit()
}
