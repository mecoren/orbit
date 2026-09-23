package cn.wait.orbit

import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 宿主 Activity。
 *
 * 继承 FlutterFragmentActivity（而非 FlutterActivity）：local_auth 的
 * Android 实现（BiometricPrompt）要求宿主为 FragmentActivity，否则
 * authenticate() 抛 "BiometricPrompt requires FragmentActivity" ——
 * 官方 README §Android integration 明确要求此改动。
 */
class MainActivity : FlutterFragmentActivity() {
    /** 本 Activity 持有的引擎引用（onDestroy 解注册 TodoWidgetHost 用） */
    private var boundEngine: FlutterEngine? = null

    /** 小而美批次④ 分享接收：其他 App「分享到」文本。冷启动（onNewIntent 之前
     *  intent 即携带 EXTRA_TEXT）与热运行（onNewIntent）两路都经
     *  MethodChannel("orbit/share") 回吐给 Dart 侧建任务。 */
    private var pendingText: String? = null

    /** 长按图标静态快捷方式（res/xml/shortcuts.xml）：只暂存动作 id
     *  （new_task / today / search），语义与路由落点在 Dart 侧
     *  （services/shortcut_receiver.dart）——原生不复制业务判断。 */
    private var pendingShortcut: String? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // 小组件勾选转发中枢挂引擎（#3）：configure 时 attach，
        // TodoWidgetHost 积压队列在此冲刷（app 被杀后用户勾选的补发路径）
        boundEngine = engine
        TodoWidgetHost.attachEngine(engine)
        // B6 角标原生通道（替换 discontinued flutter_app_badger；见 BadgeChannel）
        io.flutter.plugin.common.MethodChannel(
            engine.dartExecutor.binaryMessenger,
            BadgeChannel.CHANNEL,
        ).setMethodCallHandler { call, result ->
            BadgeChannel.handle(this, call.method, call.arguments, result)
        }
        pendingText = readSharedText(intent)
        // 冷启动快捷方式：launch intent 携带动作 id（热运行一路在 onNewIntent）
        pendingShortcut = readShortcutAction(intent)
        engine.dartExecutor.binaryMessenger
            .let { m ->
                io.flutter.plugin.common.MethodChannel(m, "orbit/share").setMethodCallHandler { call, result ->
                    if (call.method == "takeSharedText") {
                        result.success(pendingText)
                        pendingText = null
                    } else {
                        result.notImplemented()
                    }
                }
                // 快捷方式通道：与分享通道同款「取走即清」语义（Dart 侧
                // resumed / 冷启动首帧各轮询一次，重复取到 null 无害）
                io.flutter.plugin.common.MethodChannel(m, "orbit/shortcuts").setMethodCallHandler { call, result ->
                    if (call.method == "takePendingShortcut") {
                        result.success(pendingShortcut)
                        pendingShortcut = null
                    } else {
                        result.notImplemented()
                    }
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 热运行分享：存待取文本；Dart 侧 lifecycle resume 时轮询 take
        pendingText = readSharedText(intent)
        // 热运行快捷方式（launchMode=singleTop → 复用本实例走此路）
        pendingShortcut = readShortcutAction(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        // 引擎随 Activity 销毁：解引用防泄漏（勾选队列自然积压等下次 attach）
        boundEngine?.let { TodoWidgetHost.detachEngine(it) }
        boundEngine = null
    }

    private fun readSharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type != "text/plain") return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
    }

    /** 读静态快捷方式动作 id（shortcuts.xml 的 `<extra name="orbit_shortcut">`）；
     *  非本应用的私有 action 一律忽略，避免误吞外部 intent。 */
    private fun readShortcutAction(intent: Intent?): String? {
        if (intent?.action != "cn.wait.orbit.action.SHORTCUT") return null
        return intent.getStringExtra("orbit_shortcut")?.takeIf { it.isNotBlank() }
    }
}
