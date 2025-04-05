# SkipBluetooth

This is a [Skip](https://skip.tools) Swift/Kotlin library project that
provides API parity to `CoreBluetooth` for Android.

## Implementation Instructions

`SkipBluetooth` aims to provide API parity to `CoreBluetooth`, but in a few cases, this requires using `// SKIP DECLARE:` in your implementation.

There are delegate methods which have the same argument type signature (despite having differently-named parameters) in `CoreBluetooth`, and are therefore recognized as the same function to `gradle` since Kotlin doesn't differentiate between function calls based on parameter names. One such collision example is:

```
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
func centralManager(central: CBCentralManager, DidUpdateANCSAuthorizationFor peripheral: CBPeripheral)
```

In order to implement these functions in your `CBCentralManagerDelegate` implementation, you should write the function call as you would do in Swift, but put the corresponding `// SKIP DECLARE: ...` line above that function which corresponds to the Kotlin-compliant API call.

Here is an example:

```
/* Assuming this function is inside of a class conforming to `CBCentralManagerDelegate` */

// SKIP DECLARE: override fun centralManagerDidConnect(central: CBCentralManager, didConnect: CBPeripheral)
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    /* Your implementation here */
}
```

Here is a list of all such currently-available functions and their corresponding calls:

**CBCentralManagerDelegate**

| CoreBluetooth                                                                                                             | SkipBluetooth                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)`                                   | `// SKIP DECLARE: override fun centralManagerDidConnect(central: CBCentralManager, didConnect: CBPeripheral)`                                       |
| `func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral)`                | `// SKIP DECLARE: override fun centralManagerDidUpdateANCSAuthorizationFor(central: CBCentralManager, didUpdateANCSAuthorizationFor: CBPeripheral)` |
| `func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?)` | `// SKIP DECLARE: override fun centralManagerDidDisconnectPeripheral(central: CBCentralManager, peripheral: CBPeripheral, error: (any Error)?)`     |

**CBPeripheralManagerDelegate**

| CoreBluetooth                                                                                                                        | SkipBluetooth                                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic)`     | `// SKIP DECLARE: override fun peripheralManagerDidSubscribeTo(peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo: CBCharacteristic)`         |
| `func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic)` | `// SKIP DECLARE: override fun peripheralManagerDidUnsubscribeFrom(peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom: CBCharacteristic)` |

**CBPeripheralDelegate**

| CoreBluetooth | SkipBluetooth |
| ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?)` | `// SKIP DECLARE: override fun peripheralDidUpdateValueFor(peripheral: CBPeripheral, didUpdateValueFor: CBCharacteristic, error: Error?)`
| `func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?)` | `// SKIP DECLARE: override fun peripheralDidWriteValueFor(peripheral: CBPeripheral, didWriteValueFor: CBCharacteristic, error: Error?)`
| `func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?)` | `// SKIP DECLARE: override fun peripheralDidUpdateNotificationStateFor(peripheral: CBPeripheral, didUpdateNotificationStateFor: CBCharacteristic, error: Error?)`
| `func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?)` | `// SKIP DECLARE: override fun peripheralDidDiscoverCharacteristicsFor(peripheral: CBPeripheral, didDiscoverCharacteristicsFor: CBService, error: Error?)` |

### Asking for Permissions

Bluetooth requires permissions for both IOS and Kotlin, so you must add the following to your Info.plist file:

- [NSBluetoothAlwaysUsageDescription](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbluetoothalwaysusagedescription)

and these to your AndroidManifest.xml

```
<manifest>
    <!-- What you need generally -->
    <uses-permission android:name="android.permission.BLUETOOTH" />

    <!-- Allows elevated privileges (like turning on and off on android) -->
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />

    <!-- If you want central privileges

    Because you can use bluetooth to discern the user's fine-grained location, you can use this attribute
    to assure that you don't need bluetooth for their location (or remove it and signal your use in the converse)
    -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />

    <!-- If you want peripheral privileges -->
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />

    <!-- If you want to connect in either case -->
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
    <!-- other properties -->
</manifest>
```

