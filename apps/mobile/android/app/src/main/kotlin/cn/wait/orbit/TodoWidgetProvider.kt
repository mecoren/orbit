package cn.wait.orbit

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * 待办小组件（#3 存在感链条）：
 * - 数据面：home_widget SharedPreferences（Dart TodoWidgetService 写入
 *   items.N.id/title/priority/done + header.count）；经 [HomeWidgetPlugin.getData]
 *   读取（不硬编码文件名，随包版本演进安全）。
 * - 勾选（不进 app）：PendingIntentTemplate 广播 → [TodoWidgetToggleReceiver]
 *   请求 Flutter 互操作回调（widgetTodoToggle 落库），落库后 Dart 端重写数据面
 *   并 updateWidget 触发重渲染。勾选视觉 = 两份行布局（checked/unchecked）
 *   按 done 选一（RemoteViews 无 setChecked 可调用 action）。
 * - 点击行标题：FillInIntent 带 taskId → MainActivity 任务详情。
 */
class TodoWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: android.content.SharedPreferences,
    ) {
        appWidgetIds.forEach { id -> render(context, appWidgetManager, id, widgetData) }
    }

    companion object {
        /** 数据面键（与 Dart TodoWidgetService 一致） */
        const val KEY_COUNT = "widget.header.count"
        const val KEY_ID_PREFIX = "widget.items."
        const val EXTRA_ITEM_ID = "widget.item.id"
        const val EXTRA_ITEM_DONE = "widget.item.done"

        /** 优先级六档色（与 app PRIORITY_COLOR 同序：0 无 P0 灰 … 5 立即处理红） */
        val PRIORITY_COLORS = intArrayOf(
            Color.parseColor("#D1D5DB"),
            Color.parseColor("#60A5FA"),
            Color.parseColor("#34D399"),
            Color.parseColor("#FBBF24"),
            Color.parseColor("#F87171"),
            Color.parseColor("#DC2626"),
        )

        /** 渲染单个 widget 实例（数据面 → RemoteViews 组装） */
        fun render(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            prefs: android.content.SharedPreferences,
        ) {
            val count = prefs.getInt(KEY_COUNT, 0)
            val views = RemoteViews(context.packageName, R.layout.todo_widget)

            // 空态切换：无任务时隐藏列表展示完成文案
            views.setTextViewText(
                R.id.widget_header,
                context.getString(R.string.widget_header_title) + " · " + count,
            )
            views.setViewVisibility(
                R.id.widget_list,
                if (count > 0) android.view.View.VISIBLE else android.view.View.GONE,
            )
            views.setViewVisibility(
                R.id.widget_empty,
                if (count > 0) android.view.View.GONE else android.view.View.VISIBLE,
            )

            if (count > 0) {
                val factory = Intent(context, TodoWidgetViewsService::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                views.setRemoteAdapter(R.id.widget_list, factory)

                // 勾选模板 PendingIntent：整列表共用，行 fill-in 补 taskId/done
                val toggle = Intent(context, TodoWidgetToggleReceiver::class.java)
                views.setPendingIntentTemplate(
                    R.id.widget_list,
                    PendingIntent.getBroadcast(
                        context,
                        appWidgetId,
                        toggle,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                    ),
                )
            }

            // 点击标题打开 app
            views.setOnClickPendingIntent(
                R.id.widget_header,
                PendingIntent.getActivity(
                    context,
                    0,
                    Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        }

        /** 全部实例刷新（Dart updateWidget 之外的原生侧主动路径；幂等） */
        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, TodoWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val prefs = HomeWidgetPlugin.getData(context)
                ids.forEach { render(context, mgr, it, prefs) }
            }
        }
    }
}

/**
 * 小组件列表数据工厂：数据面 N 行展开成 RemoteViews 行视图。
 * 勾选视觉 = checked/unchecked 两份布局选一（RemoteViews 不能跨进程
 * 调 CheckBox.setChecked）；勾选与标题共用模板广播（fill-in 补参数）。
 */
class TodoWidgetViewsService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsService.RemoteViewsFactory =
        TodoWidgetViewsFactory(applicationContext, intent)

    class TodoWidgetViewsFactory(
        private val ctx: Context,
        intent: Intent,
    ) : RemoteViewsService.RemoteViewsFactory {
        private val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
        private var ids = IntArray(0)

        override fun onCreate() { /* 数据在 onDataSetChanged 拉取 */ }

        override fun onDataSetChanged() {
            val prefs = HomeWidgetPlugin.getData(ctx)
            val count = prefs.getInt(TodoWidgetProvider.KEY_COUNT, 0)
            val list = IntArray(count)
            for (i in 0 until count) {
                list[i] = prefs.getInt("${TodoWidgetProvider.KEY_ID_PREFIX}$i.id", -1)
            }
            ids = list
        }

        override fun onDestroy() { ids = IntArray(0) }

        override fun getCount() = ids.size

        override fun getViewAt(position: Int): RemoteViews {
            val prefs = HomeWidgetPlugin.getData(ctx)
            val key = "${TodoWidgetProvider.KEY_ID_PREFIX}$position"
            val itemId = ids.getOrElse(position) { -1 }
            val title = prefs.getString("$key.title", "") ?: ""
            val priority = prefs.getInt("$key.priority", 0).coerceIn(0, 5)
            val done = prefs.getInt("$key.done", 0)

            val row = RemoteViews(
                ctx.packageName,
                if (done == 1) R.layout.todo_widget_item_checked else R.layout.todo_widget_item,
            )
            row.setTextViewText(R.id.item_title, title)
            row.setInt(
                R.id.item_priority_bar,
                "setColorFilter",
                TodoWidgetProvider.PRIORITY_COLORS[priority],
            )

            // 勾选：目标态取反（fill-in 合并进模板广播）
            val toggleIntent = Intent()
                .putExtra(TodoWidgetProvider.EXTRA_ITEM_ID, itemId)
                .putExtra(TodoWidgetProvider.EXTRA_ITEM_DONE, if (done == 1) 0 else 1)
            row.setOnClickFillInIntent(R.id.item_check, toggleIntent)
            // 标题点击：打开 app 任务详情
            row.setOnClickFillInIntent(
                R.id.item_title,
                Intent().putExtra(TodoWidgetProvider.EXTRA_ITEM_ID, itemId),
            )
            return row
        }

        override fun getLoadingView() = null
        override fun getViewTypeCount() = 2 // checked / unchecked 两份布局
        override fun getItemId(position: Int) = ids.getOrElse(position) { position }.toLong()
        override fun hasStableIds() = true
    }
}
