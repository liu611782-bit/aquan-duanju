package com.aquan.duanju.mirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Surface
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 屏幕镜像前台服务（蓝本 DlnaCast capture/encoder/stream 全链 + scrcpy 系统音频采集）。
 *
 * MediaProjection → 采集通道 → MediaCodec(surface 输入, H264 Baseline CBR 1080p30 8Mbps,
 * I 帧间隔 1s) → [＋API 29+ 系统音频 AudioPlaybackCapture → AAC-LC 44.1k 128k] →
 * MirrorTsMuxer → 本机 HTTP `/stream.ts`（尾环缓冲，晚连电视先回放再实时）。
 * Dart 侧用既有 DLNA 发送端把该 URL SetAVTransportURI 给电视。
 *
 * 采集通道（R4.1，见 MirrorCaptureChannel）：默认 surface 直连（零拷贝，P1e 行为）；
 * MIUI 兼容备选 imageReader 通道只在多级恢复第 4 级互切后启用。
 * 多级恢复（R4.3 / design §5-3）：软恢复 → 降分辨率重建（保留会话）→ 热重启 → 通道互切。
 * MTK 兼容（R4.2）：MANUFACTURER 命中且特性开关开启时，输出 PTS 单调化 + 异常帧丢弃。
 */
class MirrorService : Service() {

