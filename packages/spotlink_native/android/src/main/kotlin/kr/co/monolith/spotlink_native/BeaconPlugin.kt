package kr.co.monolith.spotlink_native

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID

/**
 * SpotLink 웨이크 beacon 송신기. Android는 백그라운드에서 iBeacon 프레임을
 * 무기한 광고할 수 있으므로, 모든 Android 노드가 "웨이크 횃불" 역할까지
 * 겸한다: SpotLink beacon region을 모니터링 중인 iPhone은 우리가 가까이
 * 오면 CoreLocation에 의해 다시 실행된다 — 사용자가 스와이프로 강제 종료한
 * 경우에도.
 *
 * iOS BeaconPlugin.swift와 동일한 채널 계약(`spotlink/beacon`)을 쓰지만,
 * 여기서는 TX 절반만 해당된다 (Android는 beacon 웨이크 RX가 필요 없다:
 * 포그라운드 서비스가 이미 메시를 살려 두고 있다).
 */
class BeaconPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        // BeaconPlugin.swift의 beaconUUIDs와 반드시 일치해야 한다 (인덱스 0 = 원본).
        // 송신하는 UUID를 로테이션하여, 한 region "안에" 갇힌 iPhone도 우리가
        // 다른 region을 켤 때 새로운 ENTER를 받도록 한다 — BeaconPlugin.swift의
        // 긴 주석 참고.
        val BEACON_UUIDS: List<UUID> = listOf(
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5D"),
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5E"),
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5F"),
        )
        private const val APPLE_MANUFACTURER_ID = 0x004C
        private const val ROTATE_MS = 18_000L

        // 프로세스 전역 advertiser 상태 (엔진 단위가 아님 — 의도적):
        // UI 엔진이 죽은(스와이프 강제 종료) 뒤에도 횃불은 계속 타올라야 한다 —
        // 포그라운드 서비스가 프로세스를 유지하고, 이 beacon이 바로 근처의
        // 스와이프로 종료된 iPhone들을 되살린다. static으로 두면 엔진이 다시
        // 붙는 상황에서도 startTx가 멱등해진다(중복 advertise 세트 없음).
        private var advertiser: BluetoothLeAdvertiser? = null
        private var callback: AdvertiseCallback? = null
        private var txIndex = 0
        private var rotateHandler: Handler? = null
        private var rotateRunnable: Runnable? = null
    }

    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        MethodChannel(binding.binaryMessenger, "spotlink/beacon")
            .setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // 계속 광고한다: 엔진 소멸(액티비티 종료)은 프로세스 소멸이 아니며,
        // beacon은 프로세스에 속한다.
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startTx" -> { startTx(); result.success(null) }
            "stopTx" -> { stopTx(); result.success(null) }
            "status" -> result.success(
                mapOf("auth" to "always", "monitoring" to false))
            // iOS 전용 RX 메서드들은 여기서 아무 동작도 하지 않는다.
            "requestAlways" -> result.success(null)
            "enableMonitoring" -> result.success(false)
            "disableMonitoring" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    /** Apple의 manufacturer data 안에 담기는 iBeacon 레이아웃:
     *  type(0x02) len(0x15) uuid(16B) major(2B) minor(2B) txPower(1B). */
    private fun beaconPayload(uuid: UUID): ByteArray {
        val buf = ByteBuffer.allocate(23)
        buf.put(0x02).put(0x15)
        buf.putLong(uuid.mostSignificantBits)
        buf.putLong(uuid.leastSignificantBits)
        buf.putShort(0) // major
        buf.putShort(0) // minor
        buf.put(0xC5.toByte()) // 1m에서의 측정 전력 (일반적인 값)
        return buf.array()
    }

    @Suppress("MissingPermission")
    private fun startTx() {
        startAdvertisingCurrent()
        // 초기 시작이 실패했더라도(블루투스 꺼짐 / 아직 advertiser 없음) 로테이션을
        // 무조건 가동한다: 18초마다의 각 틱이 restartAdvertising →
        // startAdvertisingCurrent를 호출하므로, 로테이션은 어댑터가 돌아왔을 때
        // 횃불을 다시 켜는 재시도 루프 역할도 겸한다. (이전에는 BT 꺼진 상태로
        // 부팅하면 앱/서비스를 완전히 재시작하기 전까지 횃불이 꺼진 채 남아 있었다.)
        if (BEACON_UUIDS.size > 1 && rotateRunnable == null) {
            val h = Handler(Looper.getMainLooper())
            rotateHandler = h
            val r = object : Runnable {
                override fun run() {
                    txIndex = (txIndex + 1) % BEACON_UUIDS.size
                    restartAdvertising()
                    h.postDelayed(this, ROTATE_MS)
                }
            }
            rotateRunnable = r
            h.postDelayed(r, ROTATE_MS)
        }
    }

    @Suppress("MissingPermission")
    private fun startAdvertisingCurrent() {
        if (callback != null) return // 이미 광고 중
        val adapter =
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
                ?: return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        advertiser = adv
        // BALANCED (~250ms 간격) + HIGH 전력: iPhone의 화면 꺼짐 상태 region
        // 모니터링이 웨이크를 발생시키려면 beacon을 실제로 들을 수 있어야 한다 —
        // LOW_POWER의 ~1초 간격에 MEDIUM 전력은 탐지를 느리고 근거리로만 만들었다
        // (관측: 크로스 플랫폼 웨이크가 굼떴다). 이것은 웨이크 횃불이며,
        // 도달 가능성이 그 존재 이유의 전부다.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder()
            .addManufacturerData(APPLE_MANUFACTURER_ID, beaconPayload(BEACON_UUIDS[txIndex]))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        // onStartFailure는 중요하다: (예: 메시 advert 세트가 올라와 있는 동안의
        // TOO_MANY_ADVERTISERS 같은) 비동기 실패는 예전에 `callback`을 설정된 채로
        // 남겨 두었다 — 실제로는 아무것도 전파되지 않는데 우리는 횃불이 켜졌다고
        // 믿었다. 이를 지워 두면 다음 로테이션 틱의 restartAdvertising이 깔끔하게
        // 재시도할 수 있다.
        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                if (callback === this) callback = null
            }
        }
        callback = cb
        try {
            adv.startAdvertising(settings, data, cb)
        } catch (_: Exception) {
            callback = null
        }
    }

    /** 광고 중인 region을 BEACON_UUIDS[txIndex]로 교체한다. */
    @Suppress("MissingPermission")
    private fun restartAdvertising() {
        val cb = callback
        if (cb != null) {
            callback = null
            try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
        }
        startAdvertisingCurrent()
    }

    @Suppress("MissingPermission")
    private fun stopTx() {
        rotateRunnable?.let { rotateHandler?.removeCallbacks(it) }
        rotateRunnable = null
        rotateHandler = null
        val cb = callback ?: return
        callback = null
        try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
    }
}
