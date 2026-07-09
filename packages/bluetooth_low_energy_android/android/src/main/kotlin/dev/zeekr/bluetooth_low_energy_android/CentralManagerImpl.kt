package dev.zeekr.bluetooth_low_energy_android

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.ParcelUuid
import android.provider.Settings
import androidx.annotation.RequiresPermission
import androidx.core.app.ActivityCompat
import androidx.core.app.ActivityOptionsCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class CentralManagerImpl(context: Context, binaryMessenger: BinaryMessenger) : BluetoothLowEnergyManagerImpl(context),
    CentralManagerHostApi {
    private val mApi: CentralManagerFlutterApi
    private val mScanPowerChannel: MethodChannel

    companion object {
        // SpotLink fork: runtime-selectable scan mode so the mesh can trade
        // discovery latency for battery. LOW_LATENCY when actively hunting,
        // BALANCED once the link set is stable. Volatile: set from the
        // `spotlink/scan_power` channel (any isolate), read on the next
        // startScan. Changing it takes effect when the transport restarts the
        // scan (it always stop→starts on a power change), so no live re-scan
        // is forced here.
        @Volatile
        @JvmStatic
        var scanMode: Int = ScanSettings.SCAN_MODE_LOW_LATENCY
    }

    private val mScanCallback: ScanCallback by lazy { ScanCallbackImpl(this) }
    private val mBluetoothGattCallback: BluetoothGattCallback by lazy { BluetoothGattCallbackImpl(this, executor) }

    private var mDiscovering: Boolean

    private val mDevices: MutableMap<String, BluetoothDevice>
    private val mGATTs: MutableMap<String, BluetoothGatt>
    private val mCharacteristics: MutableMap<String, MutableMap<Long, BluetoothGattCharacteristic>>
    private val mDescriptors: MutableMap<String, MutableMap<Long, BluetoothGattDescriptor>>

    private var mAuthorizeCallback: ((Result<Boolean>) -> Unit)?
    private var mStartDiscoveryCallback: ((Result<Unit>) -> Unit)?
    private val mConnectCallbacks: MutableMap<String, (Result<Unit>) -> Unit>
    private val mDisconnectCallbacks: MutableMap<String, (Result<Unit>) -> Unit>
    private val mRequestMtuCallbacks: MutableMap<String, (Result<Long>) -> Unit>
    private val mReadRssiCallbacks: MutableMap<String, (Result<Long>) -> Unit>
    private val mDiscoverServicesCallbacks: MutableMap<String, (Result<List<GATTServiceArgs>>) -> Unit>
    private val mReadCharacteristicCallbacks: MutableMap<String, MutableMap<Long, (Result<ByteArray>) -> Unit>>
    private val mWriteCharacteristicCallbacks: MutableMap<String, MutableMap<Long, (Result<Unit>) -> Unit>>
    private val mReadDescriptorCallbacks: MutableMap<String, MutableMap<Long, (Result<ByteArray>) -> Unit>>
    private val mWriteDescriptorCallbacks: MutableMap<String, MutableMap<Long, (Result<Unit>) -> Unit>>

    init {
        mApi = CentralManagerFlutterApi(binaryMessenger)
        // SpotLink fork: accept a desired scan mode from Dart (0=LOW_POWER,
        // 1=BALANCED, 2=LOW_LATENCY, matching ScanSettings constants).
        mScanPowerChannel = MethodChannel(binaryMessenger, "spotlink/scan_power")
        mScanPowerChannel.setMethodCallHandler { call, result ->
            if (call.method == "setScanMode") {
                val mode = (call.arguments as? Int) ?: ScanSettings.SCAN_MODE_LOW_LATENCY
                scanMode = when (mode) {
                    0 -> ScanSettings.SCAN_MODE_LOW_POWER
                    1 -> ScanSettings.SCAN_MODE_BALANCED
                    else -> ScanSettings.SCAN_MODE_LOW_LATENCY
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        mDiscovering = false

        mDevices = mutableMapOf()
        mGATTs = mutableMapOf()
        mCharacteristics = mutableMapOf()
        mDescriptors = mutableMapOf()

        mAuthorizeCallback = null
        mStartDiscoveryCallback = null
        mConnectCallbacks = mutableMapOf()
        mDisconnectCallbacks = mutableMapOf()
        mRequestMtuCallbacks = mutableMapOf()
        mReadRssiCallbacks = mutableMapOf()
        mDiscoverServicesCallbacks = mutableMapOf()
        mReadCharacteristicCallbacks = mutableMapOf()
        mWriteCharacteristicCallbacks = mutableMapOf()
        mReadDescriptorCallbacks = mutableMapOf()
        mWriteDescriptorCallbacks = mutableMapOf()
    }

    private val permissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
        }
    private val manager
        get() = ContextCompat.getSystemService(
            context, BluetoothManager::class.java
        ) as BluetoothManager
    private val adapter get() = manager.adapter as BluetoothAdapter
    private val scanner: BluetoothLeScanner get() = adapter.bluetoothLeScanner
    private val executor get() = ContextCompat.getMainExecutor(context)

    @RequiresPermission(allOf = [Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN])
    override fun initialize(): CentralManagerArgs {
        if (mDiscovering) {
            stopDiscovery()
        }

        for (gatt in mGATTs.values) {
            gatt.disconnect()
            // A gatt stuck mid-connect never reaches STATE_DISCONNECTED, so
            // the close in onConnectionStateChange wouldn't run — release the
            // client interface unconditionally.
            gatt.close()
        }

        mDevices.clear()
        mGATTs.clear()
        mCharacteristics.clear()
        mDescriptors.clear()

        mAuthorizeCallback = null
        mStartDiscoveryCallback = null
        mConnectCallbacks.clear()
        mDisconnectCallbacks.clear()
        mRequestMtuCallbacks.clear()
        mReadRssiCallbacks.clear()
        mDiscoverServicesCallbacks.clear()
        mReadCharacteristicCallbacks.clear()
        mWriteCharacteristicCallbacks.clear()
        mReadDescriptorCallbacks.clear()
        mWriteDescriptorCallbacks.clear()

        val enableNotificationValue = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val enableIndicationValue = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        val disableNotificationValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        return CentralManagerArgs(enableNotificationValue, enableIndicationValue, disableNotificationValue)
    }

    override fun getState(): BluetoothLowEnergyStateArgs {
        val supported = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        return if (supported) {
            val authorized = permissions.all { permission ->
                ActivityCompat.checkSelfPermission(
                    context, permission
                ) == PackageManager.PERMISSION_GRANTED
            }
            if (authorized) adapter.state.toBluetoothLowEnergyStateArgs()
            else BluetoothLowEnergyStateArgs.UNAUTHORIZED
        } else BluetoothLowEnergyStateArgs.UNSUPPORTED
    }

    override fun authorize(callback: (Result<Boolean>) -> Unit) {
        try {
            ActivityCompat.requestPermissions(activity, permissions, AUTHORIZE_CODE)
            mAuthorizeCallback = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    override fun showAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        intent.data = Uri.fromParts("package", activity.packageName, null)
        val options = ActivityOptionsCompat.makeBasic().toBundle()
        ActivityCompat.startActivity(activity, intent, options)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    override fun startDiscovery(serviceUUIDsArgs: List<String>, callback: (Result<Unit>) -> Unit) {
        try {
            val filters = mutableListOf<ScanFilter>()
            for (serviceUuidArgs in serviceUUIDsArgs) {
                val serviceUUID = ParcelUuid.fromString(serviceUuidArgs)
                val filter = ScanFilter.Builder().setServiceUuid(serviceUUID).build()
                filters.add(filter)
            }
            val settings = ScanSettings.Builder().setScanMode(scanMode).build()
            // SpotLink fork: an EMPTY (non-null) filter list is not the same as
            // no filter — on many stacks (Samsung) it yields zero results. Pass
            // null for a true unfiltered scan so iOS peers, whose 128-bit
            // service UUID sits in the BLE overflow area and never matches a
            // ServiceUuid ScanFilter, are still discovered (matched in Dart).
            scanner.startScan(if (filters.isEmpty()) null else filters, settings, mScanCallback)
            executor.execute { onScanSucceeded() }
            mStartDiscoveryCallback = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    override fun stopDiscovery() {
        scanner.stopScan(mScanCallback)
        mDiscovering = false
    }

    // SpotLink fork: engine destroyed (activity swiped away while the
    // foreground service keeps the process alive). Without this the scanner
    // stays registered against the dead callback — the "zombie scannerId"
    // that keeps receiving results forever — and every open GATT client
    // holds its slot until the process dies.
    override fun dispose() {
        try {
            scanner.stopScan(mScanCallback)
        } catch (_: Exception) {
        }
        mDiscovering = false
        for (gatt in mGATTs.values) {
            try {
                gatt.close()
            } catch (_: Exception) {
            }
        }
        mGATTs.clear()
        super.dispose()
    }

    override fun getPeripheral(addressArgs: String): PeripheralArgs {
        val device = adapter.getRemoteDevice(addressArgs)
        val peripheralArgs = device.toPeripheralArgs()
        val addressArgs = peripheralArgs.addressArgs
        mDevices[addressArgs] = device
        return peripheralArgs
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun retrieveConnectedPeripherals(): List<PeripheralArgs> {
        // The `BluetoothProfile.GATT` and `BluetoothProfile.GATT_SERVER` return same devices.
        val devices = manager.getConnectedDevices(BluetoothProfile.GATT)
        val peripheralsArgs = devices.map { device ->
            val peripheralArgs = device.toPeripheralArgs()
            val addressArgs = peripheralArgs.addressArgs
            mDevices[addressArgs] = device
            return@map peripheralArgs
        }
        return peripheralsArgs
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun connect(addressArgs: String, callback: (Result<Unit>) -> Unit) {
        try {
            val device = mDevices[addressArgs] ?: throw IllegalArgumentException()
            val autoConnect = false
            val transport = BluetoothDevice.TRANSPORT_LE
            // Add to bluetoothGATTs cache.
            mGATTs[addressArgs] = device.connectGatt(context, autoConnect, mBluetoothGattCallback, transport)
            mConnectCallbacks[addressArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun disconnect(addressArgs: String, callback: (Result<Unit>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            gatt.disconnect()
            // SpotLink fork: gatt.disconnect() is a NO-OP on a still-CONNECTING
            // gatt (the common case when a probe/connect times out) — it never
            // reaches STATE_DISCONNECTED, so onConnectionStateChange never runs
            // and the BluetoothGatt client interface leaks. Android has a small
            // (~30) global GATT client pool; once exhausted, ALL new connects
            // fail. close() releases it unconditionally. We fire the callback
            // now and drop the maps, since no state-change callback will come.
            gatt.close()
            mGATTs.remove(addressArgs)
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
            callback(Result.success(Unit))
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun requestMTU(addressArgs: String, mtuArgs: Long, callback: (Result<Long>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val mtu = mtuArgs.toInt()
            val requesting = gatt.requestMtu(mtu)
            if (!requesting) {
                throw IllegalStateException()
            }
            mRequestMtuCallbacks[addressArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun readRSSI(addressArgs: String, callback: (Result<Long>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val reading = gatt.readRemoteRssi()
            if (!reading) {
                throw IllegalStateException()
            }
            mReadRssiCallbacks[addressArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun discoverGATT(addressArgs: String, callback: (Result<List<GATTServiceArgs>>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val discovering = gatt.discoverServices()
            if (!discovering) {
                throw IllegalStateException()
            }
            mDiscoverServicesCallbacks[addressArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun readCharacteristic(addressArgs: String, hashCodeArgs: Long, callback: (Result<ByteArray>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val characteristic = retrieveCharacteristic(addressArgs, hashCodeArgs)
            val reading = gatt.readCharacteristic(characteristic)
            if (!reading) {
                throw IllegalStateException()
            }
            val callbacks = mReadCharacteristicCallbacks.getOrPut(addressArgs) { mutableMapOf() }
            callbacks[hashCodeArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun writeCharacteristic(
        addressArgs: String,
        hashCodeArgs: Long,
        valueArgs: ByteArray,
        typeArgs: GATTCharacteristicWriteTypeArgs,
        callback: (Result<Unit>) -> Unit
    ) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val characteristic = retrieveCharacteristic(addressArgs, hashCodeArgs)
            val type = typeArgs.toType()
            val writing = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val code = gatt.writeCharacteristic(characteristic, valueArgs, type)
                code == BluetoothStatusCodes.SUCCESS
            } else { // TODO: remove this when minSdkVersion >= 33
                characteristic.value = valueArgs
                characteristic.writeType = type
                gatt.writeCharacteristic(characteristic)
            }
            if (!writing) {
                throw IllegalStateException()
            }
            val callbacks = mWriteCharacteristicCallbacks.getOrPut(addressArgs) { mutableMapOf() }
            callbacks[hashCodeArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun setCharacteristicNotification(addressArgs: String, hashCodeArgs: Long, enableArgs: Boolean) {
        val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
        val characteristic = retrieveCharacteristic(addressArgs, hashCodeArgs)
        val notifying = gatt.setCharacteristicNotification(characteristic, enableArgs)
        if (!notifying) {
            throw IllegalStateException()
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun readDescriptor(addressArgs: String, hashCodeArgs: Long, callback: (Result<ByteArray>) -> Unit) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val descriptor = retrieveDescriptor(addressArgs, hashCodeArgs)
            val reading = gatt.readDescriptor(descriptor)
            if (!reading) {
                throw IllegalStateException()
            }
            val callbacks = mReadDescriptorCallbacks.getOrPut(addressArgs) { mutableMapOf() }
            callbacks[hashCodeArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun writeDescriptor(
        addressArgs: String, hashCodeArgs: Long, valueArgs: ByteArray, callback: (Result<Unit>) -> Unit
    ) {
        try {
            val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
            val descriptor = retrieveDescriptor(addressArgs, hashCodeArgs)
            val writing = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val code = gatt.writeDescriptor(descriptor, valueArgs)
                code == BluetoothStatusCodes.SUCCESS
            } else { // TODO: remove this when minSdkVersion >= 33
                descriptor.value = valueArgs
                gatt.writeDescriptor(descriptor)
            }
            if (!writing) {
                throw IllegalStateException()
            }
            val callbacks = mWriteDescriptorCallbacks.getOrPut(addressArgs) { mutableMapOf() }
            callbacks[hashCodeArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) {
            return
        }
        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF)
        val stateArgs = state.toBluetoothLowEnergyStateArgs()
        mApi.onStateChanged(stateArgs) {}
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, results: IntArray
    ): Boolean {
        if (requestCode != AUTHORIZE_CODE) {
            return false
        }
        val callback = mAuthorizeCallback ?: return false
        mAuthorizeCallback = null
        val authorized =
            permissions.contentEquals(this.permissions) && results.all { r -> r == PackageManager.PERMISSION_GRANTED }
        callback(Result.success(authorized))
        return true
    }

    private fun onScanSucceeded() {
        mDiscovering = true
        val callback = mStartDiscoveryCallback ?: return
        mStartDiscoveryCallback = null
        callback(Result.success(Unit))
    }

    fun onScanFailed(errorCode: Int) {
        val callback = mStartDiscoveryCallback ?: return
        mStartDiscoveryCallback = null
        val error = IllegalStateException("Start discovery failed with error code: $errorCode")
        callback(Result.failure(error))
    }

    fun onScanResult(result: ScanResult) {
        val device = result.device
        val peripheralArgs = device.toPeripheralArgs()
        val addressArgs = peripheralArgs.addressArgs
        val rssiArgs = result.rssi.args
        val advertisementArgs = result.toAdvertisementArgs()
        mDevices[addressArgs] = device
        mApi.onDiscovered(peripheralArgs, rssiArgs, advertisementArgs) {}
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        val device = gatt.device
        val addressArgs = device.address // check connection state.
        if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            gatt.close()
            mGATTs.remove(addressArgs)
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
            val error = IllegalStateException("GATT is disconnected with status: $status")
            val requestMtuCallback = mRequestMtuCallbacks.remove(addressArgs)
            if (requestMtuCallback != null) {
                requestMtuCallback(Result.failure(error))
            }
            val readRssiCallback = mReadRssiCallbacks.remove(addressArgs)
            if (readRssiCallback != null) {
                readRssiCallback(Result.failure(error))
            }
            val discoverServicesCallback = mDiscoverServicesCallbacks.remove(addressArgs)
            if (discoverServicesCallback != null) {
                discoverServicesCallback(Result.failure(error))
            }
            val readCharacteristicCallbacks = mReadCharacteristicCallbacks.remove(addressArgs)
            if (readCharacteristicCallbacks != null) {
                val callbacks = readCharacteristicCallbacks.values
                for (callback in callbacks) {
                    callback(Result.failure(error))
                }
            }
            val writeCharacteristicCallbacks = mWriteCharacteristicCallbacks.remove(addressArgs)
            if (writeCharacteristicCallbacks != null) {
                val callbacks = writeCharacteristicCallbacks.values
                for (callback in callbacks) {
                    callback(Result.failure(error))
                }
            }
            val readDescriptorCallbacks = mReadDescriptorCallbacks.remove(addressArgs)
            if (readDescriptorCallbacks != null) {
                val callbacks = readDescriptorCallbacks.values
                for (callback in callbacks) {
                    callback(Result.failure(error))
                }
            }
            val writeDescriptorCallbacks = mWriteDescriptorCallbacks.remove(addressArgs)
            if (writeDescriptorCallbacks != null) {
                val callbacks = writeDescriptorCallbacks.values
                for (callback in callbacks) {
                    callback(Result.failure(error))
                }
            }
        }
        // check connect callback.
        val connectCallback = mConnectCallbacks.remove(addressArgs)
        if (connectCallback != null) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                connectCallback(Result.success(Unit))
            } else {
                val error = IllegalStateException("Connect failed with status: $status")
                connectCallback(Result.failure(error))
            }
        }
        // check disconnect callback.
        val disconnectCallback = mDisconnectCallbacks.remove(addressArgs)
        if (disconnectCallback != null) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                disconnectCallback(Result.success(Unit))
            } else {
                val error = IllegalStateException("Disconnect failed with status: $status")
                disconnectCallback(Result.failure(error))
            }
        }
        // invoke connection state changed event.
        val peripheralArgs = device.toPeripheralArgs()
        val stateArgs = newState.toConnectionStateArgs()
        mApi.onConnectionStateChanged(peripheralArgs, stateArgs) {}
    }

    fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        val result = if (status == BluetoothGatt.GATT_SUCCESS) {
            val peripheralArgs = device.toPeripheralArgs()
            val mtuArgs = mtu.args
            mApi.onMTUChanged(peripheralArgs, mtuArgs) {}
            Result.success(mtuArgs)
        } else {
            val error = IllegalStateException("Read RSSI failed with status: $status")
            Result.failure(error)
        }
        val callback = mRequestMtuCallbacks.remove(addressArgs) ?: return
        callback(result)
    }

    fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        val callback = mReadRssiCallbacks.remove(addressArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            val rssiArgs = rssi.args
            callback(Result.success(rssiArgs))
        } else {
            val error = IllegalStateException("Read RSSI failed with status: $status")
            callback(Result.failure(error))
        }
    }

    fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        val callback = mDiscoverServicesCallbacks.remove(addressArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            val services = gatt.services
            for (service in services) {
                addService(addressArgs, service)
            }
            val servicesArgs = services.map { it.toArgs() }
            callback(Result.success(servicesArgs))
        } else {
            val error = IllegalStateException("Discover GATT failed with status: $status")
            callback(Result.failure(error))
        }
    }

    fun onCharacteristicRead(
        gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int, value: ByteArray
    ) {
        val device = gatt.device
        val addressArgs = device.address
        val hashCodeArgs = characteristic.hashCode.args
        val callbacks = mReadCharacteristicCallbacks[addressArgs] ?: return
        val callback = callbacks.remove(hashCodeArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(value))
        } else {
            val error = IllegalStateException("Read characteristic failed with status: $status.")
            callback(Result.failure(error))
        }
    }

    fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        val hashCodeArgs = characteristic.hashCode.args
        val callbacks = mWriteCharacteristicCallbacks[addressArgs] ?: return
        val callback = callbacks.remove(hashCodeArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(Unit))
        } else {
            val error = IllegalStateException("Write characteristic failed with status: $status.")
            callback(Result.failure(error))
        }
    }

    fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        val device = gatt.device
        val peripheralArgs = device.toPeripheralArgs()
        val characteristicArgs = characteristic.toArgs()
        mApi.onCharacteristicNotified(peripheralArgs, characteristicArgs, value) {}
    }

    fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int, value: ByteArray) {
        val device = gatt.device
        val addressArgs = device.address
        val hashCodeArgs = descriptor.hashCode.args
        val callbacks = mReadDescriptorCallbacks[addressArgs] ?: return
        val callback = callbacks.remove(hashCodeArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(value))
        } else {
            val error = IllegalStateException("Read descriptor failed with status: $status.")
            callback(Result.failure(error))
        }
    }

    fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        val hashCodeArgs = descriptor.hashCode.args
        val callbacks = mWriteDescriptorCallbacks[addressArgs] ?: return
        val callback = callbacks.remove(hashCodeArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(Unit))
        } else {
            val error = IllegalStateException("Write descriptor failed with status: $status.")
            callback(Result.failure(error))
        }
    }

    private fun addService(addressArgs: String, service: BluetoothGattService) {
        val includedServices = service.includedServices
        for (includedService in includedServices) {
            addService(addressArgs, includedService)
        }
        for (characteristic in service.characteristics) {
            for (descriptor in characteristic.descriptors) {
                val descriptors = mDescriptors.getOrPut(addressArgs) { mutableMapOf() }
                descriptors[descriptor.hashCode.args] = descriptor
            }
            val characteristics = mCharacteristics.getOrPut(addressArgs) { mutableMapOf() }
            characteristics[characteristic.hashCode.args] = characteristic
        }
    }

    private fun retrieveCharacteristic(addressArgs: String, hashCodeArgs: Long): BluetoothGattCharacteristic {
        val characteristics = mCharacteristics[addressArgs] ?: throw IllegalArgumentException()
        return characteristics[hashCodeArgs] ?: throw IllegalArgumentException()
    }

    private fun retrieveDescriptor(addressArgs: String, hashCodeArgs: Long): BluetoothGattDescriptor {
        val descriptors = mDescriptors[addressArgs] ?: throw IllegalArgumentException()
        return descriptors[hashCodeArgs] ?: throw IllegalArgumentException()
    }
}
