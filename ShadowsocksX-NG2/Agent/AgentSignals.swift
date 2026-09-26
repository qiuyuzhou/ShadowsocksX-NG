import Foundation

// MARK: - 信号与共享状态

/// 信号只置位并唤醒监管循环，全部判定在循环线程完成。标志与信号量成对
/// （辅助等待会消耗信号量，事后 rearmIfPending 补回）。队列由顶层脚本在
/// 任何函数调用前完成初始化（源码顺序语义）。
let signalsQueue = DispatchQueue(label: "com.qiuyuzhou.ShadowsocksX-NG2.agent.signals")

final class SignalFlags {
  private let lock = NSLock()
  private var stopRequested = false
  private var reloadRequested = false
  private let events = DispatchSemaphore(value: 0)

  func requestStop() {
    lock.lock()
    stopRequested = true
    lock.unlock()
    events.signal()
  }

  func requestReload() {
    lock.lock()
    reloadRequested = true
    lock.unlock()
    events.signal()
  }

  func wake() {
    events.signal()
  }

  func wait() {
    events.wait()
  }

  func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
    events.wait(timeout: timeout)
  }

  func consumeStop() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = stopRequested
    stopRequested = false
    return value
  }

  func consumeReload() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = reloadRequested
    reloadRequested = false
    return value
  }

  func rearmIfPending() {
    lock.lock()
    let pending = stopRequested || reloadRequested
    lock.unlock()
    if pending {
      events.signal()
    }
  }
}

func observeSignal(_ number: Int32, flags: SignalFlags, handler: @escaping () -> Void)
  -> DispatchSourceSignal
{
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: signalsQueue)
  source.setEventHandler(handler: handler)
  source.resume()
  return source
}

/// 子进程退出状态的单一写入点（handler 线程）与读取点（监管线程），由
/// 信号量唤醒提供 happens-before。
final class ExitStatusBox {
  private let lock = NSLock()
  private var value: Int32?

  func store(_ status: Int32) {
    lock.lock()
    value = status
    lock.unlock()
  }

  func load() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
