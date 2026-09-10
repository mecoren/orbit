package cn.wait.orbit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 小组件勾选广播（不进 app 勾任务的核心链路）：
 * RemoteViews 模板 PendingIntent 广播到此 → 取出 fill-in 的 taskId/done →
 * 经 [TodoWidgetHost.enqueueToggle] 转发 Flutter 互操作回调
 * （widgetTodoToggle 落库 → Dart 重写数据面 → updateWidget 重渲染）。
 *
 * 广播时代理可能未跑（app 被杀），enqueueToggle 内部会拉起前台服务
 * 引擎等待回调注册——数据面回写失败也不炸（勾选静默丢失可接受：与
 * 通知 action 的后台边界同口径，打开 app 后自然收敛）。
 */
class TodoWidgetToggleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val itemId = intent.getIntExtra(TodoWidgetProvider.EXTRA_ITEM_ID, -1)
        val done = intent.getIntExtra(TodoWidgetProvider.EXTRA_ITEM_DONE, -1)
        if (itemId <= 0 || done < 0) return
        TodoWidgetHost.enqueueToggle(context, itemId, done)
    }
}
