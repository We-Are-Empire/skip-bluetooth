// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
open class CBDescriptor: CBAttribute {
    @available(*, unavailable)
    open var characteristic: CBCharacteristic? { fatalError() }

    @available(*, unavailable)
    open var value: Any? { fatalError() }
}

open class CBMutableDescriptor: CBDescriptor {
    public init(type UUID: CBUUID, value: Any?) {
        super.init(UUID)
    }
}

#endif
#endif

