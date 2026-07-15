import 'package:flutter/material.dart';

/// First-run screen: ask the user what name others should see. Without this,
/// every peer appears as the default "SpotLink User".
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
              // A branded moment: the mark sits on a soft tinted disc rather
              // than floating alone, giving the first screen presence.
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
                // Inherits the app's filled input style — no outlined outlier.
                decoration: const InputDecoration(
                  labelText: '표시 이름',
                  hintText: '예: 김정훈',
                  counterText: '', // a char counter here is just noise
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
