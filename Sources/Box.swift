import Dispatch

// 将状态, 回调, 结果使用 Swfit Enum 这种方式进行了存储, 更加的显式.
enum Sealant<R> {
    case pending(Handlers<R>)
    case resolved(R)
}

// 将, 回调这回事使用一个特定的类进行了存储.
final class Handlers<R> {
    var bodies: [(R) -> Void] = []
    func append(_ item: @escaping(R) -> Void) { bodies.append(item) }
}

/// - Remark: not protocol ∵ http://www.russbishop.net/swift-associated-types-cont
// 在 Promise 的定义里面, 是这样的 Box Box<Result<T>>
class Box<T> {
    func inspect() -> Sealant<T> { fatalError() }
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
    
    override func seal(_ value: T) {
        var handlers: Handlers<T>!
        /*
         When submitted to a concurrent queue, a work item with this flag acts as a barrier.
         Work items submitted prior to the barrier execute to completion, at which point the barrier work item executes.
         Once the barrier work item finishes, the queue returns to scheduling work items that were submitted after the barrier.
         */
        barrier.sync(flags: .barrier) {
            guard case .pending(let _handlers) = self.sealant else {
                return  // already fulfilled!
            }
            handlers = _handlers
            self.sealant = .resolved(value)
        }
        
        if let handlers = handlers {
            handlers.bodies.forEach{ $0(value) }
        }
    }
    
    override func inspect() -> Sealant<T> {
        var rv: Sealant<T>!
        barrier.sync {
            rv = self.sealant
        }
        return rv
    }
    
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


extension Optional where Wrapped: DispatchQueue {
    @inline(__always)
    func async(flags: DispatchWorkItemFlags?, _ body: @escaping() -> Void) {
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
