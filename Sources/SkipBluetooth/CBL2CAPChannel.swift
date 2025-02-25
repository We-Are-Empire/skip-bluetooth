// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
#if SKIP

import Foundation
public typealias CBL2CAPPSM = UInt16

open class CBL2CAPChannel : NSObject {
    @available(*, unavailable)
    open var peer: CBPeer! { fatalError() }

    @available(*, unavailable)
    open var inputStream: Any! { fatalError() }

    @available(*, unavailable)
    open var outputStream: Any! { fatalError() }

    @available(*, unavailable)
    open var psm: CBL2CAPPSM { fatalError() }
}

#endif
#endif

