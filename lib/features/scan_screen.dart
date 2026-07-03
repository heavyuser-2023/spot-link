import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show bleLogSink;

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      final parsed = raw == null ? null : MeshController.parseQr(raw);
      bleLogSink?.call('QR detect: rawLen=${raw?.length} '
          'parsed=${parsed != null}');
      if (parsed == null) continue;
      _handled = true;
      final (bundle, name) = parsed;
      final controller = context.read<MeshController>();
      try {
        final contact = await controller.addContactFromBundle(
          bundle,
          name: name.isEmpty ? null : name,
          verified: true,
        );
        bleLogSink?.call('QR add ok: ${contact.peerId.short}');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${contact.displayName}님을 추가했습니다 ✓')),
        );
        Navigator.of(context).pop();
      } catch (e, st) {
        bleLogSink?.call('QR add failed: $e\n$st');
        _handled = false;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('추가 실패: $e')),
        );
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR 코드 스캔')),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const Positioned(
            bottom: 40,
            child: Text(
              'SpotLink QR 코드를 비춰주세요',
              style: TextStyle(
                  color: Colors.white,
                  backgroundColor: Colors.black54,
                  fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}
