package cn.wait.orbit

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /** 小而美批次④ 分享接收：其他 App「分享到」文本。冷启动（onNewIntent 之前
     *  intent 即携带 EXTRA_TEXT）与热运行（onNewIntent）两路都经
     *  MethodChannel("orbit/share") 回吐给 Dart 侧建任务。 */
    private var pendingText: String? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        pendingText = readSharedText(intent)
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
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 热运行分享：存待取文本；Dart 侧 lifecycle resume 时轮询 take
        pendingText = readSharedText(intent)
    }

    private fun readSharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type != "text/plain") return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
    }
}
