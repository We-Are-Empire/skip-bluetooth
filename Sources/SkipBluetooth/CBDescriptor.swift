// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import android.bluetooth.BluetoothGattDescriptor

open class CBDescriptor: CBAttribute {
    /// The parent characteristic that contains this descriptor
    private var _characteristic: CBCharacteristic?

    /// The cached value of this descriptor
    private var _value: Any?

    /// The underlying Android descriptor
    internal let descriptor: BluetoothGattDescriptor?

    /// The parent characteristic that contains this descriptor
    open var characteristic: CBCharacteristic? { _characteristic }

    /// The value of the descriptor.
    ///
    /// - Note: This value is populated after calling `readValue(for:)` on the peripheral
    ///   and receiving the `peripheral(_:didUpdateValueFor:error:)` delegate callback.
    open var value: Any? { _value }

    public init(type UUID: CBUUID, value: Any?) {
        self.descriptor = nil
        self._value = value
        super.init(UUID)
    }

    public init(type UUID: CBUUID) {
        self.descriptor = nil
        super.init(UUID)
    }

    /// Creates a CBDescriptor from an Android BluetoothGattDescriptor
    internal init(platformValue: BluetoothGattDescriptor, characteristic: CBCharacteristic) {
        self.descriptor = platformValue
        self._characteristic = characteristic
        super.init(uuid: CBUUID(string: platformValue.uuid.toString()))
    }

    /// Creates a CBDescriptor from an Android BluetoothGattDescriptor with a value
    internal init(platformValue: BluetoothGattDescriptor, characteristic: CBCharacteristic, value: Data) {
        self.descriptor = platformValue
        self._characteristic = characteristic
        self._value = value
        super.init(uuid: CBUUID(string: platformValue.uuid.toString()))
    }

    /// Updates the cached value (called by BleGattCallback)
    internal func updateValue(_ value: Any?) {
        _value = value
    }
}

extension CBDescriptor {
    /// Returns the underlying Android BluetoothGattDescriptor
    internal func kotlin() -> BluetoothGattDescriptor? {
        return descriptor
    }
}

open class CBMutableDescriptor: CBDescriptor {
    public override init(type UUID: CBUUID, value: Any?) {
        super.init(type: UUID, value: value)
    }
}

#endif
#endif

