package dev.zeekr.bluetooth_low_energy_android

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
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
    private val mMainHandler = Handler(Looper.getMainLooper())

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

        private const val SPOTLINK_SERVICE_UUID = "7370746c-696e-6b00-8000-00805f9b34fb"
        private const val SPOTLINK_DEVICE_NAME = "SL"
        private const val APPLE_COMPANY_ID = 0x004C
        private const val MIN_SCAN_RESTART_GAP_MS = 8000L
        // Native-initiated scan restarts that failed are retried this many times
        // (each spaced by MIN_SCAN_RESTART_GAP_MS) before giving up until the
        // next Dart-side startDiscovery.
        private const val SCAN_RESTART_MAX_RETRIES = 3
        private const val GATT_BUSY_MAX_RETRIES = 10
        private const val GATT_BUSY_RETRY_DELAY_MS = 30L
    }

    private val mScanCallback: ScanCallback by lazy { ScanCallbackImpl(this) }
    private val mBluetoothGattCallback: BluetoothGattCallback by lazy { BluetoothGattCallbackImpl(this, executor) }

    private var mDiscovering: Boolean
    private var mLastServiceUUIDsArgs: List<String> = emptyList()
    private var mLastScanStartUptimeMs: Long = 0L
    private var mScreenSwapRunnable: Runnable? = null
    private var mScanRestartRetries = 0

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

    private fun isAuthorized(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.all { permission ->
                ActivityCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
            }
        } else {
            ActivityCompat.checkSelfPermission(
                context, Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
                ActivityCompat.checkSelfPermission(
                    context, Manifest.permission.ACCESS_COARSE_LOCATION
                ) == PackageManager.PERMISSION_GRANTED
        }
    }

    @RequiresPermission(allOf = [Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN])
    override fun initialize(): CentralManagerArgs {
        cancelPendingScreenSwap()
        if (mDiscovering) {
            try {
                stopDiscovery()
            } catch (_: Throwable) {
            }
        }

        for (gatt in mGATTs.values) {
            try {
                gatt.disconnect()
                // A gatt stuck mid-connect never reaches STATE_DISCONNECTED, so
                // the close in onConnectionStateChange wouldn't run — release the
                // client interface unconditionally.
                gatt.close()
            } catch (_: Throwable) {
            }
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
            if (isAuthorized()) adapter.state.toBluetoothLowEnergyStateArgs()
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

    /**
     * SpotLink fork:
     * - When the screen is ON (`PowerManager.isInteractive == true`) and `serviceUUIDsArgs` is empty,
     *   pass `null` for a true unfiltered scan so buggy OEM hardware filters are bypassed completely.
     * - When the screen is OFF (`!isInteractive`), Android 8.1+ `ScanManager` silently suspends ALL
     *   scan results if `filters == null` (even with a foreground service). To keep discovering peers
     *   while the phone screen is off, we supply a 3-way OR filter list covering every SpotLink peer
     *   signature:
     *   1) SpotLink 128-bit service UUID (Android & foreground iOS peers)
     *   2) SpotLink advertised device name "SL"
     *   3) Apple manufacturer data (0x004C) for background/foreground iPhone Continuity probing.
     */
    private fun buildEffectiveScanFilters(serviceUUIDsArgs: List<String>): List<ScanFilter>? {
        if (serviceUUIDsArgs.isNotEmpty()) {
            val filters = mutableListOf<ScanFilter>()
            for (serviceUuidArgs in serviceUUIDsArgs) {
                val serviceUUID = ParcelUuid.fromString(serviceUuidArgs)
                filters.add(ScanFilter.Builder().setServiceUuid(serviceUUID).build())
            }
            return filters
        }
        val pm = ContextCompat.getSystemService(context, PowerManager::class.java)
        val interactive = pm?.isInteractive ?: true
        if (interactive) {
            return null
        }
        return listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid.fromString(SPOTLINK_SERVICE_UUID))
                .build(),
            ScanFilter.Builder()
                .setDeviceName(SPOTLINK_DEVICE_NAME)
                .build(),
            ScanFilter.Builder()
                .setManufacturerData(APPLE_COMPANY_ID, ByteArray(0))
                .build()
        )
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    private fun startScannerWithFallback(filters: List<ScanFilter>?) {
        val preferredSettings = ScanSettings.Builder()
            .setScanMode(scanMode)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0L)
            .build()
        try {
            scanner.startScan(filters, preferredSettings, mScanCallback)
        } catch (_: IllegalArgumentException) {
            // Budget OEM BLE chipsets may reject MATCH_MODE_AGGRESSIVE or MATCH_NUM_MAX_ADVERTISEMENT.
            val fallbackSettings = ScanSettings.Builder()
                .setScanMode(scanMode)
                .build()
            scanner.startScan(filters, fallbackSettings, mScanCallback)
        }
        mLastScanStartUptimeMs = SystemClock.elapsedRealtime()
    }

    private fun cancelPendingScreenSwap() {
        mScreenSwapRunnable?.let { mMainHandler.removeCallbacks(it) }
        mScreenSwapRunnable = null
    }

    /**
     * Restarts the running scan from the native side: on screen on/off (to swap
     * between unfiltered and screen-off filters) and, with [retry], after a
     * native-initiated restart failed. Dart cannot see these restarts — its
     * scanning flag stays true and its own start becomes a no-op — so a failed
     * restart must be retried here, or discovery silently stays dead until the
     * next Dart-side stop/start.
     */
    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    private fun scheduleScreenFilterSwap(retry: Boolean = false) {
        cancelPendingScreenSwap()
        if (!mDiscovering) return
        if (retry) {
            if (mScanRestartRetries >= SCAN_RESTART_MAX_RETRIES) return
            mScanRestartRetries++
        } else if (mLastServiceUUIDsArgs.isNotEmpty()) {
            return // filtered scans don't depend on the screen state
        }
        val elapsed = SystemClock.elapsedRealtime() - mLastScanStartUptimeMs
        var delayMs = if (elapsed >= MIN_SCAN_RESTART_GAP_MS) 250L else (MIN_SCAN_RESTART_GAP_MS - elapsed + 250L)
        if (retry) {
            // 10 s, 20 s, 30 s: a SCANNING_TOO_FREQUENTLY failure only clears after
            // the 30 s window, so retrying at the bare 8 s gap would just fail again.
            delayMs = maxOf(delayMs, 10_000L * mScanRestartRetries)
        }
        val runnable = Runnable {
            mScreenSwapRunnable = null
            if (!mDiscovering) return@Runnable
            if (!retry && mLastServiceUUIDsArgs.isNotEmpty()) return@Runnable
            if (adapter.state != BluetoothAdapter.STATE_ON) return@Runnable
            try {
                scanner.stopScan(mScanCallback)
            } catch (_: Throwable) {
            }
            try {
                val filters = buildEffectiveScanFilters(mLastServiceUUIDsArgs)
                startScannerWithFallback(filters)
            } catch (_: Throwable) {
                // The scan is now stopped while Dart believes it is running.
                scheduleScreenFilterSwap(retry = true)
            }
        }
        mScreenSwapRunnable = runnable
        mMainHandler.postDelayed(runnable, delayMs)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    override fun startDiscovery(serviceUUIDsArgs: List<String>, callback: (Result<Unit>) -> Unit) {
        try {
            cancelPendingScreenSwap()
            mScanRestartRetries = 0
            mLastServiceUUIDsArgs = serviceUUIDsArgs
            val filters = buildEffectiveScanFilters(serviceUUIDsArgs)
            startScannerWithFallback(filters)
            executor.execute { onScanSucceeded() }
            mStartDiscoveryCallback = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    override fun stopDiscovery() {
        cancelPendingScreenSwap()
        try {
            scanner.stopScan(mScanCallback)
        } catch (_: Throwable) {
        }
        mDiscovering = false
    }

    // SpotLink fork: engine destroyed (activity swiped away while the
    // foreground service keeps the process alive). Without this the scanner
    // stays registered against the dead callback — the "zombie scannerId"
    // that keeps receiving results forever — and every open GATT client
    // holds its slot until the process dies.
    override fun dispose() {
        cancelPendingScreenSwap()
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
        val address = peripheralArgs.addressArgs
        mDevices[address] = device
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

    private fun failPendingCallbacks(addressArgs: String, error: Throwable) {
        mConnectCallbacks.remove(addressArgs)?.invoke(Result.failure(error))
        mRequestMtuCallbacks.remove(addressArgs)?.invoke(Result.failure(error))
        mReadRssiCallbacks.remove(addressArgs)?.invoke(Result.failure(error))
        mDiscoverServicesCallbacks.remove(addressArgs)?.invoke(Result.failure(error))
        mReadCharacteristicCallbacks.remove(addressArgs)?.values?.forEach { it(Result.failure(error)) }
        mWriteCharacteristicCallbacks.remove(addressArgs)?.values?.forEach { it(Result.failure(error)) }
        mReadDescriptorCallbacks.remove(addressArgs)?.values?.forEach { it(Result.failure(error)) }
        mWriteDescriptorCallbacks.remove(addressArgs)?.values?.forEach { it(Result.failure(error)) }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun connect(addressArgs: String, callback: (Result<Unit>) -> Unit) {
        try {
            val device = mDevices.getOrPut(addressArgs) { adapter.getRemoteDevice(addressArgs) }
            mGATTs.remove(addressArgs)?.let { oldGatt ->
                try {
                    oldGatt.disconnect()
                    oldGatt.close()
                } catch (_: Exception) {
                }
            }
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
            failPendingCallbacks(addressArgs, IllegalStateException("Superseded by new connect"))
            val autoConnect = false
            val transport = BluetoothDevice.TRANSPORT_LE
            val gatt = device.connectGatt(context, autoConnect, mBluetoothGattCallback, transport)
                ?: throw IllegalStateException("connectGatt returned null")
            mGATTs[addressArgs] = gatt
            mConnectCallbacks[addressArgs] = callback
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun disconnect(addressArgs: String, callback: (Result<Unit>) -> Unit) {
        try {
            val gatt = mGATTs.remove(addressArgs) ?: throw IllegalArgumentException()
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
            failPendingCallbacks(addressArgs, IllegalStateException("Disconnected by local host"))
            try {
                gatt.disconnect()
            } catch (_: Throwable) {
            }
            // SpotLink fork: gatt.disconnect() is a NO-OP on a still-CONNECTING
            // gatt (the common case when a probe/connect times out) — it never
            // reaches STATE_DISCONNECTED, so onConnectionStateChange never runs
            // and the BluetoothGatt client interface leaks. Android has a small
            // (~30) global GATT client pool; once exhausted, ALL new connects
            // fail. close() releases it unconditionally. We fire the callback
            // now and drop the maps, since no state-change callback will come.
            try {
                gatt.close()
            } catch (_: Throwable) {
            }
            callback(Result.success(Unit))
        } catch (e: Throwable) {
            callback(Result.failure(e))
        }
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun requestMTU(addressArgs: String, mtuArgs: Long, callback: (Result<Long>) -> Unit) {
        fun tryRequestMtu(attempt: Int) {
            try {
                val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
                val mtu = mtuArgs.toInt()
                val requesting = gatt.requestMtu(mtu)
                if (!requesting) {
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryRequestMtu(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                mRequestMtuCallbacks[addressArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryRequestMtu(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun readRSSI(addressArgs: String, callback: (Result<Long>) -> Unit) {
        fun tryReadRssi(attempt: Int) {
            try {
                val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
                val reading = gatt.readRemoteRssi()
                if (!reading) {
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryReadRssi(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                mReadRssiCallbacks[addressArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryReadRssi(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun discoverGATT(addressArgs: String, callback: (Result<List<GATTServiceArgs>>) -> Unit) {
        fun tryDiscover(attempt: Int) {
            try {
                val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
                val discovering = gatt.discoverServices()
                if (!discovering) {
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryDiscover(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                mDiscoverServicesCallbacks[addressArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryDiscover(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun readCharacteristic(addressArgs: String, hashCodeArgs: Long, callback: (Result<ByteArray>) -> Unit) {
        fun tryRead(attempt: Int) {
            try {
                val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
                val characteristic = retrieveCharacteristic(addressArgs, hashCodeArgs)
                val reading = gatt.readCharacteristic(characteristic)
                if (!reading) {
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryRead(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                val callbacks = mReadCharacteristicCallbacks.getOrPut(addressArgs) { mutableMapOf() }
                callbacks[hashCodeArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryRead(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun writeCharacteristic(
        addressArgs: String,
        hashCodeArgs: Long,
        valueArgs: ByteArray,
        typeArgs: GATTCharacteristicWriteTypeArgs,
        callback: (Result<Unit>) -> Unit
    ) {
        fun tryWrite(attempt: Int) {
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
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryWrite(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                val callbacks = mWriteCharacteristicCallbacks.getOrPut(addressArgs) { mutableMapOf() }
                callbacks[hashCodeArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryWrite(0)
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
        fun tryReadDesc(attempt: Int) {
            try {
                val gatt = mGATTs[addressArgs] ?: throw IllegalArgumentException()
                val descriptor = retrieveDescriptor(addressArgs, hashCodeArgs)
                val reading = gatt.readDescriptor(descriptor)
                if (!reading) {
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryReadDesc(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                val callbacks = mReadDescriptorCallbacks.getOrPut(addressArgs) { mutableMapOf() }
                callbacks[hashCodeArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryReadDesc(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    override fun writeDescriptor(
        addressArgs: String, hashCodeArgs: Long, valueArgs: ByteArray, callback: (Result<Unit>) -> Unit
    ) {
        fun tryWriteDesc(attempt: Int) {
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
                    if (attempt < GATT_BUSY_MAX_RETRIES) {
                        mMainHandler.postDelayed({ tryWriteDesc(attempt + 1) }, GATT_BUSY_RETRY_DELAY_MS)
                        return
                    }
                    throw IllegalStateException()
                }
                val callbacks = mWriteDescriptorCallbacks.getOrPut(addressArgs) { mutableMapOf() }
                callbacks[hashCodeArgs] = callback
            } catch (e: Throwable) {
                callback(Result.failure(e))
            }
        }
        tryWriteDesc(0)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_SCAN)
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            BluetoothAdapter.ACTION_STATE_CHANGED -> {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.STATE_OFF)
                if (state != BluetoothAdapter.STATE_ON) {
                    cancelPendingScreenSwap()
                    mDiscovering = false
                }
                val stateArgs = state.toBluetoothLowEnergyStateArgs()
                mApi.onStateChanged(stateArgs) {}
            }
            Intent.ACTION_SCREEN_OFF, Intent.ACTION_SCREEN_ON -> {
                scheduleScreenFilterSwap()
            }
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
        val authorized = isAuthorized() ||
            (permissions.contentEquals(this.permissions) && results.all { r -> r == PackageManager.PERMISSION_GRANTED })
        callback(Result.success(authorized))
        return true
    }

    private fun onScanSucceeded() {
        mDiscovering = true
        val callback = mStartDiscoveryCallback ?: return
        mStartDiscoveryCallback = null
        callback(Result.success(Unit))
    }

    @SuppressLint("MissingPermission") // only reached after a scan was started
    fun onScanFailed(errorCode: Int) {
        val callback = mStartDiscoveryCallback
        if (callback == null) {
            // No Dart start is pending: this failure belongs to a native restart
            // (screen swap) or arrived after startDiscovery already reported
            // success. Dart still thinks the scan runs, so recover here.
            if (errorCode == ScanCallback.SCAN_FAILED_ALREADY_STARTED) return
            scheduleScreenFilterSwap(retry = true)
            return
        }
        mDiscovering = false
        mStartDiscoveryCallback = null
        val error = IllegalStateException("Start discovery failed with error code: $errorCode")
        callback(Result.failure(error))
    }

    fun onScanResult(result: ScanResult) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !result.isConnectable) {
            return
        }
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
        val addressArgs = device.address
        // Ignore late callbacks from a stale BluetoothGatt instance that was already replaced or closed.
        if (mGATTs[addressArgs] !== gatt) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                try {
                    gatt.close()
                } catch (_: Throwable) {
                }
            }
            return
        }
        val isConnected =
            status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED
        if (!isConnected) {
            try {
                gatt.disconnect()
            } catch (_: Throwable) {
            }
            try {
                gatt.close()
            } catch (_: Throwable) {
            }
            mGATTs.remove(addressArgs)
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
            val connectCallback = mConnectCallbacks.remove(addressArgs)
            if (connectCallback != null) {
                val error = IllegalStateException("Connect failed with status: $status, newState: $newState")
                connectCallback(Result.failure(error))
            }
            val error = IllegalStateException("GATT is disconnected with status: $status")
            failPendingCallbacks(addressArgs, error)
        } else {
            val connectCallback = mConnectCallbacks.remove(addressArgs)
            connectCallback?.invoke(Result.success(Unit))
        }
        val disconnectCallback = mDisconnectCallbacks.remove(addressArgs)
        if (disconnectCallback != null) {
            if (status == BluetoothGatt.GATT_SUCCESS || !isConnected) {
                disconnectCallback(Result.success(Unit))
            } else {
                val error = IllegalStateException("Disconnect failed with status: $status")
                disconnectCallback(Result.failure(error))
            }
        }
        // invoke connection state changed event.
        val peripheralArgs = device.toPeripheralArgs()
        val effectiveState = if (isConnected) BluetoothProfile.STATE_CONNECTED else BluetoothProfile.STATE_DISCONNECTED
        val stateArgs = effectiveState.toConnectionStateArgs()
        mApi.onConnectionStateChanged(peripheralArgs, stateArgs) {}
    }

    fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        if (mGATTs[addressArgs] !== gatt) return
        val result = if (status == BluetoothGatt.GATT_SUCCESS) {
            val peripheralArgs = device.toPeripheralArgs()
            val mtuArgs = mtu.args
            mApi.onMTUChanged(peripheralArgs, mtuArgs) {}
            Result.success(mtuArgs)
        } else {
            val error = IllegalStateException("Request MTU failed with status: $status")
            Result.failure(error)
        }
        val callback = mRequestMtuCallbacks.remove(addressArgs) ?: return
        callback(result)
    }

    fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
        val device = gatt.device
        val addressArgs = device.address
        if (mGATTs[addressArgs] !== gatt) return
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
        if (mGATTs[addressArgs] !== gatt) return
        val callback = mDiscoverServicesCallbacks.remove(addressArgs) ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            mCharacteristics.remove(addressArgs)
            mDescriptors.remove(addressArgs)
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
        if (mGATTs[addressArgs] !== gatt) return
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
        if (mGATTs[addressArgs] !== gatt) return
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
        val addressArgs = device.address
        if (mGATTs[addressArgs] !== gatt) return
        val peripheralArgs = device.toPeripheralArgs()
        val characteristicArgs = characteristic.toArgs()
        mApi.onCharacteristicNotified(peripheralArgs, characteristicArgs, value) {}
    }

    fun onDescriptorRead(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int, value: ByteArray) {
        val device = gatt.device
        val addressArgs = device.address
        if (mGATTs[addressArgs] !== gatt) return
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
        if (mGATTs[addressArgs] !== gatt) return
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
