package cn.wait.orbit

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * 小组件原生 ⇄ Flutter 转发中枢（#3）：
 * - [enqueueToggle]：勾选广播入口。引擎存活（缓存引擎或前台 Activity）
 *   直发 MethodChannel；未存活时积压队列，引擎就绪（configureFlutterEngine /
 *   Dart 侧注册互操作回调）后冲刷。
 * - 磁贴点击：直接拉起 MainActivity（不进 app 的复杂操作不做）。
 *
 * 与 home_widget 的 registerInteractivityCallback 路径并存不冲突：
 * 我们不用它的 isolate 派发（SQLite 直连已由 FRB 全局状态保证），
 * 只复用其数据面与 widget 刷新。
 */
object TodoWidgetHost {
    private const val CHANNEL = "orbit/widget"
    private const val METHOD_TOGGLE = "widgetToggle"
    private const val METHOD_PIN_TILE = "requestPinTile"

    /** 待冲刷的勾选（引擎未就绪时积压；就绪后 FIFO 冲刷） */
    private val pendingToggles = ConcurrentLinkedQueue<Pair<Int, Int>>()

    /** 当前引擎引用（MainActivity configure 时赋值） */
    @Volatile
    private var engine: FlutterEngine? = null

    /** 引擎就绪（Activity configure 或 Dart 注册回调时调用） */
    fun attachEngine(flutterEngine: FlutterEngine) {
        engine = flutterEngine
        // 冲刷积压：引擎重启（app 被杀后重新打开）时补发丢失勾选
        while (true) {
            val item = pendingToggles.poll() ?: break
            send(item.first, item.second)
        }
    }

    fun detachEngine(flutterEngine: FlutterEngine) {
        if (engine === flutterEngine) engine = null
    }

    /** 勾选入队：引擎活则直发，否则积压（下次引擎就绪冲刷） */
    fun enqueueToggle(context: Context, taskId: Int, done: Int) {
        val e = engine
        if (e != null && e.dartExecutor.isExecutingDart) {
            send(taskId, done)
        } else {
            pendingToggles.add(taskId to done)
            // 引擎未跑：拉起 app 后台预热（不进前台界面的轻量路径不可靠，
            // 直接启动 Activity 最稳——用户勾选本身即"要操作本任务"意图）
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /** 请求系统添加磁贴（TileService.requestTileAddedApi）由 Dart 触发 */
    fun requestPinTile(context: Context) {
        // API 33+ 才有磁贴添加 API；反射防崩（minSdk 24）
        try {
            val service = Class.forName("cn.wait.orbit.TodoTileService")
            val method = service.getMethod("requestPin", Context::class.java)
            method.invoke(null, context)
        } catch (_: Exception) {
            /* 低版本无 API：静默（设置页引导文案已按 API 差异提示） */
        }
    }

    private fun send(taskId: Int, done: Int) {
        val e = engine ?: return
        Handler(Looper.getMainLooper()).post {
            MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod(METHOD_TOGGLE, mapOf("taskId" to taskId, "done" to done))
        }
    }
}
