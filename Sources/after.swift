import struct Foundation.TimeInterval
import Dispatch

/**
     after(seconds: 1.5).then {
         //…
     }

- Returns: A guarantee that resolves after the specified duration.
*/
public func after(seconds: TimeInterval) -> Guarantee<Void> {
    // 为什么会出现 pending() 这个函数在这里体现出来了.
    // 快速的定义一个 Thenable, 提供 seal 接口进行状态的封存.
    // 这种方式, 比使用构造方法进行 Thenable 的创建要好的多. 
    let (rg, seal) = Guarantee<Void>.pending()
    let when = DispatchTime.now() + seconds
    theQueue.asyncAfter(deadline: when) { seal(()) }
    return rg
}

/**
     after(.seconds(2)).then {
         //…
     }

 - Returns: A guarantee that resolves after the specified duration.
*/
public func after(_ interval: DispatchTimeInterval) -> Guarantee<Void> {
    let (rg, seal) = Guarantee<Void>.pending()
    let when = DispatchTime.now() + interval
#if swift(>=4.0)
    theQueue.asyncAfter(deadline: when) { seal(()) }
#else
    theQueue.asyncAfter(deadline: when, execute: seal)
#endif
    return rg
}

private var theQueue: DispatchQueue {
    if #available(macOS 10.10, iOS 8.0, tvOS 9.0, watchOS 2.0, *) {
        return DispatchQueue.global(qos: .default)
    } else {
        return DispatchQueue.global(priority: .default)
    }
}