> [!IMPORTANT]
> You must request runtime permissions in an `#IF SKIP` block to prevent your app from crashing

Before using any Bluetooth API's, you must request user permissions.
One way to do this is to use the `PermissionManager` API in
[SkipKit](https://github.com/skiptools/skip-kit#permissionmanager):

```swift
import SkipKit

func performBluetoothOperation() async {
    if await PermissionManager.requestPermission("android.permission.BLUETOOTH_SCAN") == true {
        if await PermissionManager.requestPermission("android.permission.BLUETOOTH_CONNECT") == true {
            // perform bluetooth operation…
        }
    }
}
```

An example of manually requesting a permission without using `SkipKit` is as follows.
In this scenario, note that you must request user permissions **in the body of the view or function**
which will use Bluetooth.

```swift
import SwiftUI

#if SKIP
import SkipBluetooth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
#endif

struct ContentView: View {
    var body: some View {
#if SKIP
    askForBluetoothPermissions()
#endif
    }
}

/// Prompts the user to allow bluetooth permissions
@Composable
public func askForBluetoothPermissions() {
    let requestPermissionLauncher = rememberLauncherForActivityResult(contract = ActivityResultContracts.RequestMultiplePermissions()) { perms in
        // Handle permissions here if you'd like
    }

    let permissions: kotlin.Array<String> = kotlin.arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT
    )

    // Skip can't implicitly convert between kotlin.Array<string> and
    // skip.lib.Array<String> hence the cast
    SideEffect {
        requestPermissionLauncher.launch(permissions)
    }
}
#endif
```

This will request Bluetooth permissions as soon as the view appears. Subsequent loads of this view will
not show the prompt again—you will have to request the user to enable Bluetooth in settings if they denied
permission previously.

## Building

This project is a free Swift Package Manager module that uses the
[Skip](https://skip.tools) plugin to transpile Swift into Kotlin.

Building the module requires that Skip be installed using
[Homebrew](https://brew.sh) with `brew install skiptools/skip/skip`.
This will also install the necessary build prerequisites:
Kotlin, Gradle, and the Android build tools.

## Testing

The module can be tested using the standard `swift test` command
or by running the test target for the macOS destination in Xcode,
which will run the Swift tests as well as the transpiled
Kotlin JUnit tests in the Robolectric Android simulation environment.

Parity testing can be performed with `skip test`,
which will output a table of the test results for both platforms.

## Contributing

We welcome contributions to this package in the form of enhancements and bug fixes.

The general flow for contributing to this and any other Skip package is:

1. Fork this repository and enable actions from the "Actions" tab
2. Check out your fork locally
3. When developing alongside a Skip app, add the package to a [shared workspace](https://skip.tools/docs/contributing) to see your changes incorporated in the app
4. Push your changes to your fork and ensure the CI checks all pass in the Actions tab
5. Add your name to the Skip [Contributor Agreement](https://github.com/skiptools/clabot-config)
6. Open a Pull Request from your fork with a description of your changes

## License

This software is licensed under the
[GNU Lesser General Public License v3.0](https://spdx.org/licenses/LGPL-3.0-only.html),
with the following
[linking exception](https://spdx.org/licenses/LGPL-3.0-linking-exception.html)
to clarify that distribution to restricted environments (e.g., app stores)
is permitted:

> This software is licensed under the LGPL3, included below.
> As a special exception to the GNU Lesser General Public License version 3
> ("LGPL3"), the copyright holders of this Library give you permission to
> convey to a third party a Combined Work that links statically or dynamically
> to this Library without providing any Minimal Corresponding Source or
> Minimal Application Code as set out in 4d or providing the installation
> information set out in section 4e, provided that you comply with the other
> provisions of LGPL3 and provided that you meet, for the Application the
> terms and conditions of the license(s) which apply to the Application.
> Except as stated in this special exception, the provisions of LGPL3 will
> continue to comply in full to this Library. If you modify this Library, you
> may apply this exception to your version of this Library, but you are not
> obliged to do so. If you do not wish to do so, delete this exception
> statement from your version. This exception does not (and cannot) modify any
> license terms which apply to the Application, with which you must still
> comply.

