package cn.wait.orbit

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新安装通道（Android 平台能力）。
 *
 * 为什么在壳层而不是 orbit-core：这一层只碰 Android 的「未知来源安装」权限、
 * FileProvider 与安装器 Intent——纯系统集成，没有可下沉的业务判断。版本检查
 * 与版本比较仍在 core（`update_api`），下载落盘在 Dart（`AppUpdateService`）。
 *
 * `installApk` 只负责把文件交给系统安装器：APK 必须是**同一 release keystore
 * 签名**（`docs/08` §3.6），否则系统会以 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
 * 拒绝覆盖安装，这里如实返回 false，由 UI 提示走发布页手动安装。
 */
object UpdateInstallChannel {
    const val CHANNEL = "orbit/update_install"

    fun handle(activity: Activity, method: String, arg: Any?, result: MethodChannel.Result) {
        when (method) {
            "canInstallPackages" -> result.success(canInstallPackages(activity))
            "openInstallPermissionSettings" -> {
                openInstallPermissionSettings(activity)
                result.success(null)
            }
            "installApk" -> {
                val filePath = (arg as? Map<*, *>)?.get("filePath") as? String
                if (filePath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "filePath 不能为空", null)
                } else {
                    result.success(installApk(activity, filePath))
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Android 8.0+ 的「安装未知应用」开关；低版本默认允许（安装时系统自处理） */
    private fun canInstallPackages(activity: Activity): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /** 跳本应用的「安装未知应用」授权页；个别 ROM 无此页时退回应用详情页 */
    private fun openInstallPermissionSettings(activity: Activity) {
        val packageUri = Uri.parse("package:${activity.packageName}")
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            activity.startActivity(intent)
        } catch (_: Exception) {
            /* ROM 无对应设置页：静默失败，由 Dart 侧提示手动开启 */
        }
    }

    /**
     * 用 FileProvider 暴露缓存目录里的 APK 并拉起系统安装器。
     *
     * 必须走 content://（Android 7.0+ 禁止 file:// 跨应用共享），路径白名单见
     * `res/xml/file_paths.xml`（`cacheDir/update/`）。
     */
    private fun installApk(activity: Activity, filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists() || !file.canRead()) return false
        return try {
            val uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
