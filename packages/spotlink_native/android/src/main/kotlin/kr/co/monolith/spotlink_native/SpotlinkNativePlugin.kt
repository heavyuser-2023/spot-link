package kr.co.monolith.spotlink_native

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Composite entry point: a Flutter plugin declares exactly one pluginClass,
 * so this fans the engine lifecycle out to SpotLink's native pieces. Being a
 * plugin (rather than MainActivity manual registration) is what gets these
 * into EVERY engine — including the mesh-owning foreground-service engine,
 * which has no Activity and never runs configureFlutterEngine.
 */
class SpotlinkNativePlugin : FlutterPlugin {
    private val fastLane = FastLanePlugin()
    private val beacon = BeaconPlugin()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        fastLane.onAttachedToEngine(binding)
        beacon.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        fastLane.onDetachedFromEngine(binding)
        beacon.onDetachedFromEngine(binding)
    }
}
