import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';

/// 关于页 /about（设置页关于卡入口）
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: BackButton(color: colors.titleText),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '循迹',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: colors.titleText,
                    ),
                  ),
                  const SizedBox(height: AppDimens.space8),
                  Text(
                    'Orbit · 本地优先的待办与知识库',
                    style: TextStyle(fontSize: 14, color: colors.secondaryText),
                  ),
                  const SizedBox(height: AppDimens.space4),
                  Text(
                    '版本 0.1.0',
                    style: TextStyle(fontSize: 12, color: colors.secondaryText),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimens.space24),
              child: Text(
                '数据经端到端同步加密，仅你持有密钥。',
                style: TextStyle(
                  fontSize: 12,
                  color: OrbitAccents.themeAccent.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
