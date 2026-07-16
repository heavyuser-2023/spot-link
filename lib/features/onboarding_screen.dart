import 'package:flutter/material.dart';

/// 첫 실행 화면: 다른 사람에게 어떤 이름으로 보일지 사용자에게 묻는다. 이것이
/// 없으면 모든 피어가 기본값 "SpotLink User"로 표시된다.
class OnboardingScreen extends StatefulWidget {
  final Future<void> Function(String name) onSubmit;
  const OnboardingScreen({super.key, required this.onSubmit});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    await widget.onSubmit(name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              // 브랜드를 각인시키는 순간: 마크가 홀로 떠 있지 않고 부드럽게
              // 물든 원판 위에 놓여, 첫 화면에 존재감을 준다.
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.hub, size: 40, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(height: 28),
              Text('SpotLink에\n오신 걸 환영합니다',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                '주변 친구들에게 표시될 이름을 정해주세요.\n'
                '인터넷 없이 블루투스로 안전하게 대화합니다.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                maxLength: 32,
                onSubmitted: (_) => _submit(),
                // 앱의 채워진(filled) 입력 스타일을 상속한다 — 혼자 테두리 형태로 튀지 않는다.
                decoration: const InputDecoration(
                  labelText: '표시 이름',
                  hintText: '예: 김정훈',
                  counterText: '', // 여기서 글자 수 카운터는 그저 잡음일 뿐
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('시작하기',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}
