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
        // 카메라 위에서는 흰색으로 강제한다: 앱 바 테마의 titleTextStyle은
        // onSurface(어두운 색)를 써서, 라이브 프리뷰 위에서는 읽을 수 없다.
        titleTextStyle: const TextStyle(
            color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
        title: const Text('QR 코드 스캔'),
        actions: [
          // 손전등 토글 — 어두운 방에서 인쇄된/화면 속 코드를 스캔하는 건
          // 실제로 있는 상황이다; 손전등은 바로 여기에 있어야 한다.
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
          // 조준 프레임 주위만 뚜렷하게 뚫어 놓은 어두운 스크림. 시선이 코드를
          // 두어야 할 곳으로 곧장 향하도록 유도한다.
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

/// 카메라 위에 덮이는 반투명 스크림. 가운데에 모서리가 둥근 투명한 창이 있고,
/// 조준 프레임처럼 읽히는 밝은 모서리 강조 네 개가 더해진다.
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
    // 조준 창을 뺀 나머지를 모두 어둡게 한다(even-odd 규칙으로 구멍을 뚫는다).
    final scrim = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rrect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(scrim, Paint()..color = Colors.black.withValues(alpha: 0.5));

    // 밝고 둥근 모서리 강조.
    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const c = 28.0; // 모서리 팔 길이
    void corner(Offset o, Offset h, Offset v) {
      canvas.drawLine(o, o + h, stroke);
      canvas.drawLine(o, o + v, stroke);
    }

    // 팔이 둥근 창의 딱 안쪽에 놓이도록 하는 인셋.
    final l = rect.left + radius * 0.4, r = rect.right - radius * 0.4;
    final t = rect.top + radius * 0.4, b = rect.bottom - radius * 0.4;
    corner(Offset(l, t), const Offset(c, 0), const Offset(0, c)); // 좌상단
    corner(Offset(r, t), const Offset(-c, 0), const Offset(0, c)); // 우상단
    corner(Offset(l, b), const Offset(c, 0), const Offset(0, -c)); // 좌하단
    corner(Offset(r, b), const Offset(-c, 0), const Offset(0, -c)); // 우하단
  }

  @override
  bool shouldRepaint(_ScrimPainter old) =>
      old.rect != rect || old.radius != radius;
}
