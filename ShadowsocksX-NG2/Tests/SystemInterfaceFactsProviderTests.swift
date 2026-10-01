import SystemConfiguration
import XCTest

@testable import ShadowsocksX_NG2

/// 生产本机接口事实来源的真实主机非视觉验证（issue #72）：替身测试证明策略
/// 行为，本组用例证明系统适配器整合——接口名称与类型映射、回环识别、地址
/// 规范化与链路本地判定均来自真实 macOS。候选枚举本身不证明跨设备可达。
@MainActor
final class SystemInterfaceFactsProviderTests: XCTestCase {
  private var provider: SystemInterfaceFactsProvider!
  private var interfaces: [LocalInterfaceFacts]!

  override func setUp() async throws {
    try await super.setUp()
    provider = SystemInterfaceFactsProvider()
    guard let interfaces = provider.interfaces else {
      self.interfaces = []
      XCTFail("真实主机 getifaddrs 枚举不应失败")
      return
    }
    self.interfaces = interfaces
  }

  private func fact(_ bsdName: String) -> LocalInterfaceFacts? {
    interfaces.first { $0.bsdName == bsdName }
  }

  func testLoopbackIsIdentifiedWithNormalizedAddresses() {
    guard let lo0 = fact("lo0") else {
      return XCTFail("真实主机必有 lo0：\(interfaces.map(\.bsdName))")
    }
    XCTAssertTrue(lo0.isLoopback, "回环以 IFF_LOOPBACK 识别")
    XCTAssertNil(lo0.interfaceType, "回环无 SystemConfiguration 类型映射")
    XCTAssertTrue(
      lo0.addresses.contains(
        LocalInterfaceAddress(address: "127.0.0.1", family: .ipv4, isIPv6LinkLocal: false)),
      "回环单播含规范化 127.0.0.1")
  }

  func testInterfaceTypeMappingCoversRealSystemInterfaces() {
    let mapped = interfaces.filter { $0.interfaceType != nil }
    XCTAssertFalse(
      mapped.isEmpty, "真实主机至少有一个 SystemConfiguration 可见接口：\(interfaces)")
    for interface in mapped {
      if let localizedName = interface.localizedName {
        XCTAssertFalse(localizedName.isEmpty, "\(interface.bsdName) 本地化名称非空")
      }
    }
  }

  func testAddressTextIsNormalizedWithoutScopeOrEmptiness() {
    for interface in interfaces {
      for address in interface.addresses {
        XCTAssertFalse(address.address.isEmpty)
        XCTAssertFalse(
          address.address.contains("%"),
          "\(interface.bsdName) 地址不含作用域后缀：\(address.address)")
        if address.family == .ipv6, address.address.hasPrefix("fe80") {
          XCTAssertTrue(address.isIPv6LinkLocal, "fe80 地址必须标记链路本地")
        } else if address.family == .ipv6 {
          XCTAssertFalse(address.isIPv6LinkLocal, "非 fe80 地址不应标记链路本地")
        }
      }
    }
  }

  func testPolicyAppliedToRealFactsYieldsLoopbackFirstAndAllowedTypesOnly() {
    let candidates = TerminalCommandAddressPolicy.candidates(
      for: .allIPv4AndIPv6Interfaces, interfaces: interfaces)

    XCTAssertEqual(
      candidates.prefix(2).map(\.address), ["127.0.0.1", "::1"],
      "双栈回环两项置顶且来自真实主机")
    let nonLoopback = candidates.dropFirst(2)
    XCTAssertFalse(nonLoopback.isEmpty, "真实主机存在可列出的接口地址候选")
    for candidate in nonLoopback {
      let type = interfaces.first { $0.bsdName == candidate.bsdName }?.interfaceType
      XCTAssertTrue(
        type == kSCNetworkInterfaceTypeIEEE80211 as String
          || type == kSCNetworkInterfaceTypeEthernet as String,
        "候选 \(candidate.label) 必须来自允许类型接口（实际类型 \(type ?? "nil")）")
      XCTAssertFalse(candidate.address.contains("%"), "候选地址已规范化")
    }
  }
}
