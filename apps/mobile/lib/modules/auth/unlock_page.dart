import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/providers/biometric_provider.dart';
import '../../data/providers/bridge_provider.dart';

/// 主密码解锁页（原 React 版 unlock-page.tsx 同构）
///
/// 输入主密码 → masterAuthUnlock 解出 db_key_hex → [onUnlocked] 回调上层
/// （BootGate 据此 dbInitEncrypted 进入主界面）；密码错误展示桥层错误消息。
///
/// 生物识别（已启用且指纹可用时展示指纹按钮）：指纹认证 → Rust 解密
/// 三件套得 db_key_hex → 同一 [onUnlocked] 汇合（DB 初始化单一路径）；
/// 密钥链损坏（[biometric_failed]）展示错误并引导密码路径。
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

  /// 指纹可用且已启用（null = 检查中，按钮不展示）
  bool? _bioEnabled;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 指纹入口探测：未启用或硬件不可用则不展示按钮（明文库/未开启场景
  /// 界面与原先完全一致）
  Future<void> _checkBiometric() async {
    final service = ref.read(biometricServiceProvider);
    final available = await service.isAvailable();
    if (!mounted) return;
    if (!available) {
      setState(() => _bioEnabled = false);
      return;
    }
    final enabled = await service.isEnabled();
    if (mounted) setState(() => _bioEnabled = enabled);
  }

  /// 错误消息转用户文案（保留 [tag] 前缀供排查）
  static String errMsg(Object e) {
    var msg = e.toString();
    // Exception: [wrong_password] xxx → 去掉 "Exception:" 与 tag 括号
    msg = msg.replaceFirst(RegExp(r'^Exception:\s*'), '');
    msg = msg.replaceAll(RegExp(r'^\[[^\]]*\]\s*'), '');
    return msg;
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

  /// 指纹解锁：闸门 + 密钥链解密一次走完；用户取消静默返回
  Future<void> _biometricSubmit() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dbKeyHex = await ref.read(biometricServiceProvider).unlock();
      if (!mounted) return;
      if (dbKeyHex == null) {
        setState(() => _error = null);
        return;
      }
      widget.onUnlocked(dbKeyHex);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errMsg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final showBio = _bioEnabled == true;
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
                if (showBio) ...[
                  const SizedBox(height: AppDimens.space16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : _biometricSubmit,
                      icon: _loading
                          ? SizedBox(
                              width: AppDimens.iconSizeSm,
                              height: AppDimens.iconSizeSm,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colors.secondaryText),
                            )
                          : const Icon(Icons.fingerprint_rounded,
                              size: AppDimens.iconSizeSm + 2),
                      label: const Text('指纹解锁'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
