import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/providers/bridge_provider.dart';

/// 主密码解锁页（原 React 版 unlock-page.tsx 同构）
///
/// 输入主密码 → masterAuthUnlock 解出 db_key_hex → [onUnlocked] 回调上层
/// （BootGate 据此 dbInitEncrypted 进入主界面）；密码错误展示桥层错误消息。
class UnlockPage extends ConsumerStatefulWidget {
  const UnlockPage({super.key, required this.onUnlocked});

  /// 解锁成功回调，携带 db_key_hex
  final ValueChanged<String> onUnlocked;

  @override
  ConsumerState<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends ConsumerState<UnlockPage> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _controller.text;
    if (password.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dbKeyHex =
          await ref.read(orbitBridgeProvider).masterAuthUnlock(password);
      if (!mounted) return;
      widget.onUnlocked(dbKeyHex);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 错误消息转用户文案（保留 [tag] 前缀供排查）
  static String errMsg(Object e) {
    var msg = e.toString();
    // Exception: [wrong_password] xxx → 去掉 "Exception:" 与 tag 括号
    msg = msg.replaceFirst(RegExp(r'^Exception:\s*'), '');
    msg = msg.replaceAll(RegExp(r'^\[[^\]]*\]\s*'), '');
    return msg;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppDimens.space32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '循迹',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: colors.titleText,
                  ),
                ),
                const SizedBox(height: AppDimens.space8),
                Text(
                  '请输入主密码解锁',
                  style: TextStyle(fontSize: 14, color: colors.secondaryText),
                ),
                const SizedBox(height: AppDimens.space24),
                TextField(
                  controller: _controller,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: '主密码',
                    errorText: _error,
                  ),
                ),
                const SizedBox(height: AppDimens.space16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (_loading || _controller.text.isEmpty)
                        ? null
                        : _submit,
                    child: Text(_loading ? '解锁中…' : '解锁'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
