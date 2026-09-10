package cn.wait.orbit

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

/**
 * 厂商 ROM 角标原生实现（替代 discontinued 的 flutter_app_badger：
 * 该插件 compileSdk 29 与 AGP 9 + Java 17 工具链硬不兼容，无法构建）。
 *
 * 覆盖主流 ROM 广播协议（ShortcutBadger 同款机制的核心子集）：
 * - 小米 MIUI：extraapplication 的 APP_ICON_UPDATE 通知数
 * - 华为 EMUI：badge_number 额外字段
 * - OPPO/ColorOS、vivo、原生（Nova 等 launcher 自读 shortcut）走
 *  原生 Android 8+ notification channel 数（小工具不依赖）
 *
 * ROM 广播失败全静默（ShortcutBadger 的支持度矩阵本就碎片化；
 * 角标是锦上添花——BadgeService 全吞口径不变）。
 */
object BadgeChannel {
    const val CHANNEL = "orbit/badge"

    fun handle(context: Context, method: String, arg: Any?, result: MethodChannel.Result) {
        when (method) {
            "updateBadge" -> {
                val count = (arg as? Number)?.toInt() ?: 0
                updateBadge(context, count)
                result.success(null)
            }
            "removeBadge" -> {
                updateBadge(context, 0)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun updateBadge(context: Context, count: Int) {
        safeSend(context, "android.intent.action.BADGE_COUNT_UPDATE") {
            putExtra("badge_count", count.coerceAtLeast(0))
            putExtra("badge_count_package_name", context.packageName)
            putExtra("badge_count_class_name", MainActivity::class.java.name)
        }
        // MIUI：Application 类通知数（原 ShortcutBadger 小米路径）
        safeSend(context, "android.intent.action.APPLICATION_ICON_UPDATE") {
            putExtra("extraapplication", context.packageName)
            putExtra("extraBadgeNumber", count.coerceAtLeast(0))
        }
        // 华为 EMUI
        safeSend(context, "com.huawei.android.launcher.action.CHANGE_APPLICATION_ICON_NUM") {
            putExtra("package_name", context.packageName)
            putExtra("class_name", MainActivity::class.java.name)
            putExtra("badge_number", count.coerceAtLeast(0))
        }
    }

    /** ROM 专属广播在非目标 ROM 上会抛异常（receiver 未注册接收权限）；全吞 */
    private inline fun safeSend(
        context: Context,
        action: String,
        fill: android.content.Intent.() -> Unit,
    ) {
        try {
            context.sendBroadcast(Intent(action).apply(fill))
        } catch (_: Exception) {
            /* ROM 不支持：角标可选，不炸主流程 */
        }
    }
}
