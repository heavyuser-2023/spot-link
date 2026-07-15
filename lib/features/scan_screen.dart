import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../app/mesh_controller.dart';
import '../core/ble/mesh_transport.dart' show bleLogSink;
import '../core/model/qr_payload.dart';

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
      final parsed = raw == null ? null : QrPayload.decode(raw);
      bleLogSink?.call('QR detect: rawLen=${raw?.length} '
          'parsed=${parsed != null}');
      if (parsed == null) continue;
      _handled = true;
      final (bundle, name) = parsed;
      final controller = context.read<MeshFrontend>();
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
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        // Force white over the camera: the app-bar theme's titleTextStyle uses
        // onSurface (dark), which is unreadable against the live preview.
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
        title: const Text('QR 코드 스캔'),
        actions: [
          // Torch toggle — scanning a printed/on-screen code in a dim room is a
          // real case; a flashlight belongs right here.
          IconButton(
            tooltip: '플래시',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Dim scrim with a clear cut-out around the aiming frame, so the eye
          // is guided straight to where the code should go.
          const _ScannerScrim(size: 248),
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Text(
                  '친구의 SpotLink QR 코드를 사각형 안에 맞춰주세요',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A translucent scrim over the camera with a rounded transparent window in
/// the centre, plus four bright corner accents that read as an aiming frame.
class _ScannerScrim extends StatelessWidget {
  final double size;
  const _ScannerScrim({required this.size});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final rect = Rect.fromCenter(
          center: Offset(box.maxWidth / 2, box.maxHeight / 2),
          width: size,
          height: size,
        );
        return IgnorePointer(
          child: CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _ScrimPainter(rect: rect, radius: 24),
          ),
        );
      },
    );
  }
}

class _ScrimPainter extends CustomPainter {
  final Rect rect;
  final double radius;
  _ScrimPainter({required this.rect, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    // Dim everything except the aiming window (even-odd punches the hole).
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: 0.5));

    // Bright rounded corner accents.
    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const c = 28.0; // corner arm length
    void corner(Offset o, Offset h, Offset v) {
      canvas.drawLine(o, o + h, stroke);
      canvas.drawLine(o, o + v, stroke);
    }

    // Insets so the arms sit just inside the rounded window.
    final l = rect.left + radius * 0.4, r = rect.right - radius * 0.4;
    final t = rect.top + radius * 0.4, b = rect.bottom - radius * 0.4;
    corner(Offset(l, t), const Offset(c, 0), const Offset(0, c)); // TL
    corner(Offset(r, t), const Offset(-c, 0), const Offset(0, c)); // TR
    corner(Offset(l, b), const Offset(c, 0), const Offset(0, -c)); // BL
    corner(Offset(r, b), const Offset(-c, 0), const Offset(0, -c)); // BR
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.rect != rect || old.radius != radius;
}
