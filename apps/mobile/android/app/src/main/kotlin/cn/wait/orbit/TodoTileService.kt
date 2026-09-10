package cn.wait.orbit

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * 快捷设置磁贴（#3）：
 * - 副标题实时刷「今日截止或逾期 N」计数（onStartListening 时经
 *   TodoWidgetHost 数据面读 header.count——widget 与磁贴共用同一快照）。
 * - 点击：启动 MainActivity 落在待办页（快捷查看路径；复杂操作进 app）。
 * - [requestPin]：API 33+ 系统添加磁贴对话框（设置页「添加磁贴」按钮触发）。
 */
class TodoTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val count = HomeWidgetTileReader.readCount(this)
        tile.subtitle = if (count > 0) "$count" else "无待办"
        tile.state = Tile.STATE_ACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        startActivityAndCollapse(
            android.content.Intent(this, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    companion object {
        /** API 34+ 请求系统添加磁贴（反射防低版本 NoClassDefFound；
         *  低版本由设置页引导手动添加） */
        @JvmStatic
        fun requestPin(context: android.content.Context) {
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                try {
                    TileService::class.java
                        .getMethod(
                            "requestTileAdded",
                            android.content.Context::class.java,
                            android.content.ComponentName::class.java,
                        )
                        .invoke(null, context, android.content.ComponentName(context, TodoTileService::class.java))
                } catch (_: Exception) {
                    /* 厂商 ROM 未实现 / API 不可用：静默（引导文案兜底） */
                }
            }
        }
    }
}

/** 磁贴计数读取（隔离 HomeWidgetPlugin 依赖，方便 ROM 差异兜底） */
private object HomeWidgetTileReader {
    fun readCount(context: android.content.Context): Int {
        return try {
            es.antonborri.home_widget.HomeWidgetPlugin.getData(context)
                .getInt(TodoWidgetProvider.KEY_COUNT, 0)
        } catch (_: Exception) {
            0
        }
    }
}
