// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
open class CBAttribute: NSObject, Equatable {
    open var uuid: CBUUID

    internal init(uuid: CBUUID) {
        self.uuid = uuid
    }

    static func == (lhs: CBAttribute, rhs: CBAttribute) -> Bool {
        return lhs.uuid.uuidString == rhs.uuid.uuidString
    }
}
#endif
#endif