    companion object {
        private const val TAG = "MirrorService"
        private const val CHANNEL_ID = "aquan_mirror_channel"
        private const val NOTIFICATION_ID = 2001
        private const val DEFAULT_PORT = 18380
        private const val PORT_ATTEMPTS = 20
        private const val VIDEO_MIME = "video/avc"
        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val TIMEOUT_US = 33_000L

        // 尾环缓冲上限（4MB ≈ 4s@8Mbps）：晚连的电视先回放再追实时。
        private const val TAIL_LIMIT_BYTES = 4 * 1024 * 1024

        // --- 分辨率档位（P1e 现状）：0=屏幕实际(≤1080p/8Mbps)，1=720p/4Mbps ---
        private const val RESOLUTION_TIER_MAX = 1

        // --- 多级恢复档位（R4.3 / design §5-3）：一次无输出 episode 内按同一时间轴逐级升级，
        // 每级只触发一次，任意一帧到达即复位到第 0 级：
        // 第 1 级 3s 软恢复（P1e 现状）→ 第 2 级 6s 降分辨率重建（保留采集通道会话）→
        // 第 3 级 9s 热重启（P1e 现状 6s 链路实现）→ 第 4 级 12s 采集通道互切（R4.1）→
        // 之后回到既有热重启节奏（连续 2 次无效自毁，P1e 链路不变）。
        private const val RECOVERY_NONE = 0
        private const val RECOVERY_SOFT_DONE = 1
        private const val RECOVERY_RES_REBUILT = 2
        private const val RECOVERY_HOT_RESTARTED = 3
        private const val RECOVERY_CHANNEL = 4
        private const val SOFT_RECOVER_MS = 3_000L
        private const val RES_REBUILD_MS = 6_000L
        private const val HOT_RESTART_MS = 9_000L
        private const val CHANNEL_SWITCH_MS = 12_000L
        private const val POST_LADDER_STEP_MS = 3_000L
        // 采集通道互切次数上限（R4.1：失败互切有上限，超过后走既有热重启/自毁链）
        private const val MAX_CHANNEL_SWITCHES = 4

        // --- MTK SurfaceBridge 规避（R4.2 / design §5-2）---
        // 总开关：真机出问题时置 false 一键回退，所有设备行为与 P1e 完全一致。
        private const val MTK_COMPAT_ENABLED = true
        // PTS 大幅回退（>500ms）视为时间轴损坏 → 整帧丢弃；
        // 轻微回退/重复 → 钳制为上一帧 + 步进（约 1/3 帧间隔，不显著拖慢时间轴）。
        private const val MTK_PTS_DROP_THRESHOLD_US = 500_000L
        private const val MTK_PTS_STEP_US = 11_000L

        @Volatile
        var projectionData: Intent? = null
            private set

        @Volatile
        var projectionResultCode: Int = 0
            private set

        @Volatile
        var dartChannel: MethodChannel? = null

        @Volatile
        private var instance: MirrorService? = null

        fun isRunning(): Boolean = instance != null

        fun saveProjection(resultCode: Int, data: Intent) {
            projectionResultCode = resultCode
            projectionData = data
        }

        /** 服务内一次性消费 token（resultCode, Intent）：取出即清空，绝不复制给第二个 Intent。 */
        @Synchronized
        fun consumeProjection(): Pair<Int, Intent>? {
            val data = projectionData ?: return null
            val code = projectionResultCode
            projectionData = null
            projectionResultCode = 0
            return Pair(code, data)
        }

        fun start(context: Context, withAudio: Boolean) {
            // 授权 Intent 只保存在服务进程内（saveProjection），不再经过
            // startForegroundService 的 extra 二次传递：Android 14 起 token
            // 只能消费一次，复制 Intent 会触发 SecurityException。
            val intent = Intent(context, MirrorService::class.java)
                .putExtra("with_audio", withAudio)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "start foreground service failed", e)
                emitStoppedStatic("start-failed")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, MirrorService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "stop service failed", e)
            }
        }

        /** 服务还没起来时的失败通知（无实例可用），Dart 侧对重复事件幂等。 */
        private fun emitStoppedStatic(reason: String) {
            try {
                dartChannel?.invokeMethod("mirrorStopped", mapOf("reason" to reason))
            } catch (e: Exception) {
                Log.w(TAG, "emit mirrorStopped failed", e)
            }
        }
    }

    private val running = AtomicBoolean(false)

    // mirrorStopped 只发一次：失败 / 正常结束 / 系统销毁共用去重闸门。
    private val stopEventSent = AtomicBoolean(false)

    private var projection: MediaProjection? = null

    // --- 采集通道（R4.1 / design §5-1）---
    // 默认 surface 直连 = P1e 行为不变；仅在多级恢复第 4 级互切后才启用 imageReader 备选。
    private var channel: MirrorCaptureChannel? = null
    private var useImageReaderChannel = false
    private var channelSwitches = 0
    private var captureDpi = 160
    private var videoCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var audioCodec: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var httpServer: ServerSocket? = null
    private var muxer = MirrorTsMuxer()
    private val sinks = CopyOnWriteArrayList<Socket>()
    private val tail = Collections.synchronizedList(ArrayDeque<ByteArray>())
    private var tailBytes = 0L
    private val workers = ArrayList<Thread>()
    private var serviceVideoWidth = 1920
    private var serviceVideoHeight = 1080

    // --- 编码器韧性（移植 DlnaCast VideoEncoder 恢复机制） ---
    // 分辨率层级：0=屏幕实际(≤1080p/8Mbps) → 1=720p/4Mbps。恢复档位逐级下降。
    private var resolutionTier = 0
    private var stallRecoveryAttempts = 0

    // 多级恢复档位（R4.3）：一次无输出 episode 内逐级升级，有输出复位。
    private var recoveryStage = RECOVERY_NONE

    // --- MTK 兼容（R4.2）：送 muxer 的上一帧 PTS 与异常帧丢弃计数 ---
    private var lastMuxedPtsUs = 0L
    private var mtkDropCount = 0

    /** R4.2 MTK 判定：总开关 + MANUFACTURER 含 mtk/mediatek（覆盖 MediaTek/Mtk 拼写变体）。 */
    private val mtkCompat = MTK_COMPAT_ENABLED && isMtkDevice()

    private fun isMtkDevice(): Boolean {
        val maker = Build.MANUFACTURER ?: return false
        val lower = maker.lowercase()
        return lower.contains("mtk") || lower.contains("mediatek")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // Android 14+（targetSdk 34+）要求：getMediaProjection() 必须在
        // startForeground(FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION) **之后**
        // 调用，否则 SecurityException（11-08 真机修复——原顺序在 14+ 全灭）。
        // 授权 token 只能消费一次：先起前台、再在服务内消费 token。
        try {
            startAsForeground()
        } catch (e: Exception) {
            // 前台服务受限 / 通知渠道异常：不重抛，走 mirrorStopped 优雅退出。
            Log.e(TAG, "startForeground failed", e)
            failAndStop("foreground-failed")
            return
        }
        try {
            createProjectionFromGrant()
        } catch (e: Exception) {
            Log.e(TAG, "projection unavailable", e)
            failAndStop("no-projection")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running.get()) return START_NOT_STICKY
        val withAudio = intent?.getBooleanExtra("with_audio", true) ?: true
        if (projection == null || stopEventSent.get()) {
            // onCreate 未拿到授权或已发过失败事件：只补一次事件后自毁。
            if (!stopEventSent.get()) emitStopped("no-projection")
            stopSelf()
            return START_NOT_STICKY
        }
        running.set(true)
        instance = this
        Thread({
            try {
                runMirror(withAudio)
            } catch (t: Throwable) {
                // 编码器 / VirtualDisplay / HTTP 服务初始化异常统一走事件，不杀进程。
                // 11-08 真机修复：catch Throwable——Error 级（OOM/LinkageError 等）
                // 也降级为 mirrorStopped 优雅停机，绝不让 worker 异常炸掉整个进程。
                Log.e(TAG, "mirror failed", t)
                emitStopped("error", "${t.message}")
            } finally {
                cleanup()
                emitStopped("stopped") // 失败路径已发过，去重后不会二次通知。
                stopSelf()
            }
        }, "aquan-mirror").start()
        return START_NOT_STICKY
    }

    /** 服务内一次性消费授权 token 并创建/持有 MediaProjection。 */
    private fun createProjectionFromGrant() {
        val grant = consumeProjection()
            ?: throw IllegalStateException("no projection grant")
        val pm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
            ?: throw IllegalStateException("MediaProjectionManager unavailable")
        val mp = pm.getMediaProjection(grant.first, grant.second)
            ?: throw IllegalStateException("getMediaProjection returned null")
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // 用户从系统面板停止投屏 → 全链自毁（Dart 侧状态回 idle）。
                running.set(false)
            }
        }, null)
    }

    /** mirrorStopped 只发一次；reason/message 是固定文案，不含 URL 或凭据。 */
    private fun emitStopped(reason: String, message: String? = null) {
        if (!stopEventSent.compareAndSet(false, true)) return
        val args = HashMap<String, Any?>()
        args["reason"] = reason
        if (message != null) args["message"] = message
        notifyDart("mirrorStopped", args)
    }

    private fun failAndStop(reason: String, message: String? = null) {
        emitStopped(reason, message)
        runCatching { stopSelf() }
    }

    private fun startAsForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "屏幕镜像", NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
        }
        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("屏幕镜像运行中")
                .setContentText("正在镜像到电视")
                .setSmallIcon(android.R.drawable.ic_menu_slideshow)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("屏幕镜像运行中")
                .setSmallIcon(android.R.drawable.ic_menu_slideshow)
                .setOngoing(true)
                .build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun runMirror(withAudio: Boolean) {
        // MediaProjection 已在 onCreate 内一次性消费 token 创建并持有；
        // 这里只负责编码器 / VirtualDisplay / HTTP / 音频链路。
        muxer = MirrorTsMuxer()
        val metrics = resources.displayMetrics
        serviceVideoWidth = metrics.widthPixels.coerceAtMost(1920)
        serviceVideoHeight = metrics.heightPixels.coerceAtMost(1080)
        if (serviceVideoWidth % 2 != 0) serviceVideoWidth -= 1
        if (serviceVideoHeight % 2 != 0) serviceVideoHeight -= 1

        // --- 视频编码器（surface 输入；层级 0） ---
        buildVideoEncoder(metrics.densityDpi)

        startHttpServer()

        // --- 音频（API 29+ 系统音频回放采集；失败降级纯视频） ---
        var audioStarted = false
        if (withAudio && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            audioStarted = try {
                startAudioCapture()
            } catch (e: Exception) {
                Log.w(TAG, "audio capture unavailable, video only", e)
                false
            }
        }
        notifyDart(
            "mirrorStarted",
            mapOf(
                "url" to mirrorUrl(),
                "audio" to audioStarted,
                "width" to serviceVideoWidth,
                "height" to serviceVideoHeight,
            ),
        )

        // --- 视频编码循环（主 worker；带多级恢复） ---
        videoLoop()
    }

    /** 当前层级的分辨率/码率：0=屏幕实际(≤1080p/8Mbps)，1=720p/4Mbps（降级档） */
    private fun tierSpec(): Triple<Int, Int, Int> {
        if (resolutionTier == 0) {
            return Triple(serviceVideoWidth, serviceVideoHeight, 8_000_000)
        }
        return Triple(1280, 720, 4_000_000)
    }

    /** 构建编码器 + 输入 Surface + 采集通道（初建/热重启共用） */
    private fun buildVideoEncoder(densityDpi: Int) {
        captureDpi = densityDpi
        buildVideoCodec()
        // 采集通道按当前模式重建（R4.1）：默认 surface 直连 = P1e 行为不变；
        // 只有互切过的会话才以 imageReader 通道重建（把画面回灌进新编码器 Surface）。
        channel?.stop()
        channel = createCaptureChannel()
        if (!startChannel(channel!!) && useImageReaderChannel) {
            // 备选通道建不起来（如 ImageReader 资源不足）：回退默认 surface 通道。
            // 普通设备永远走 surface 通道，不经过这个分支。
            Log.w(TAG, "capture channel ${channel?.name} start failed, fallback to surface channel")
            useImageReaderChannel = false
            channel = createCaptureChannel()
            startChannel(channel!!)
        }
        requestSyncFrame()
    }

    /** 构建编码器与输入 Surface（分辨率/码率按当前档位；不含采集通道） */
    private fun buildVideoCodec() {
        val (width, height, bitrate) = tierSpec()
        val format = MediaFormat.createVideoFormat(VIDEO_MIME, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(
                    MediaFormat.KEY_LEVEL,
                    if (width <= 1280) MediaCodecInfo.CodecProfileLevel.AVCLevel31
                    else MediaCodecInfo.CodecProfileLevel.AVCLevel4,
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LATENCY, 1)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
        }
        videoCodec = MediaCodec.createEncoderByType(VIDEO_MIME).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = createInputSurface()
            start()
        }
    }

    /** 按当前模式构建采集通道（R4.1：普通设备恒走 surface 直连） */
    private fun createCaptureChannel(): MirrorCaptureChannel {
        val (width, height, _) = tierSpec()
        return if (useImageReaderChannel) {
            ImageReaderCaptureChannel(projection, width, height, captureDpi)
        } else {
            SurfaceCaptureChannel(projection, width, height, captureDpi)
        }
    }

    private fun startChannel(ch: MirrorCaptureChannel): Boolean = try {
        ch.start(inputSurface ?: return false)
    } catch (e: Exception) {
        Log.e(TAG, "capture channel ${ch.name} start failed", e)
        false
    }

    /** 安全释放编码器与输入 Surface（不动采集通道；通道由调用方决定 stop 还是 reattach） */
    private fun releaseVideoCodec() {
        try { videoCodec?.stop() } catch (_: Exception) {}
        try { videoCodec?.release() } catch (_: Exception) {}
        videoCodec = null
        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null
    }

    /**
     * 视频编码循环 + 多级恢复（P1e 恢复链 + design §5-3 档位语义 + R4.1 通道互切）：
     * 一次无输出 episode 内按同一时间轴逐级升级，每级只触发一次，任意一帧到达即复位：
     * 第 1 级 3s  软恢复（同步帧 + 码率微扰，P1e 现状行为）；
     * 第 2 级 6s  降分辨率重建编码器（保留采集通道会话，不重走 MediaProjection 授权）；
     * 第 3 级 9s  热重启（P1e 现状 6s 链路的重建+重连实现；连续 2 次无效自毁）；
     * 第 4 级 12s 采集通道互切（surface ↔ imageReader，R4.1 MIUI 兼容，次数有上限）；
     * 第 4 级之后回到既有热重启节奏，直至自毁（现状链路）。
     * 每级原因写 Log.w（现有日志通道）；mirrorStopped 事件与 reason 保持不变。
     */
    private fun videoLoop() {
        val info = MediaCodec.BufferInfo()
        var spsPpsSent = false
        var lastFrameWall = System.currentTimeMillis()
        val frameTimestamps = ArrayDeque<Long>()
        while (running.get()) {
            val codec = videoCodec ?: throw IllegalStateException("video codec missing")
            val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val csd0 = codec.outputFormat.getByteBuffer("csd-0")
                    val csd1 = codec.outputFormat.getByteBuffer("csd-1")
                    if (csd0 != null && csd1 != null && !spsPpsSent) {
                        val sps = ByteArray(csd0.remaining()).also { csd0.get(it); csd0.rewind() }
                        val pps = ByteArray(csd1.remaining()).also { csd1.get(it); csd1.rewind() }
                        // SPS/PPS 前补起始码（编码器 CSD 常裸给）。
                        publish(muxer.writeVideo(addStartCode(sps), true, 0))
                        publish(muxer.writeVideo(addStartCode(pps), true, 0))
                        spsPpsSent = true
                    }
                }
                index >= 0 -> {
                    lastFrameWall = System.currentTimeMillis()
                    stallRecoveryAttempts = 0
                    recoveryStage = RECOVERY_NONE // 有输出 → 档位复位（互切启用的通道保持运行）
                    // 滑动窗口帧率监测（3s 窗口）。
                    frameTimestamps.addLast(lastFrameWall)
                    while (frameTimestamps.isNotEmpty() &&
                        lastFrameWall - frameTimestamps.first() > 3_000
                    ) {
                        frameTimestamps.removeFirst()
                    }
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null && info.size > 0) {
                        val data2 = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(data2, 0, info.size)
                        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ||
                            (data2.size > 4 && (data2[4].toInt() and 0x1F) == 5)
                        // MTK 兼容（R4.2）：PTS 单调化 + 异常帧丢弃；返回 -1 表示整帧丢弃。
                        val ptsUs = if (mtkCompat) mtkGuardPts(data2, info.presentationTimeUs)
                        else info.presentationTimeUs
                        if (ptsUs >= 0) {
                            publish(muxer.writeVideo(addStartCode(data2), isKey, ptsUs))
                        }
                    }
                    codec.releaseOutputBuffer(index, false)
                }
                else -> {
                    val nowMs = System.currentTimeMillis()
                    val elapsed = nowMs - lastFrameWall
                    when {
                        // 第 4 级之后：回到既有热重启节奏（连续 2 次无效 → 自毁，P1e 链路）。
                        recoveryStage >= RECOVERY_CHANNEL && elapsed >= POST_LADDER_STEP_MS -> {
                            stallRecoveryAttempts++
                            Log.w(TAG, "encoder stalled ${elapsed}ms after full ladder, " +
                                "hot restart #$stallRecoveryAttempts")
                            if (stallRecoveryAttempts >= 2) {
                                throw IllegalStateException("video encoder unrecoverable after hot restarts")
                            }
                            hotRestartEncoder()
                            spsPpsSent = false
                            frameTimestamps.clear()
                            lastFrameWall = System.currentTimeMillis()
                        }
                        // 第 4 级：采集通道互切（R4.1 MIUI 兼容）。不重建编码器、不断流：
                        // SPS/PPS 与 TS 序列保持连续。互切超过上限后降级为热重启节奏。
                        elapsed >= CHANNEL_SWITCH_MS && recoveryStage == RECOVERY_HOT_RESTARTED -> {
                            if (channelSwitches < MAX_CHANNEL_SWITCHES) {
                                switchCaptureChannel()
                            } else {
                                Log.w(TAG, "channel switch cap reached ($channelSwitches), " +
                                    "degrade to hot restart cadence")
                            }
                            recoveryStage = RECOVERY_CHANNEL
                            // 互切后重置节奏基准：新通道需要首帧/首输出的启动时间，
                            // 不重置会让「第 4 级之后的热重启」立即触发。
                            lastFrameWall = nowMs
                        }
                        // 第 3 级：热重启（P1e 现状 6s 链路的重建+重连实现）。
                        elapsed >= HOT_RESTART_MS && recoveryStage == RECOVERY_RES_REBUILT -> {
                            stallRecoveryAttempts++
                            Log.w(TAG, "encoder stalled ${elapsed}ms, " +
                                "hot restart #$stallRecoveryAttempts (recovery level 3)")
                            if (stallRecoveryAttempts >= 2) {
                                throw IllegalStateException("video encoder unrecoverable after hot restarts")
                            }
                            hotRestartEncoder()
                            recoveryStage = RECOVERY_HOT_RESTARTED
                            spsPpsSent = false
                            frameTimestamps.clear()
                            lastFrameWall = System.currentTimeMillis()
                        }
                        // 第 2 级：降分辨率重建编码器（保留采集通道会话，不重走授权）。
                        elapsed >= RES_REBUILD_MS && recoveryStage == RECOVERY_SOFT_DONE -> {
                            if (rebuildEncoderKeepDisplay()) {
                                recoveryStage = RECOVERY_RES_REBUILT
                                Thread.sleep(300) // 新编码器缓冲预热（对齐 P1e 热重启节奏）
                            } else {
                                Log.w(TAG, "recovery level 2 failed, escalate to level 3 hot restart")
                                stallRecoveryAttempts++
                                if (stallRecoveryAttempts >= 2) {
                                    throw IllegalStateException("video encoder unrecoverable after hot restarts")
                                }
                                hotRestartEncoder()
                                recoveryStage = RECOVERY_HOT_RESTARTED
                            }
                            spsPpsSent = false
                            frameTimestamps.clear()
                            lastFrameWall = System.currentTimeMillis()
                        }
                        // 第 1 级：3s 无输出 → 软恢复（现状行为：同步帧 + 码率微扰）。
                        elapsed >= SOFT_RECOVER_MS && recoveryStage == RECOVERY_NONE -> {
                            Log.w(TAG, "encoder quiet ${elapsed}ms, soft recovery (recovery level 1)")
                            attemptSoftRecovery(codec)
                            recoveryStage = RECOVERY_SOFT_DONE
                        }
                        // 级别 0：帧率异常低 → 主动软恢复（P1e 现状行为保留；
                        // stallRecoveryAttempts=1 沿用 P1e 语义：低帧率事件后下一次热重启不再宽限）。
                        frameTimestamps.size >= 3 &&
                            frameTimestamps.size * 1000f / 3_000f < 3f -> {
                            Log.w(TAG, "low fps ${frameTimestamps.size * 1000f / 3_000f}, proactive recovery")
                            attemptSoftRecovery(codec)
                            lastFrameWall = nowMs
                            stallRecoveryAttempts = 1
                        }
                    }
                }
            }
        }
    }

    /**
     * 第 2 级恢复：按下一档分辨率重建编码器，但保留采集通道会话——
     * surface 通道经 VirtualDisplay.setSurface 换绑（不释放 MediaProjection、
     * 不重走授权弹窗，这是与第 3 级热重启的本质区别）；imageReader 通道只切换回灌目标。
     * 返回 false 表示重建/换绑失败，调用方升级第 3 级热重启。
     */
    private fun rebuildEncoderKeepDisplay(): Boolean {
        if (resolutionTier < RESOLUTION_TIER_MAX) resolutionTier++
        val spec = tierSpec()
        Log.w(
            TAG, "recovery level 2: rebuild encoder at tier $resolutionTier " +
                "(${spec.first}x${spec.second}), keeping capture channel session",
        )
        releaseVideoCodec()
        // MTK 单调化基准随编码器重建复位：新编码器 PTS 从 0 重新起步，
        // 不复位的话旧基准会把所有新帧钳制成固定步进（A/V 漂移）。
        // 复位后的 PTS 跳变与非 MTK 路径热重启的现状行为一致。
        lastMuxedPtsUs = 0L
        return try {
            buildVideoCodec()
            val rebound = channel?.reattach(inputSurface ?: return false) ?: false
            if (rebound) requestSyncFrame()
            rebound
        } catch (e: Exception) {
            Log.e(TAG, "recovery level 2 rebuild failed", e)
            false
        }
    }

    /**
     * 第 3 级恢复：热重启（P1e 现状 6s 链路的实现）——释放编码器与采集通道后全量重建
     * （surface 通道重建 VirtualDisplay / imageReader 通道重建 ImageReader+VirtualDisplay）。
     * 与第 2 级的区别：不保留会话，采集通道整个重来。
     */
    private fun hotRestartEncoder() {
        releaseVideoCodec()
        lastMuxedPtsUs = 0L // MTK 单调化基准随编码器重建复位（同第 2 级，见彼处注释）
        channel?.stop()
        buildVideoEncoder(resources.displayMetrics.densityDpi)
        Thread.sleep(300)
    }

    /**
     * 第 4 级恢复：采集通道互切（R4.1 MIUI 兼容）。不重建编码器、不断流，
     * 只把 VirtualDisplay 的消费端换掉（surface ↔ imageReader）：
     * - surface → imageReader：默认直连链路无帧（DlnaCast 佐证的 MIUI Qinput=0 形态），
     *   重建 VirtualDisplay 到 ImageReader 上并起泵回灌编码器；
     * - imageReader → surface：泵有帧但编码器仍无输出（采集不是瓶颈）或泵也无帧，
     *   换回直连通道继续观察。
     * 互切次数有上限（MAX_CHANNEL_SWITCHES），超过后由调用方降级走既有热重启/自毁链。
     */
    private fun switchCaptureChannel(): Boolean {
        val surface = inputSurface ?: return false
        val oldName = channel?.name ?: "none"
        val oldFrames = channel?.frameCount ?: -1L
        channel?.stop()
        channel = null
        useImageReaderChannel = !useImageReaderChannel
        channelSwitches++
        val fresh = createCaptureChannel()
        val ok = try {
            fresh.start(surface)
        } catch (e: Exception) {
            Log.e(TAG, "capture channel switch failed", e)
            false
        }
        if (ok) {
            channel = fresh
            Log.w(
                TAG, "recovery level 4: capture channel switched " +
                    "$oldName(frames=$oldFrames) -> ${fresh.name} (#$channelSwitches)",
            )
        } else {
            // 互切失败：模式标记回滚，之后的热重启按原模式重建通道。
            useImageReaderChannel = !useImageReaderChannel
            Log.e(TAG, "recovery level 4: switch to ${fresh.name} failed, keep $oldName for next rebuild")
        }
        return ok
    }

    /**
     * MTK 编码器输出守卫（R4.2 / design §5-2，特性开关 mtkCompat 可一键关）：
     * 时间戳单调化 + 偶发异常帧丢弃。
     *
     * 为什么落在这里：MTK Surface 输入编码器在负载抖动/换档后偶发输出 PTS 回绕或
     * 重复的帧，PTS 倒退直接进 TS 会让接收端解码器卡死（DlnaCast MtkSurfaceBridge
     * 思路的本工程落法）。本链路编码输出走 releaseOutputBuffer(render=false)，
     * 时间戳只在 muxer 边界消费，因此单调化作用在送 muxer 的 PTS 上。
     *
     * 规则：PTS 正常前进 → 原样放行；轻微回退/重复（≤500ms）→ 钳制为上一帧+步进，
     * 保帧不断流；大幅回退（>500ms，时间轴已损坏无法补值）或 NAL 不足 5 字节
     * （装不下 NAL 头）→ 整帧丢弃并请求同步帧（偶发丢帧规避）。
     * 返回 -1 表示调用方丢弃该帧。
     */
    private fun mtkGuardPts(nal: ByteArray, rawPtsUs: Long): Long {
        if (nal.size < 5) {
            mtkDropCount++
            Log.w(TAG, "mtk: drop undersized frame (${nal.size}B) #$mtkDropCount")
            requestSyncFrame()
            return -1L
        }
        val last = lastMuxedPtsUs
        if (rawPtsUs > last) {
            lastMuxedPtsUs = rawPtsUs
            return rawPtsUs
        }
        if (last - rawPtsUs > MTK_PTS_DROP_THRESHOLD_US) {
            mtkDropCount++
            Log.w(TAG, "mtk: drop frame with regressed pts=$rawPtsUs (last=$last) #$mtkDropCount")
            requestSyncFrame()
            return -1L
        }
        val clamped = last + MTK_PTS_STEP_US
        lastMuxedPtsUs = clamped
        return clamped
    }

    /** 软恢复：同步帧请求 + 极小码率微扰（±100bps，MTK 速率控制器兼容） */
    private fun attemptSoftRecovery(codec: MediaCodec) {
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        } catch (_: Exception) {
        }
        val (_, _, bitrate) = tierSpec()
        try {
            val bump = android.os.Bundle()
            bump.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate + 100)
            codec.setParameters(bump)
            Thread.sleep(50)
            val restore = android.os.Bundle()
            restore.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
            codec.setParameters(restore)
        } catch (_: Exception) {
        }
    }

    /** 系统音频回放采集 → AAC（API 29+；scrcpy 路线，无需麦克风权限） */
    private fun startAudioCapture(): Boolean {
        val projection = projection ?: return false
        val config = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(44100)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(
            44100, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
        )
        audioRecord = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(minBuf, 8192))
            .setAudioPlaybackCaptureConfig(config)
            .build()
        val record = audioRecord ?: return false
        if (record.state != AudioRecord.STATE_INITIALIZED) return false

        val aacFormat = MediaFormat.createAudioFormat(AUDIO_MIME, 44100, 2).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        audioCodec = MediaCodec.createEncoderByType(AUDIO_MIME).apply {
            configure(aacFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        val codec = audioCodec!!
        record.startRecording()

        Thread({
            val info = MediaCodec.BufferInfo()
            val pcm = ByteArray(8192)
            var csdSent = false
            try {
                while (running.get()) {
                    val read = record.read(pcm, 0, pcm.size)
                    if (read > 0) {
                        val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (inIndex >= 0) {
                            val inBuf = codec.getInputBuffer(inIndex)
                            inBuf?.clear()
                            inBuf?.put(pcm, 0, read)
                            codec.queueInputBuffer(inIndex, 0, read, System.nanoTime() / 1000, 0)
                        }
                    }
                    val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val csd0 = codec.outputFormat.getByteBuffer("csd-0")
                            if (csd0 != null && !csdSent) {
                                val cfg = ByteArray(csd0.remaining()).also { csd0.get(it); csd0.rewind() }
                                publish(muxer.writeAudio(cfg, 0))
                                csdSent = true
                            }
                        }
                        outIndex >= 0 -> {
                            val buffer = codec.getOutputBuffer(outIndex)
                            if (buffer != null && info.size > 0) {
                                val aac = ByteArray(info.size)
                                buffer.position(info.offset)
                                buffer.get(aac, 0, info.size)
                                publish(muxer.writeAudio(aac, info.presentationTimeUs))
                            }
                            codec.releaseOutputBuffer(outIndex, false)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "audio loop ended", e)
            } finally {
                try { record.stop() } catch (_: Exception) {}
                try { record.release() } catch (_: Exception) {}
                try { codec.stop() } catch (_: Exception) {}
                try { codec.release() } catch (_: Exception) {}
            }
        }, "aquan-mirror-audio").also { workers.add(it) }.start()
        return true
    }

    // ---------------------------------------------------------------------------
    // HTTP 服务：/stream.ts（PAT/PMT + 尾缓冲回放 + 实时流）
    // ---------------------------------------------------------------------------

    private fun startHttpServer() {
        var bound: ServerSocket? = null
        for (i in 0 until PORT_ATTEMPTS) {
            try {
                bound = ServerSocket(DEFAULT_PORT + i)
                break
            } catch (_: Exception) {
                continue
            }
        }
        val server = bound ?: throw IllegalStateException("mirror http port exhausted")
        httpServer = server
        Thread({
            while (running.get() && !server.isClosed) {
                try {
                    val socket = server.accept()
                    socket.tcpNoDelay = true
                    Thread({ serveClient(socket) }, "aquan-mirror-client").start()
                } catch (e: Exception) {
                    if (running.get()) Log.w(TAG, "accept failed", e)
                }
            }
        }, "aquan-mirror-http").also { workers.add(it) }.start()
    }

    private fun serveClient(socket: Socket) {
        try {
            val input = socket.getInputStream()
            // 读掉请求头（到 \r\n\r\n）——只服务 GET /stream.ts。
            val head = ByteArrayOutputStream()
            while (true) {
                val c = input.read()
                if (c == -1) return
                head.write(c)
                val bytes = head.toByteArray()
                val n = bytes.size
                if (n >= 4 && bytes[n - 4] == 13.toByte() && bytes[n - 3] == 10.toByte() &&
                    bytes[n - 2] == 13.toByte() && bytes[n - 1] == 10.toByte()
                ) {
                    break
                }
            }
            val response = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: video/mp2t\r\n" +
                "Connection: close\r\n\r\n"
            socket.getOutputStream().write(response.toByteArray())
            // 新客户端：初始 PAT/PMT + 尾缓冲回放（电视能立即出画面），然后进实时。
            socket.getOutputStream().write(muxer.getInitialPackets())
            val replay = synchronized(tail) { tail.toList() }
            for (chunk in replay) {
                socket.getOutputStream().write(chunk)
            }
            sinks.add(socket)
            requestSyncFrame()
            // 保持到断连（实时数据由 publish 推送）。
            while (running.get() && !socket.isClosed) {
                Thread.sleep(200)
            }
        } catch (_: Exception) {
        } finally {
            sinks.remove(socket)
            try { socket.close() } catch (_: Exception) {}
        }
    }

    /** 发布 TS 字节：写入尾环缓冲 + 推给所有客户端 */
    private fun publish(tsBytes: ByteArray) {
        if (tsBytes.isEmpty()) return
        synchronized(tail) {
            tail.add(tsBytes)
            tailBytes += tsBytes.size
            while (tailBytes > TAIL_LIMIT_BYTES && tail.isNotEmpty()) {
                tailBytes -= tail.removeFirst().size
            }
        }
        for (socket in sinks) {
            try {
                socket.getOutputStream().write(tsBytes)
                socket.getOutputStream().flush()
            } catch (e: Exception) {
                sinks.remove(socket)
                try { socket.close() } catch (_: Exception) {}
                Log.w(TAG, "client write failed", e)
            }
        }
    }

    fun requestSyncFrame() {
        val codec = videoCodec ?: return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            codec.setParameters(params)
        } catch (_: Exception) {
        }
    }

    private fun addStartCode(nal: ByteArray): ByteArray {
        // 已带 4 字节起始码则原样；裸 NAL（3 字节码或无码）统一补 4 字节起始码。
        if (nal.size >= 4 && nal[0] == 0x00.toByte() && nal[1] == 0x00.toByte() &&
            nal[2] == 0x00.toByte() && nal[3] == 0x01.toByte()
        ) {
            return nal
        }
        if (nal.size >= 3 && nal[0] == 0x00.toByte() && nal[1] == 0x00.toByte() &&
            nal[2] == 0x01.toByte()
        ) {
            return byteArrayOf(0x00, 0x00, 0x00, 0x01) + nal.copyOfRange(3, nal.size)
        }
        return byteArrayOf(0x00, 0x00, 0x00, 0x01) + nal
    }

    private fun mirrorUrl(): String {
        val port = httpServer?.localPort ?: return ""
        return "http://${lanIp()}:$port/stream.ts"
    }

    private fun lanIp(): String {
        try {
            var fallback = ""
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                for (addr in ni.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        if (ip.startsWith("192.168.")) return ip
                        if (ip.startsWith("10.") && fallback.isEmpty()) fallback = ip
                        if (Regex("^172\\.(1[6-9]|2\\d|3[01])\\.").containsMatchIn(ip) && fallback.isEmpty()) {
                            fallback = ip
                        }
                    }
                }
            }
            return fallback
        } catch (_: Exception) {
            return ""
        }
    }

    private fun notifyDart(method: String, args: Map<String, Any?>) {
        try {
            dartChannel?.invokeMethod(method, args)
        } catch (e: Exception) {
            // 通道未挂 / 已销毁：日志兜底，绝不因通知失败杀服务。
            Log.w(TAG, "notifyDart($method) failed", e)
        }
    }

    private fun cleanup() {
        running.set(false)
        for (socket in sinks) {
            try { socket.close() } catch (_: Exception) {}
        }
        sinks.clear()
        try { httpServer?.close() } catch (_: Exception) {}
        httpServer = null
        // 采集通道统一释放（surface=VirtualDisplay / imageReader=VirtualDisplay+ImageReader+泵）
        try { channel?.stop() } catch (_: Exception) {}
        channel = null
        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null
        try { videoCodec?.stop() } catch (_: Exception) {}
        try { videoCodec?.release() } catch (_: Exception) {}
        videoCodec = null
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
        try { audioCodec?.stop() } catch (_: Exception) {}
        try { audioCodec?.release() } catch (_: Exception) {}
        audioCodec = null
        try { projection?.stop() } catch (_: Exception) {}
        projection = null
        tail.clear()
        tailBytes = 0
        instance = null
    }

    override fun onDestroy() {
        cleanup()
        // 系统异常销毁时兜底发一次；正常/失败路径已发过，去重后不重复。
        emitStopped("destroyed")
        super.onDestroy()
    }
}
