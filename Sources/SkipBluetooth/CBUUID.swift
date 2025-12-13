// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP

public let CBUUIDCharacteristicExtendedPropertiesString: String = "2900"
public let CBUUIDCharacteristicUserDescriptionString: String = "2901"
public let CBUUIDClientCharacteristicConfigurationString: String = "2902"
public let CBUUIDServerCharacteristicConfigurationString: String = "2903"
public let CBUUIDCharacteristicFormatString: String = "2904"
public let CBUUIDCharacteristicAggregateFormatString: String = "2905"
public let CBUUIDCharacteristicValidRangeString: String = "2906"

@available(*, unavailable)
public let CBUUIDL2CAPPSMCharacteristicString: String = "2A36"

open class CBUUID {
    private lazy var uuid: UUID
    /// Stores the original short-form UUID if provided (e.g., "180A")
    private var shortFormUUID: String? = nil

    @available(*, unavailable)
    open var data: Data { fatalError() }

    /// Returns the UUID string.
    /// For short-form 16-bit UUIDs, returns the short form (e.g., "180A") for CoreBluetooth compatibility.
    /// For full 128-bit UUIDs, returns the full uppercase format.
    open var uuidString: String {
        if let short = shortFormUUID {
            return short.uppercased()
        }
        return uuid.uuidString.uppercased()
    }

    /// The Bluetooth Base UUID suffix (after the first 8 characters)
    private static let bluetoothBaseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Valid hex characters for UUID validation
    private static let hexCharacters = "0123456789ABCDEFabcdef"

    /// Check if a character is a valid hex digit
    private static func isHexChar(_ char: Character) -> Bool {
        return hexCharacters.contains(char)
    }

    /// Expands a short-form UUID (16-bit or 32-bit) to full 128-bit Bluetooth UUID
    private static func expandShortUUID(_ shortUUID: String) -> String? {
        let trimmed = shortUUID.trimmingCharacters(in: .whitespaces).uppercased()

        // Check if it looks like a short UUID (4 hex chars for 16-bit, or 8 hex chars for 32-bit)
        guard trimmed.count == 4 || trimmed.count == 8 else {
            return nil
        }

        // Validate it's all hex characters
        for char in trimmed {
            if !isHexChar(char) {
                return nil
            }
        }

        // Expand to 128-bit: XXXXXXXX-0000-1000-8000-00805F9B34FB
        // For 16-bit: 0000XXXX-0000-1000-8000-00805F9B34FB
        let paddedUUID = trimmed.count == 4 ? "0000\(trimmed)" : trimmed
        return "\(paddedUUID)\(bluetoothBaseSuffix)"
    }

    /// Extracts the short form from a full Bluetooth Base UUID if applicable.
    /// Returns nil if not a standard Bluetooth Base UUID.
    /// E.g., "0000180A-0000-1000-8000-00805F9B34FB" → "180A"
    /// E.g., "12345678-0000-1000-8000-00805F9B34FB" → "12345678" (32-bit)
    private static func extractShortUUID(_ fullUUID: String) -> String? {
        let upper = fullUUID.uppercased()

        // Full Bluetooth Base UUID is 36 characters: XXXXXXXX-0000-1000-8000-00805F9B34FB
        guard upper.count == 36 else {
            return nil
        }

        // Check if it ends with the Bluetooth Base UUID suffix
        guard upper.hasSuffix(bluetoothBaseSuffix) else {
            return nil
        }

        // Extract the first 8 characters (the variable part) using prefix
        let prefix = String(upper.prefix(8))

        // If it starts with "0000", return the 16-bit short form (last 4 chars of prefix)
        if prefix.hasPrefix("0000") {
            return String(prefix.suffix(4))
        }

        // Otherwise return the 32-bit form
        return prefix
    }

    public init(string theString: String) {
        // First try parsing as a full 128-bit UUID
        if let uuid = UUID(uuidString: theString) {
            self.uuid = uuid
            // Check if this is a standard Bluetooth Base UUID that can be shortened
            self.shortFormUUID = CBUUID.extractShortUUID(theString)
        } else if let expanded = CBUUID.expandShortUUID(theString),
                  let uuid = UUID(uuidString: expanded) {
            // It's a short-form UUID - expand it and store the original short form
            self.uuid = uuid
            self.shortFormUUID = theString.uppercased()
        } else {
            // Invalid UUID string - log error but create a nil UUID
            // This matches CoreBluetooth behavior which would crash on invalid input
            logger.error("CBUUID: Invalid UUID string: \(theString)")
            self.uuid = UUID()
            self.shortFormUUID = nil
        }
    }

    @available(*, unavailable)
    public init(data theData: Data) { fatalError()}

    @available(*, unavailable)
    public init(cfuuid theUUID: Any) { fatalError() }

    public init(nsuuid: UUID) {
        self.uuid = nsuuid
        // Check if this is a standard Bluetooth Base UUID that can be shortened
        self.shortFormUUID = CBUUID.extractShortUUID(nsuuid.uuidString)
    }
}

extension CBUUID: Equatable {
    public static func == (lhs: CBUUID, rhs: CBUUID) -> Bool {
        return lhs.uuidString == rhs.uuidString
    }
}

extension CBUUID: KotlinConverting<java.util.UUID> {
    // SKIP @nooverride
    public override func kotlin(nocopy: Bool = false) -> java.util.UUID {
        return uuid.kotlin()
    }
}

#endif
#endif

