import Dispatch

// 将, 回调这回事使用一个特定的类进行了存储.
// 这是一个引用类型.
// 这个类型, 只会在 Sealant.pending中使用
final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

// 将状态, 回调, 结果使用 Swfit Enum 这种方式进行了存储, 更加的显式.
enum Sealant<R> {
    case pending(Handlers<R>) // 还没有 resolved, 这个时候, 存储了众多处理 Result 值的回调.
    case resolved(R) // 已经 Resolve 了, 这时候, 存储了最终的这个 Result 值.
}

// - Remark: not protocol ∵ http://www.russbishop.net/swift-associated-types-cont
// 在 Promise 的定义里面, 是这样的 Box Box<Result<T>>
class Box<T> {
    // 用来返回当前的 Promise 状态.
    func inspect() -> Sealant<T> { fatalError() }
    // 用来存储闭包的. BLOCK 会在所的环境下进行.
    // 这是一个比较好的实现方法, Swift 很多 API , with 开头的都是这样做的, 将环境搭设完毕之后进行操作. 
    func inspect(_: (Sealant<T>) -> Void) { fatalError() }
    func seal(_: T) {}
}

// 泛型的定义, 该需要类型参数的, 就使用类型参数.
// 泛型的子类, 经常会使用一个类型, 以及这个类型的变体来进行父类的类型的确定, 这样子类需要的类型参数就会大大减少.
final class SealedBox<T>: Box<T> {
    let value: T // 对于 SealedBox 来说, 它连 Sealant 这个值都不需要.
    
    init(value: T) {
        self.value = value
    }
    
    override func inspect() -> Sealant<T> {
        return .resolved(value)
    }
}

class EmptyBox<T>: Box<T> {
    // 对于 EmptyBox 来说, 它的状态是一个变化的过程, 所以使用 Sealant 来表示.
    private var sealant = Sealant<T>.pending(.init())
    // 都是用的 sync, 这 concurrent 个屁
    private let barrier = DispatchQueue(label: "org.promisekit.barrier", attributes: .concurrent)
    
    // Resolve 数据的过程.
    override func seal(_ value: T) {
        var handlers: Handlers<T>!
        /*
         When submitted to a concurrent queue, a work item with this flag acts as a barrier.
         Work items submitted prior to the barrier execute to completion, at which point the barrier work item executes.
         Once the barrier work item finishes, the queue returns to scheduling work items that were submitted after the barrier.
         */
        barrier.sync(flags: .barrier) {
            // 直接使用这种方式, 会有编译错误.
            //            if sealant == .pending {
            //                print("可以这样判断")
            //            }
            // 如果想要不做提取, 直接使用 case 进行判断, 要使用这个特殊的形式. 使用这个特殊的形式, 倒是不用进行值的抽取就可以.
            //            if case .pending = sealant {
            //                return
            //            }
            
            guard case .pending(let _handlers) = self.sealant else {
                return  // already fulfilled!
            }
            // 在多线程的环境下, 如何尽可能小的控制临界区, 是一个值得注意的点.
            handlers = _handlers
            self.sealant = .resolved(value)
        }
        
        // 在临界区外, 进行回调的触发.
        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }
    }
    
    // 这是一个惯例写法, 所有在多线程环境的 get 方法, 都是这样来写的.
    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }
    
    // 在 pending 状态下, 进行 Block 的添加会使用该方法, 就是 sealant 是一个 enum, 单例里面的 Handler 是一个引用值, 所以不用考虑 inout 的传递.
    override func inspect(_ body: (Sealant<T>) -> Void) {
        var sealed = false
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

// 这其实就是 Wrapper 这种方式实现的基础, 各种 kf, yd 其实都是这种方式实现的.
// Option 其实就是一个 Wrapper 对象, 只不过他的 Type 是通过 case 进行了区分.
// 这种扩展, 就是为什么一个 DispatchQueue? 可以调用 async 的原因所在了. 
extension Optional where Wrapped: DispatchQueue {
    @inline(__always)
    func async(flags: DispatchWorkItemFlags?,
               _ body: @escaping() -> Void) {
        switch self {
        case .none:
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
