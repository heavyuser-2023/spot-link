package kr.co.monolith.spotlink_native

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * "스쳐 지나간 친구"(encounter) 기록의 "어디서"를 공급하는 위치 채널
 * `spotlink/location`. 친구의 폰이 가까이 오면 앱이 언제·누구·어디서를
 * 남기는데, 위치는 이 기기에만 저장된다 — 메시 피어에게도, 우리 쪽 서버에도
 * 보내지 않는다. 이 플러그인은 좌표와 지명 한 줄을 Dart에 돌려줄 뿐이다.
 * 단 reverseGeocode는 지명을 얻으려고 좌표를 OS 지오코더(기기의 지오코딩
 * 제공자, 대개 Google)에 묻는다 — 오프라인이면 그냥 null이다.
 *
 * 계약 (iOS BeaconPlugin.swift의 같은 채널과 동일):
 * - `currentLocation {timeoutMs?}` → `{lat, lng, accuracy?}` 또는 null
 * - `reverseGeocode {lat, lng}` → 지명 문자열 또는 null
 * 기대된 실패(권한 없음, 위치 꺼짐, 타임아웃, 제공자 오류, 오프라인)는 전부
 * 예외가 아니라 null로 회신한다 — 위치는 만남 기록의 부가 정보라, 위치를
 * 못 얻었다고 기록 자체가 깨지면 안 된다.
 *
 * UI 엔진과 Activity 없는 포그라운드 서비스 엔진 양쪽에 붙는다
 * (SpotlinkNativePlugin 참고). 그래서 Activity를 절대 요구하지 않는다 —
 * 권한은 확인만 하고, 요청은 Activity가 있는 Dart UI 쪽 몫이다. 백그라운드
 * 위치 권한이 없으므로, UI가 화면에 없을 때 서비스 엔진에서 온 호출은 OS가
 * 위치를 내주지 않아 대개 null로 끝난다(정상 동작).
 * Google Play 서비스 없이 프레임워크 LocationManager/Geocoder만 쓴다 — GMS
 * 없는 기기와 사이드로드 배포에서도 같은 코드가 돈다.
 */
class LocationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        private const val DEFAULT_TIMEOUT_MS = 15_000L

        // 이만큼 신선한 last-known은 새 fix 없이 그대로 쓴다: 만남의 "어디서"에는
        // 1분 전 위치로 충분하고, 무선을 깨우지 않으니 배터리도 들지 않는다.
        private const val FRESH_MS = 60_000L

        // 타임아웃·실패 시의 차선책: 10분 이내의 last-known은 null보다 낫다(같은
        // 동네일 가능성이 높다). 그보다 오래된 위치는 틀린 기록이 될 수 있어 버린다.
        private const val STALE_FALLBACK_MS = 10 * 60_000L

        private const val GEOCODE_TIMEOUT_MS = 10_000L

        // API < 33의 블로킹 Geocoder 호출을 받는 단일 스레드. 프로세스 전역이고
        // 30초 놀면 스레드를 반납한다 — 서비스 프로세스는 며칠씩 살아 있으므로
        // 쉬는 스레드를 붙들고 있지 않는다. 한 줄로 세우는 것은 의도적이다:
        // 오프라인에서 호출마다 네트워크 타임아웃까지 매달려도 스레드가 불어나지
        // 않는다(밀린 요청은 각자의 10초 타임아웃이 null로 정리한다).
        private val geocodeExecutor = ThreadPoolExecutor(
            0, 1, 30L, TimeUnit.SECONDS, LinkedBlockingQueue<Runnable>(),
            ThreadFactory { r -> Thread(r, "spotlink-geocode") },
        )

        /**
         * 주소 조각으로 짧은 지명 한 줄을 만든다 — iOS BeaconPlugin.placeLabel과
         * 같은 규칙: 광역 → 시·구 → 동 → 길 순서로, 빈 조각과 바로 앞 조각과
         * 같은 조각(예: 광역시의 adminArea == locality)은 건너뛰고 공백 하나로
         * 잇는다. 예) 한국어 기기: "서울특별시 강남구 역삼동 테헤란로".
         * locality가 없는 주소(군·시골 지역 등)는 subAdminArea가 그 자리를 메운다.
         * 남는 조각이 없으면 null.
         */
        internal fun placeLabel(address: Address): String? {
            val locality = address.locality?.takeIf { it.isNotBlank() }
                ?: address.subAdminArea
            val parts = ArrayList<String>(4)
            for (raw in arrayOf(
                address.adminArea, locality, address.subLocality, address.thoroughfare,
            )) {
                val part = raw?.trim()
                if (part.isNullOrEmpty()) continue
                if (part == parts.lastOrNull()) continue
                parts.add(part)
            }
            return if (parts.isEmpty()) null else parts.joinToString(" ")
        }
    }

    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    // ---- currentLocation 상태 (전부 메인 스레드 전용) ----
    // 메서드 호출·타임아웃·fix 콜백이 모두 메인 루퍼에서 돌므로 잠금이 필요 없다.
    // 동시에 들어온 호출들은 진행 중인 fix 하나를 함께 기다리고(각자 타임아웃은
    // 따로), fix 한 번이 모두를 해결한다.
    private val waiters = ArrayList<FixWaiter>()

    // 진행 중인 fix 요청의 식별 토큰. null이면 진행 중인 요청이 없다.
    private var fixToken: Any? = null
    private var cancelFix: (() -> Unit)? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "spotlink/location").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        // 엔진이 사라지면 기다릴 쪽도 없다: 대기자에게 계약대로 한 번씩 null을
        // 회신하고, 진행 중인 fix를 끊어 무선을 놓아 준다(API < 30의
        // requestSingleUpdate는 스스로 끝나지 않는다).
        resolveWaiters(null)
        cancelInFlightFix()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "currentLocation" -> {
                val timeoutMs = call.number("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
                currentLocation(timeoutMs.coerceAtLeast(0L), result)
            }
            "reverseGeocode" -> {
                val lat = call.number("lat")?.toDouble()
                val lng = call.number("lng")?.toDouble()
                if (lat == null || lng == null) {
                    result.success(null)
                } else {
                    reverseGeocode(lat, lng, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** 인자 맵에서 숫자 하나. 형식이 어긋나도 던지지 않고 null — 이 채널은
     *  어떤 입력에도 PlatformException을 내지 않는다는 계약이다. */
    private fun MethodCall.number(key: String): Number? =
        try { argument<Any>(key) as? Number } catch (_: Exception) { null }

    // ---- currentLocation ----

    @Suppress("MissingPermission")
    private fun currentLocation(timeoutMs: Long, result: MethodChannel.Result) {
        val lm = locationManager()
        if (lm == null || !hasLocationPermission()) {
            result.success(null)
            return
        }
        // 위치 서비스(마스터 스위치)가 꺼져 있으면 모든 제공자가 비활성으로 보고된다.
        val providers = enabledProviders(lm)
        if (providers.isEmpty()) {
            result.success(null)
            return
        }
        val last = freshestLastKnown(lm, providers)
        if (last != null && ageMs(last) <= FRESH_MS) {
            result.success(toMap(last))
            return
        }
        val waiter = FixWaiter(OnceReply(result, main))
        val timeout = Runnable { onWaiterTimeout(waiter) }
        waiter.timeout = timeout
        waiters.add(waiter)
        main.postDelayed(timeout, timeoutMs)
        // 이미 진행 중인 요청이 있으면 거기에 합류한다 — 여러 만남이 한꺼번에
        // 기록돼도 무선은 한 번만 깨운다.
        if (fixToken == null) startFix(lm, providers)
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun startFix(lm: LocationManager, providers: List<String>) {
        // NETWORK 우선: 실내에서도 수 초 안에 잡히고 GPS를 켜지 않는다 — 만남의
        // "어디서"는 동네 수준이면 충분하다. 없으면 GPS, 그것도 없으면 남은 것(fused).
        val provider = when {
            LocationManager.NETWORK_PROVIDER in providers -> LocationManager.NETWORK_PROVIDER
            LocationManager.GPS_PROVIDER in providers -> LocationManager.GPS_PROVIDER
            else -> providers.first()
        }
        val token = Any()
        fixToken = token
        // 이 요청의 결과는 한 번만 받아들인다: 타임아웃으로 취소된 뒤 늦게 온
        // 콜백, 다음 요청으로 대체된 뒤의 콜백은 토큰이 달라 버려진다.
        val deliver: (Location?) -> Unit = { loc ->
            if (fixToken === token) {
                fixToken = null
                cancelFix = null
                onFix(loc)
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val signal = CancellationSignal()
                cancelFix = { signal.cancel() }
                // null = 제공자가 위치를 내지 못했다(자체 타임아웃 포함) — onFix가
                // 차선책(10분 이내 last-known)으로 정리한다.
                lm.getCurrentLocation(provider, signal, context.mainExecutor) { loc ->
                    deliver(loc)
                }
            } else {
                // API < 30엔 getCurrentLocation이 없다. requestSingleUpdate는 스스로
                // 끝나지 않으므로(실내 GPS는 영영 못 잡을 수 있다) 대기자가 모두
                // 빠지면 cancelInFlightFix가 반드시 removeUpdates로 끊는다.
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) = deliver(location)

                    // API < 30 프레임워크의 LocationListener에는 디폴트 구현이 없다 —
                    // 아래 셋을 빼먹으면 그 기기에서 AbstractMethodError로 죽는다.
                    @Suppress("OVERRIDE_DEPRECATION")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                    override fun onProviderEnabled(provider: String) {}

                    override fun onProviderDisabled(provider: String) {
                        // 기다리던 제공자가 꺼졌다: 등록을 풀고 차선책으로 정리한다.
                        try { lm.removeUpdates(this) } catch (_: Exception) {}
                        deliver(null)
                    }
                }
                cancelFix = { lm.removeUpdates(listener) }
                lm.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        } catch (_: Exception) {
            // SecurityException(예: API < 31에서 대략적 위치 권한만으로 GPS 요청),
            // IllegalArgumentException(그 사이 사라진 제공자) 등 — 대기자를
            // 차선책으로 정리한다.
            deliver(null)
        }
    }

    /** 진행 중이던 fix의 결과로 대기자 전원을 해결한다. */
    private fun onFix(loc: Location?) {
        resolveWaiters(if (loc != null) toMap(loc) else staleFallback())
    }

    private fun resolveWaiters(payload: Map<String, Any?>?) {
        val all = ArrayList(waiters)
        waiters.clear()
        for (w in all) {
            w.timeout?.let { main.removeCallbacks(it) }
            w.reply.send(payload)
        }
    }

    private fun onWaiterTimeout(waiter: FixWaiter) {
        if (!waiters.remove(waiter)) return
        waiter.reply.send(staleFallback())
        // 아무도 기다리지 않는 요청은 끊어 무선을 놓아 준다. 다른 대기자가 남아
        // 있으면(더 긴 타임아웃으로 합류한 호출) 요청은 그대로 둔다.
        if (waiters.isEmpty()) cancelInFlightFix()
    }

    private fun cancelInFlightFix() {
        val cancel = cancelFix
        fixToken = null
        cancelFix = null
        try { cancel?.invoke() } catch (_: Exception) {}
    }

    /** 타임아웃·실패 시의 차선책 — 지금 시점에 다시 조회한다(그 사이 다른 앱이
     *  받아 둔 fix가 있을 수 있다). 10분 넘은 위치는 null. */
    private fun staleFallback(): Map<String, Any?>? {
        val lm = locationManager() ?: return null
        if (!hasLocationPermission()) return null
        val last = freshestLastKnown(lm, enabledProviders(lm)) ?: return null
        return if (ageMs(last) <= STALE_FALLBACK_MS) toMap(last) else null
    }

    private fun locationManager(): LocationManager? =
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    // ContextCompat(androidx.core)은 이 플러그인의 의존성이 아니다 — minSdk 24라
    // 프레임워크 checkSelfPermission(API 23+)으로 충분하다.
    private fun hasLocationPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun enabledProviders(lm: LocationManager): List<String> {
        val candidates = mutableListOf(
            LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            candidates.add(LocationManager.FUSED_PROVIDER)
        }
        return candidates.filter { p ->
            try { lm.isProviderEnabled(p) } catch (_: Exception) { false }
        }
    }

    @Suppress("MissingPermission")
    private fun freshestLastKnown(lm: LocationManager, providers: List<String>): Location? {
        var best: Location? = null
        for (p in providers) {
            // API < 31에서 대략적 위치 권한만 있으면 GPS 조회는 SecurityException이다.
            val loc = try { lm.getLastKnownLocation(p) } catch (_: Exception) { null }
                ?: continue
            if (best == null || loc.elapsedRealtimeNanos > best.elapsedRealtimeNanos) {
                best = loc
            }
        }
        return best
    }

    /** 단조 시계 기준 나이(ms) — 벽시계 변경(수동 시간 설정, 망 시간 동기화)에
     *  흔들리지 않는다. 타임스탬프가 비었거나 이번 부팅 이전 것이면 나이를 알 수
     *  없으니 가장 오래된 것으로 친다. */
    private fun ageMs(loc: Location): Long {
        val nanos = SystemClock.elapsedRealtimeNanos() - loc.elapsedRealtimeNanos
        return if (loc.elapsedRealtimeNanos <= 0L || nanos < 0L) {
            Long.MAX_VALUE
        } else {
            nanos / 1_000_000L
        }
    }

    private fun toMap(loc: Location): Map<String, Any?> = hashMapOf(
        "lat" to loc.latitude,
        "lng" to loc.longitude,
        // 정확도를 모르면 null — Dart가 "모름"과 "0m"를 구분하게.
        "accuracy" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
    )

    // ---- reverseGeocode ----

    private fun reverseGeocode(lat: Double, lng: Double, result: MethodChannel.Result) {
        // 범위 밖·NaN 좌표는 Geocoder가 IllegalArgumentException을 던진다 — 미리
        // 거른다. isPresent()=false는 지오코딩 백엔드가 없는 기기(GMS 없는 ROM 등).
        if (lat !in -90.0..90.0 || lng !in -180.0..180.0 || !Geocoder.isPresent()) {
            result.success(null)
            return
        }
        val reply = OnceReply(result, main)
        // 오프라인이면 지오코더가 네트워크 타임아웃까지 한참 매달릴 수 있다 —
        // 만남 기록이 지명 하나 때문에 늦어지지 않게 10초에서 끊는다.
        val timeout = Runnable { reply.send(null) }
        main.postDelayed(timeout, GEOCODE_TIMEOUT_MS)
        // 어느 스레드에서 불려도 안전하다(Handler와 OnceReply 모두 스레드 안전).
        val finish: (List<Address>?) -> Unit = { addresses ->
            main.removeCallbacks(timeout)
            reply.send(addresses?.firstOrNull()?.let { placeLabel(it) })
        }
        // 기기 로캘로 받는다 — 한국어 기기면 지명이 한국어로 나온다.
        val geocoder = Geocoder(context, Locale.getDefault())
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // 리스너는 임의의 스레드에서 불린다 — OnceReply가 메인으로 옮긴다.
                geocoder.getFromLocation(lat, lng, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) = finish(addresses)

                    override fun onError(errorMessage: String?) = finish(null)
                })
            } else {
                // API < 33엔 블로킹 API뿐이다 — 메인 스레드를 막지 않게 전용 스레드에서.
                geocodeExecutor.execute { finish(blockingGeocode(geocoder, lat, lng)) }
            }
        } catch (_: Exception) {
            finish(null)
        }
    }

    /** API < 33 전용 블로킹 조회. IOException = 오프라인/백엔드 무응답 → null. */
    @Suppress("DEPRECATION")
    private fun blockingGeocode(geocoder: Geocoder, lat: Double, lng: Double): List<Address>? =
        try { geocoder.getFromLocation(lat, lng, 1) } catch (_: Exception) { null }

    /**
     * 결과를 정확히 한 번만, 항상 메인 스레드에서 회신한다. 타임아웃과 실제
     * 완료가 경합해도(지오코더 콜백은 임의의 스레드에서 온다) 두 번째 회신은
     * 버린다 — Flutter는 같은 Result에 두 번 회신하면 IllegalStateException
     * ("Reply already submitted")을 던진다.
     */
    private class OnceReply(
        private val result: MethodChannel.Result,
        private val main: Handler,
    ) {
        private val sent = AtomicBoolean(false)

        fun send(value: Any?) {
            if (!sent.compareAndSet(false, true)) return
            if (Looper.myLooper() == Looper.getMainLooper()) {
                result.success(value)
            } else {
                main.post { result.success(value) }
            }
        }
    }

    /** 진행 중인 fix 하나를 기다리는 currentLocation 호출 하나. */
    private class FixWaiter(val reply: OnceReply) {
        var timeout: Runnable? = null
    }
}
