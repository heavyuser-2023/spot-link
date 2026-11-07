package dev.zeekr.bluetooth_low_energy_android

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.annotation.RequiresPermission
import androidx.core.app.ActivityCompat
import androidx.core.app.ActivityOptionsCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger

class PeripheralManagerImpl(context: Context, binaryMessenger: BinaryMessenger) :
    BluetoothLowEnergyManagerImpl(context), PeripheralManagerHostApi {
    private val mApi: PeripheralManagerFlutterApi
    private val mMainHandler = Handler(Looper.getMainLooper())

    private val mBluetoothGattServerCallback: BluetoothGattServerCallback by lazy {
        BluetoothGattServerCallbackImpl(
            this, executor
        )
    }
    private val mAdvertiseCallback: AdvertiseCallback by lazy { AdvertiseCallbackImpl(this) }

    private var mServer: BluetoothGattServer?
    private var mAdvertising: Boolean

    private val mServicesArgs: MutableMap<Int, MutableGATTServiceArgs>
    private val mCharacteristicsArgs: MutableMap<Int, MutableGATTCharacteristicArgs>
    private val mDescriptorsArgs: MutableMap<Int, MutableGATTDescriptorArgs>

    private val mDevices: MutableMap<String, BluetoothDevice>
    private val mServices: MutableMap<Long, BluetoothGattService>
    private val mCharacteristics: MutableMap<Long, BluetoothGattCharacteristic>
    private val mDescriptors: MutableMap<Long, BluetoothGattDescriptor>

    private var mAuthorizeCallback: ((Result<Boolean>) -> Unit)?
    private var mSetNameCallback: ((Result<String?>) -> Unit)?
    private var mAddServiceCallback: ((Result<Unit>) -> Unit)?
    private var mStartAdvertisingCallback: ((Result<Unit>) -> Unit)?
    private val mNotifyCharacteristicValueChangedCallbacks: MutableMap<String, (Result<Unit>) -> Unit>

    init {
        mApi = PeripheralManagerFlutterApi(binaryMessenger)

        mServer = null
        mAdvertising = false

        mServicesArgs = mutableMapOf()
        mCharacteristicsArgs = mutableMapOf()
        mDescriptorsArgs = mutableMapOf()

        mDevices = mutableMapOf()
        mServices = mutableMapOf()
        mCharacteristics = mutableMapOf()
        mDescriptors = mutableMapOf()

        mAuthorizeCallback = null
        mSetNameCallback = null
        mAddServiceCallback = null
        mStartAdvertisingCallback = null
        mNotifyCharacteristicValueChangedCallbacks = mutableMapOf()
    }

    private val permissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            // Android 11(API 30) 이하에서는 BLE 광고 및 GATT 서버 동작에 위치 권한이
            // 필요하지 않다(매니페스트의 BLUETOOTH / BLUETOOTH_ADMIN으로 충분).
            emptyArray()
        }
    private val manager
        get() = ContextCompat.getSystemService(context, BluetoothManager::class.java) as BluetoothManager
    private val adapter get() = manager.adapter as BluetoothAdapter
    private val advertiser get() = adapter.bluetoothLeAdvertiser
    private val server get() = mServer ?: throw IllegalStateException()
    private val executor get() = ContextCompat.getMainExecutor(context)

    @RequiresPermission(allOf = [Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE])
    override fun initialize(): PeripheralManagerArgs {
        if (mAdvertising) {
            stopAdvertising()
        }

        mServer?.close()
        mServer = null

        mServicesArgs.clear()
        mCharacteristicsArgs.clear()
        mDescriptorsArgs.clear()

        mDevices.clear()
        mServices.clear()
        mCharacteristics.clear()
        mDescriptors.clear()

        mAuthorizeCallback = null
        mSetNameCallback = null
        mAddServiceCallback = null
        mStartAdvertisingCallback = null
        mNotifyCharacteristicValueChangedCallbacks.clear()

        val enableNotificationValue = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val enableIndicationValue = BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        val disableNotificationValue = BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        return PeripheralManagerArgs(enableNotificationValue, enableIndicationValue, disableNotificationValue)
    }

    override fun getState(): BluetoothLowEnergyStateArgs {
        // SpotLink fork: do NOT gate on adapter.isMultipleAdvertisementSupported.
        // Single-slot BLE chipsets return false there yet still support a GATT
        // server and single-slot advertising (which is all SpotLink needs once
        // the wake torch yields). Returning UNSUPPORTED left _peripheral dead.
        val supported =
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
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
            if (permissions.isEmpty()) {
                callback(Result.success(true))
                return
            }
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

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun setName(nameArgs: String, callback: (Result<String?>) -> Unit) {
        try {
            // SpotLink fork: when the adapter name is ALREADY equal to nameArgs
            // (e.g. "SL" persisted from a previous run), Android's BluetoothAdapter
            // does NOT broadcast ACTION_LOCAL_NAME_CHANGED, which used to hang
            // this future forever -> 8s timeout -> dropping the advertised name.
            if (adapter.name == nameArgs) {
                callback(Result.success(nameArgs))
                return
            }
            val setting = adapter.setName(nameArgs)
            if (!setting) {
                // Some OEM ROMs reject setName; proceed without hanging.
                callback(Result.success(nameArgs))
                return
            }
            mSetNameCallback = callback
            mMainHandler.postDelayed({
                val pending = mSetNameCallback ?: return@postDelayed
                if (pending === callback) {
                    mSetNameCallback = null
                    pending(Result.success(nameArgs))
                }
            }, 600L)
        } catch (_: Throwable) {
            callback(Result.success(nameArgs))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun openGATTServer() {
        // Close any previous instance first: reassigning without close leaks
        // a live server registration (a second serverIf) that keeps serving a
        // stale copy of our GATT service — remote centrals then bind to the
        // dead copy and their writes go nowhere.
        mServer?.close()
        mServer = manager.openGattServer(context, mBluetoothGattServerCallback)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun closeGATTServer() {
        server.close()
    }

    // SpotLink fork: engine destroyed — release the advertiser and the GATT
    // server, or they survive as zombies for the life of the process and a
    // re-entered app registers a duplicate serverIf next to them.
    override fun dispose() {
        try {
            if (mAdvertising) stopAdvertising()
        } catch (_: Exception) {
        }
        mAdvertising = false
        try {
            mServer?.close()
        } catch (_: Exception) {
        }
        mServer = null
        super.dispose()
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun addService(serviceArgs: MutableGATTServiceArgs, callback: (Result<Unit>) -> Unit) {
        try {
            val service = addServiceArgs(serviceArgs)
            val adding = server.addService(service)
            if (!adding) {
                throw IllegalStateException()
            }
            mAddServiceCallback = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun removeService(hashCodeArgs: Long) {
        val service = mServices[hashCodeArgs] ?: throw IllegalArgumentException()
        val removed = server.removeService(service)
        if (!removed) {
            throw IllegalStateException()
        }
        val hashCode = service.hashCode()
        val serviceArgs = mServicesArgs[hashCode] ?: throw IllegalArgumentException()
        removeServiceArgs(serviceArgs)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun removeAllServices() {
        // Stock behaviour: clear services but keep the single GATT server open.
        // (An earlier fork closed+reopened the server here; that raced with the
        // manager's own initialize() and produced TWO servers in one process —
        // the very dual-server bug it tried to prevent. With the mesh running
        // in a single isolate now, one server is opened once and reused.)
        server.clearServices()
        mServices.clear()
        mCharacteristics.clear()
        mDescriptors.clear()

        mServicesArgs.clear()
        mCharacteristicsArgs.clear()
        mDescriptorsArgs.clear()
    }

    override fun startAdvertising(
        settingsArgs: AdvertiseSettingsArgs,
        advertiseDataArgs: AdvertiseDataArgs,
        scanResponseArgs: AdvertiseDataArgs,
        callback: (Result<Unit>) -> Unit
    ) {
        try {
            val settings = settingsArgs.toAdvertiseSettings()
            // SpotLink fork: when the adapter name is short (e.g. "SL", 2 bytes)
            // and we only advertise a single 128-bit service UUID with no extra
            // service/manufacturer data, Flags(3B) + UUID(18B) + Name(4B) = 25B
            // fits comfortably inside the 31B primary advertisement packet.
            // Including it in the primary packet guarantees iOS/Android scanners
            // see both the UUID and 'SL' even if a SCAN_RSP packet is missed.
            // Conversely, if an OEM ROM (Xiaomi/Huawei/Samsung) ignored setName("SL")
            // and kept a long multi-byte device name (e.g. Korean name > 29 UTF-8 bytes),
            // including the device name even in scanResponse overflows the 31B limit
            // and causes ADVERTISE_FAILED_DATA_TOO_LARGE (error code 1). Drop
            // includeDeviceNameArgs whenever the actual adapter name is not short!
            val shortAdapterName = try {
                val n = adapter.name
                n != null && n.toByteArray(Charsets.UTF_8).size <= 4
            } catch (_: Throwable) {
                false
            }
            val effectiveAdvertiseDataArgs =
                if (shortAdapterName &&
                    scanResponseArgs.includeDeviceNameArgs == true &&
                    advertiseDataArgs.serviceUUIDsArgs.size <= 1 &&
                    advertiseDataArgs.serviceDataArgs.isEmpty() &&
                    advertiseDataArgs.manufacturerSpecificDataArgs.isEmpty()
                ) {
                    advertiseDataArgs.copy(includeDeviceNameArgs = true)
                } else {
                    advertiseDataArgs.copy(includeDeviceNameArgs = false)
                }
            val effectiveScanResponseArgs =
                if (shortAdapterName) {
                    scanResponseArgs
                } else {
                    scanResponseArgs.copy(includeDeviceNameArgs = false)
                }
            val advertiseData = effectiveAdvertiseDataArgs.toAdvertiseData()
            val scanResponse = effectiveScanResponseArgs.toAdvertiseData()
            advertiser.startAdvertising(settings, advertiseData, scanResponse, mAdvertiseCallback)
            mStartAdvertisingCallback = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    override fun stopAdvertising() {
        try {
            advertiser.stopAdvertising(mAdvertiseCallback)
        } catch (_: Throwable) {
        }
        mAdvertising = false
    }

    override fun getCentral(addressArgs: String): CentralArgs {
        val device = adapter.getRemoteDevice(addressArgs)
        val centralArgs = device.toCentralArgs()
        val addressArgs = centralArgs.addressArgs
        mDevices[addressArgs] = device
        return centralArgs
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun retrieveConnectedCentrals(): List<CentralArgs> {
        // The `BluetoothProfile.GATT` and `BluetoothProfile.GATT_SERVER` return same devices.
        val devices = manager.getConnectedDevices(BluetoothProfile.GATT_SERVER)
        val centralsArgs = devices.map { device ->
            val centralArgs = device.toCentralArgs()
            val addressArgs = centralArgs.addressArgs
            mDevices[addressArgs] = device
            return@map centralArgs
        }
        return centralsArgs
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun disconnect(addressArgs: String) {
        val device = mDevices.getOrPut(addressArgs) { adapter.getRemoteDevice(addressArgs) }
        server.cancelConnection(device)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun sendResponse(
        addressArgs: String, idArgs: Long, statusArgs: GATTStatusArgs, offsetArgs: Long, valueArgs: ByteArray?
    ) {
        val device = mDevices.getOrPut(addressArgs) { adapter.getRemoteDevice(addressArgs) }
        val requestId = idArgs.toInt()
        val status = statusArgs.toStatus()
        val offset = offsetArgs.toInt()
        val sent = server.sendResponse(device, requestId, status, offset, valueArgs)
        if (!sent) {
            throw IllegalStateException("Send response failed.")
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun notifyCharacteristicChanged(
        addressArgs: String,
        hashCodeArgs: Long,
        confirmArgs: Boolean,
        valueArgs: ByteArray,
        callback: (Result<Unit>) -> Unit
    ) {
        fun attempt(retriesLeft: Int) {
            try {
                val device = mDevices.getOrPut(addressArgs) { adapter.getRemoteDevice(addressArgs) }
                val characteristic = mCharacteristics[hashCodeArgs] ?: throw IllegalArgumentException()
                val notifying = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val statusCode = server.notifyCharacteristicChanged(device, characteristic, confirmArgs, valueArgs)
                    statusCode == BluetoothStatusCodes.SUCCESS
                } else { // TODO: remove this when minSdkVersion >= 33
                    characteristic.value = valueArgs
                    server.notifyCharacteristicChanged(device, characteristic, confirmArgs)
                }
                if (!notifying) {
                    if (retriesLeft > 0) {
                        mMainHandler.postDelayed({ attempt(retriesLeft - 1) }, 30L)
                        return
                    }
                    throw IllegalStateException("notifyCharacteristicChanged busy/failed")
                }
                mNotifyCharacteristicValueChangedCallbacks[addressArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        attempt(10)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            BluetoothAdapter.ACTION_STATE_CHANGED -> {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF)
                val stateArgs = state.toBluetoothLowEnergyStateArgs()
                mApi.onStateChanged(stateArgs) {}
            }

            BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED -> {
                val callback = mSetNameCallback ?: return
                mSetNameCallback = null
                val nameArgs = intent.getStringExtra(BluetoothAdapter.EXTRA_LOCAL_NAME)
                callback(Result.success(nameArgs))
            }

            else -> {}
        }
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

    fun onServiceAdded(status: Int, service: BluetoothGattService) {
        val callback = mAddServiceCallback ?: return
        mAddServiceCallback = null
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(Unit))
        } else {
            val error = IllegalStateException("Add service failed with status: $status")
            callback(Result.failure(error))
        }
    }

    fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
        mAdvertising = true
        val callback = mStartAdvertisingCallback ?: return
        mStartAdvertisingCallback = null
        callback(Result.success(Unit))
    }

    fun onStartFailure(errorCode: Int) {
        val callback = mStartAdvertisingCallback ?: return
        mStartAdvertisingCallback = null
        val error = IllegalStateException("Start advertising failed with error code: $errorCode")
        callback(Result.failure(error))
    }

    fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
        val centralArgs = device.toCentralArgs()
        val addressArgs = centralArgs.addressArgs
        val statusArgs = status.args
        val stateArgs = newState.toConnectionStateArgs()
        mDevices[addressArgs] = device
        if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            val notifyCallback = mNotifyCharacteristicValueChangedCallbacks.remove(addressArgs)
            if (notifyCallback != null) {
                notifyCallback(Result.failure(IllegalStateException("Central disconnected with status: $status")))
            }
        }
        mApi.onConnectionStateChanged(centralArgs, statusArgs, stateArgs) {}
    }

    fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val mtuArgs = mtu.args
        mApi.onMTUChanged(centralArgs, mtuArgs) {}
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun onCharacteristicReadRequest(
        device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic
    ) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val idArgs = requestId.args
        val offsetArgs = offset.args
        val hashCode = characteristic.hashCode()
        val characteristicArgs = mCharacteristicsArgs[hashCode]
        if (characteristicArgs == null) {
            val status = BluetoothGatt.GATT_FAILURE
            server.sendResponse(device, requestId, status, offset, null)
        } else {
            val hashCodeArgs = characteristicArgs.hashCodeArgs
            mApi.onCharacteristicReadRequest(centralArgs, idArgs, offsetArgs, hashCodeArgs) {}
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun onCharacteristicWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        characteristic: BluetoothGattCharacteristic,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray
    ) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val idArgs = requestId.args
        val hashCode = characteristic.hashCode()
        val characteristicArgs = mCharacteristicsArgs[hashCode]
        if (characteristicArgs == null) {
            if (!responseNeeded) {
                return
            }
            val status = BluetoothGatt.GATT_FAILURE
            server.sendResponse(device, requestId, status, offset, null)
        } else {
            val hashCodeArgs = characteristicArgs.hashCodeArgs
            val offsetArgs = offset.args
            mApi.onCharacteristicWriteRequest(
                centralArgs, idArgs, hashCodeArgs, preparedWrite, responseNeeded, offsetArgs, value
            ) {}
        }
    }

    fun onNotificationSent(device: BluetoothDevice, status: Int) {
        val addressArgs = device.address
        val callback = mNotifyCharacteristicValueChangedCallbacks.remove(addressArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            callback(Result.success(Unit))
        } else {
            val error = IllegalStateException("Notify characteristic value changed failed with status: $status")
            callback(Result.failure(error))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun onDescriptorReadRequest(
        device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor
    ) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val idArgs = requestId.args
        val offsetArgs = offset.args
        val hashCode = descriptor.hashCode()
        val descriptorArgs = mDescriptorsArgs[hashCode]
        if (descriptorArgs == null) {
            val status = BluetoothGatt.GATT_FAILURE
            server.sendResponse(device, requestId, status, offset, null)
        } else {
            val hashCodeArgs = descriptorArgs.hashCodeArgs
            mApi.onDescriptorReadRequest(centralArgs, idArgs, offsetArgs, hashCodeArgs) {}
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun onDescriptorWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        descriptor: BluetoothGattDescriptor,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray
    ) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val idArgs = requestId.args
        val hashCode = descriptor.hashCode()
        val descriptorArgs = mDescriptorsArgs[hashCode]
        if (descriptorArgs == null) {
            if (!responseNeeded) {
                return
            }
            val status = BluetoothGatt.GATT_FAILURE
            server.sendResponse(device, requestId, status, offset, null)
        } else {
            val hashCodeArgs = descriptorArgs.hashCodeArgs
            val offsetArgs = offset.args
            mApi.onDescriptorWriteRequest(
                centralArgs, idArgs, hashCodeArgs, preparedWrite, responseNeeded, offsetArgs, value
            ) {}
        }
    }

    fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
        val centralArgs = device.toCentralArgs()
        mDevices[centralArgs.addressArgs] = device
        val idArgs = requestId.args
        mApi.onExecuteWrite(centralArgs, idArgs, execute) {}
    }

    private fun addServiceArgs(serviceArgs: MutableGATTServiceArgs): BluetoothGattService {
        val service = serviceArgs.toService()
        this.mServicesArgs[service.hashCode] = serviceArgs
        this.mServices[serviceArgs.hashCodeArgs] = service
        val includedServicesArgs = serviceArgs.includedServicesArgs.requireNoNulls()
        for (includedServiceArgs in includedServicesArgs) {
            val includedService = addServiceArgs(includedServiceArgs)
            val adding = service.addService(includedService)
            if (!adding) {
                throw IllegalStateException()
            }
        }
        val characteristicsArgs = serviceArgs.characteristicsArgs.requireNoNulls()
        for (characteristicArgs in characteristicsArgs) {
            val characteristic = characteristicArgs.toCharacteristic()
            this.mCharacteristicsArgs[characteristic.hashCode] = characteristicArgs
            this.mCharacteristics[characteristicArgs.hashCodeArgs] = characteristic
            val descriptorsArgs = characteristicArgs.descriptorsArgs.requireNoNulls()
            for (descriptorArgs in descriptorsArgs) {
                val descriptor = descriptorArgs.toDescriptor()
                this.mDescriptorsArgs[descriptor.hashCode] = descriptorArgs
                this.mDescriptors[descriptorArgs.hashCodeArgs] = descriptor
                val descriptorAdded = characteristic.addDescriptor(descriptor)
                if (!descriptorAdded) {
                    throw IllegalStateException()
                }
            }
            val characteristicAdded = service.addCharacteristic(characteristic)
            if (!characteristicAdded) {
                throw IllegalStateException()
            }
        }
        return service
    }

    private fun removeServiceArgs(serviceArgs: MutableGATTServiceArgs) {
        val includedServicesArgs = serviceArgs.includedServicesArgs.requireNoNulls()
        for (includedServiceArgs in includedServicesArgs) {
            removeServiceArgs(includedServiceArgs)
        }
        val characteristicsArgs = serviceArgs.characteristicsArgs.requireNoNulls()
        for (characteristicArgs in characteristicsArgs) {
            val descriptorsArgs = characteristicArgs.descriptorsArgs.requireNoNulls()
            for (descriptorArgs in descriptorsArgs) {
                val descriptor = mDescriptors.remove(descriptorArgs.hashCodeArgs) ?: throw IllegalArgumentException()
                this.mDescriptorsArgs.remove(descriptor.hashCode)
            }
            val characteristic =
                mCharacteristics.remove(characteristicArgs.hashCodeArgs) ?: throw IllegalArgumentException()
            this.mCharacteristicsArgs.remove(characteristic.hashCode)
        }
        val service = mServices.remove(serviceArgs.hashCodeArgs) ?: throw IllegalArgumentException()
        mServicesArgs.remove(service.hashCode)
    }
}