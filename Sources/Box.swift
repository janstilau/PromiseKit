import Dispatch

/*
 Sealant 里面, 存储的会是 Result 类型.
 Handler 里面, 存储的是 处理 Result 类型的闭包.
 */
enum Sealant<R> {
    // 如果是在 Pending 状态, 那么 value 部分, 存储的是一个个的 Handler
    case pending(Handlers<R>)
    // 如果是在 resolved 状态, 那么 value 部分, 就是存储的 R. Result. 可能是 Fulfilled, 也可能是 Rejected.
    case resolved(R)
}

final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

class Box<T> {
    func inspect() -> Sealant<T> { fatalError() }
    func inspect(_: (Sealant<T>) -> Void) { fatalError() } // 使用该方法, 一定要在 inspect() 返回 Pending 的前提下使用.
    func seal(_: T) {} // Seal, 就是将状态, 改变为 Resolved 的状态.
}

// SealedBox, 是没有办法, 进行状态的改变的.
// 对他进行 Inspect, 只会是 Resolved 的状态.
final class SealedBox<T>: Box<T> {
    let value: T
    
    init(value: T) {
        self.value = value
    }
    
    // 特殊的 Box, 状态不会发生任何改变, 一个不可变对象.
    // 不用考虑线程问题.
    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}

/*
 虽然, 这里写的是 T, 但是其实是一个 Result 的类型.
 */
class EmptyBox<T>: Box<T> {
    
    private var sealant = Sealant<T>.pending(.init())
    
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)
    
    // 当, Box 从 Pending 变为 Resolved 的时候, 要把所有的回调取出来调用一次, 并且清空回调 .
    // 然后, 将自己的状态, 变为是 .resolved 的状态.
    
    // 因为, 这是一个可变类型, 所以要考虑线程问题.
    // 实际, 在 Resolver 里面, seal 的参数, 会是一个 Result 类型的对象.
    override func seal(_ value: T) {
        
        var handlers: Handlers<T>!
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return
            }
            handlers = _handlers
            // 在这里, 完成了 Sealant 的状态切换.
            // 之前存储的 Handlers 在这个时候, 会全部进行是释放.
            self.sealant = .resolved(value)
        }
        
        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }
    }
    
    // 因为, 这是一个可变类型, 所以在进行 Get 请求的时候, 需要考虑到线程的问题.
    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }
    
    // 因为, 这是一个可变类型, 所以要考虑到线程问题.
    // 现在的需求是, 需要 Body 的执行过程中, 保持线程独占. 这是使用的技术是, barrier queue.
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
        /*
         When submitted to a concurrent queue, a work item with this flag acts as a barrier.
         Work items submitted prior to the barrier execute to completion, at which point the barrier work item executes.
         Once the barrier work item finishes, the queue returns to scheduling work items that were submitted after the barrier.
         
         barrier 应该更多的是和队列调度相关.
         */
        barrier.sync(flags: .barrier) {
            switch sealant {
            case .pending:
                // body will append to handlers, so we must stay barrier’d
                body(sealant)
            case .resolved:
                sealed = true
            }
        }
        if sealed {
            // we do this outside the barrier to prevent potential deadlocks
            // it's safe because we never transition away from this state
            body(sealant)
        }
    }
}


extension Optional where Wrapped: DispatchQueue {
    @inline(__always)
    func async(flags: DispatchWorkItemFlags?,
               _ body: @escaping() -> Void) {
        switch self {
        case .none:
            // 如果, 是 nil. 那就不调度, 直接当前的线程执行. 
            body()
        case .some(let q):
            if let flags = flags {
                q.async(flags: flags, execute: body)
            } else {
                q.async(execute: body)
            }
        }
    }
}
