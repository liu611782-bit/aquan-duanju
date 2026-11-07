package com.aquan.duanju.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.aquan.duanju.MainActivity
import io.flutter.plugin.common.MethodChannel

/**
 * DLNA 接收端前台服务（R1.2）：开关开启期间常驻，承载三类职责——
 *
 * - **保活**：mediaPlayback 前台服务 + 通知（「正在等待投屏 / 正在接收：<标题>」，
 *   点击回 App）。接收端 HTTP/SSDP/播放栈在 Dart 侧（castd 纯 Dart 实现），
 *   本服务只负责保活与系统事件；
 * - **MulticastLock**：SSDP 收包前提（不持锁多数机型的 Wi-Fi 驱动会过滤
 *   239.255.255.250 组播），onCreate 申请、onDestroy 释放（非引用计数，
 *   锁生命周期 = 服务生命周期）；
 * - **音频焦点**（R1.3）：首个会话到达（setSessionMeta）申请 AUDIOFOCUS_GAIN；
 *   被抢占（来电/其他播放器）→ 向 Dart 回推 `receiverPause` 事件（引擎 pause、
 *   上报 PAUSED_PLAYBACK），恢复后不自动续播。
 *
 * ## 通道协议（与 lib/core/castd/receiver_android_bridge.dart 对齐）
 *
 * - aquan/cast（Dart→Kotlin，MainActivity 分发）：receiverStart{port} /
 *   receiverStop / setSessionMeta{title}；
 * - aquan/castd（Kotlin→Dart 事件）：receiverPause。与镜像事件共用 aquan/cast
 *   会互相顶掉 Dart 侧 handler（MirrorController 构造即独占注册），因此事件
 *   单独开通道。
 *
 * 通知权限（Android 13+ POST_NOTIFICATIONS）由 MainActivity 在 receiverStart
 * 时顺手请求：拒绝仍可投，仅无通知（服务照跑，notify 静默无效）。
 */
class ReceiverService : Service() {

    companion object {
        private const val TAG = "ReceiverService"
        private const val CHANNEL_ID = "aquan_receiver"
        private const val NOTIFICATION_ID = 2002
        private const val MULTICAST_LOCK_TAG = "aquan-castd"

        /** Kotlin→Dart 接收端事件通道（aquan/castd；MainActivity 注入）。 */
        @Volatile
        var dartChannel: MethodChannel? = null

        @Volatile
        private var instance: ReceiverService? = null

        /** 起前台服务（Android 8.0+ 走 startForegroundService）。 */
        fun start(context: Context, port: Int?) {
            val intent = Intent(context, ReceiverService::class.java)
                .putExtra("port", port ?: 0)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "start receiver foreground service failed", e)
            }
        }

        /** 停服务（onDestroy 释放组播锁与音频焦点）。 */
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ReceiverService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "stop receiver service failed", e)
            }
        }

        /** Dart 侧会话标题推送：更新通知；首个会话同时申请音频焦点。 */
        fun setSessionMeta(title: String?) {
            instance?.updateSessionMeta(title)
        }
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var focusHeld = false

    private var sessionTitle: String? = null
    private var port = 0

    /** 音频焦点被抢占（LOSS/LOSS_TRANSIENT）→ 回推 receiverPause；CAN_DUCK 不打断。 */
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS ||
            change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
        ) {
            notifyDart("receiverPause", null)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        acquireMulticastLock()
        audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        try {
            startAsForeground()
        } catch (e: Exception) {
            // 前台服务受限 / 通知渠道异常：服务照跑（无通知），不炸进程。
            Log.e(TAG, "startForeground failed", e)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        port = intent?.getIntExtra("port", 0) ?: 0
        // 重复 receiverStart（服务已存活）也按当前会话态刷新通知。
        updateNotification()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        abandonAudioFocus()
        releaseMulticastLock()
        instance = null
        super.onDestroy()
    }

    /** Dart 推送会话标题：null/空 = 回「等待投屏」；首个会话申请音频焦点。 */
    fun updateSessionMeta(title: String?) {
        sessionTitle = title
        requestAudioFocusIfReceiving()
        updateNotification()
    }

    // --- 通知 ----------------------------------------------------------------

    private fun startAsForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "投屏接收", NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
        val notification = buildNotification("正在等待投屏", "其他设备可把视频投到本机播放")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ 必须带类型（manifest 已声明 foregroundServiceType）。
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification() {
        val title = sessionTitle
        val notification = when {
            title == null -> buildNotification("正在等待投屏", "其他设备可把视频投到本机播放")
            title.isBlank() -> buildNotification("正在接收", "点击返回应用")
            else -> buildNotification("正在接收：${title.trim()}", "点击返回应用")
        }
        try {
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            // 通知权限被拒 / 通知服务异常：仅无通知，服务照跑。
            Log.w(TAG, "update receiver notification failed", e)
        }
    }

    private fun buildNotification(contentTitle: String, contentText: String): Notification {
        // 点击回 App：优先系统启动 Intent（带正确的 task/launcher 语义）。
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val contentIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(contentTitle)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    // --- MulticastLock（SSDP 组播收包前提） ------------------------------------

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            // 无 Wi-Fi 硬件的盒子拿不到 WifiManager：as? 空安全，只跳过加锁。
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifi == null) {
                Log.w(TAG, "WifiManager unavailable, multicast lock skipped")
                return
            }
            multicastLock = wifi.createMulticastLock(MULTICAST_LOCK_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "multicast lock acquire failed", e)
            multicastLock = null
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "multicast lock release failed", e)
        }
        multicastLock = null
    }

    // --- 音频焦点（R1.3） ------------------------------------------------------

    /** 首个会话到达且未持焦点时申请 AUDIOFOCUS_GAIN（8.0+ 用 AudioFocusRequest）。 */
    private fun requestAudioFocusIfReceiving() {
        val title = sessionTitle
        if (title.isNullOrEmpty() || focusHeld) return
        val am = audioManager ?: return
        val granted = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build(),
                    )
                    .setOnAudioFocusChangeListener(focusListener)
                    .build()
                focusRequest = request
                am.requestAudioFocus(request)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio focus request failed", e)
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        focusHeld = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        val am = audioManager
        if (am != null) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    focusRequest?.let { am.abandonAudioFocusRequest(it) }
                } else {
                    @Suppress("DEPRECATION")
                    am.abandonAudioFocus(focusListener)
                }
            } catch (e: Exception) {
                Log.w(TAG, "audio focus abandon failed", e)
            }
        }
        focusRequest = null
        focusHeld = false
    }

    // --- Kotlin→Dart 事件 -------------------------------------------------------

    private fun notifyDart(method: String, args: Map<String, Any?>?) {
        try {
            dartChannel?.invokeMethod(method, args)
        } catch (e: Exception) {
            // Dart 侧未监听 / 引擎未挂：日志兜底，绝不因事件失败影响服务。
            Log.w(TAG, "notifyDart($method) failed", e)
        }
    }
}
