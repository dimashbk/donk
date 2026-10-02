import Foundation
import ObjectiveC.runtime

package enum DonkSwizzle {
    @discardableResult
    package static func instanceMethod(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) -> Bool {
        guard
            let originalMethod = class_getInstanceMethod(cls, original),
            let swizzledMethod = class_getInstanceMethod(cls, swizzled)
        else { return false }
        let didAdd = class_addMethod(
            cls,
            original,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        if didAdd {
            class_replaceMethod(
                cls,
                swizzled,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
        return true
    }

    @discardableResult
    package static func classMethod(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) -> Bool {
        guard let metaclass = object_getClass(cls) else { return false }
        return instanceMethod(metaclass, original, swizzled)
    }
}
