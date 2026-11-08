package com.aquan.duanju

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import com.aquan.duanju.mirror.MirrorService
import com.aquan.duanju.receiver.ReceiverService
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// 继承 AudioServiceActivity（它本身继承 FlutterActivity）才能让 audio_service 的
// 前台服务拿到 Activity 上下文；同时保住下面 aquan/cast 的自定义通道。
class MainActivity : AudioServiceActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    /// 通知权限申请只能有一个在飞：保存挂起的 result，系统回调时再回填。
    private var pendingNotificationResult: MethodChannel.Result? = null

    /// 屏幕镜像授权：系统投屏确认框的挂起结果。
    private var pendingMirrorResult: MethodChannel.Result? = null

    private companion object {
        const val TAG = "MainActivity"
        const val REQ_POST_NOTIFICATIONS = 4001
        const val REQ_MIRROR_PERMISSION = 4002
        const val CRASH_LOG_MAX_BYTES = 256 * 1024
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installCrashLogger()
        // DLNA 投屏设备发现：不持 MulticastLock 时多数机型收不到 SSDP 组播响应。
        // 所有 aquan/cast 方法统一 runCatching + 结构化返回：任何原生异常都不会
        // 冒出通道（R4），原始堆栈只写 logcat，不回传 Dart 作用户可见文案。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/cast")
            .setMethodCallHandler { call, result ->
                runCatching {
                    when (call.method) {
                        "acquireMulticastLock" -> {
                            val ok = runCatching {
                                if (multicastLock == null) {
                                    // 无 Wi-Fi 硬件的盒子拿不到 WifiManager：
                                    // as? 空安全，不再因强转 null 抛未捕获异常。
                                    val wifi = applicationContext
                                        .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                                        ?: return@runCatching false
                                    multicastLock = wifi.createMulticastLock("aquan-cast").apply {
                                        setReferenceCounted(false)
                                        acquire()
                                    }
                                }
                                true
                            }.getOrElse { e ->
                                Log.w(TAG, "multicast lock unavailable", e)
                                false
                            }
                            result.success(ok)
                        }
                        "releaseMulticastLock" -> {
                            runCatching { multicastLock?.release() }
                                .onFailure { Log.w(TAG, "release multicast lock", it) }
                            multicastLock = null
                            result.success(true)
                        }
                        "requestMirrorPermission" -> {
                            // 系统投屏确认框：onActivityResult 回填 {granted, ...}。
                            if (pendingMirrorResult != null) {
                                result.success(mapOf("granted" to false, "reason" to "busy"))
                            } else {
                                pendingMirrorResult = result
                                val launched = runCatching {
                                    val pm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                                        as? MediaProjectionManager
                                        ?: error("MediaProjectionManager unavailable")
                                    startActivityForResult(
                                        pm.createScreenCaptureIntent(),
                                        REQ_MIRROR_PERMISSION,
                                    )
                                    true
                                }.getOrElse { e ->
                                    Log.w(TAG, "mirror permission launch failed", e)
                                    false
                                }
                                if (!launched) {
                                    pendingMirrorResult = null
                                    result.success(
                                        mapOf("granted" to false, "reason" to "unavailable")
                                    )
                                }
                            }
                        }
                        "startMirror" -> {
                            val started = runCatching {
                                if (MirrorService.isRunning()) {
                                    false
                                } else {
                                    MirrorService.dartChannel = MethodChannel(
                                        flutterEngine.dartExecutor.binaryMessenger, "aquan/cast"
                                    )
                                    // 授权 Intent 已由 onActivityResult 存进 MirrorService
                                    // 进程内，不再经 startForegroundService 的 extra 二次传递
                                    // （Android 14 起 token 只能消费一次）。
                                    MirrorService.start(
                                        applicationContext,
                                        call.argument<Boolean>("withAudio") ?: true,
                                    )
                                    true
                                }
                            }.getOrElse { e ->
                                Log.w(TAG, "start mirror failed", e)
                                false
                            }
                            // Dart 侧 invokeMethod<bool> 只 await、不读值：结构化返回。
                            result.success(started)
                        }
                        "stopMirror" -> {
                            runCatching { MirrorService.stop(applicationContext) }
                                .onFailure { Log.w(TAG, "stop mirror failed", it) }
                            result.success(true)
                        }
                        "receiverStart" -> {
                            // 接收端开关（R1.1/R1.2）：前台服务 + MulticastLock。
                            // Android 13+ 通知权限顺手请求（拒绝仍可投，仅无通知）。
                            requestReceiverNotificationPermission()
                            val port = runCatching {
                                // receiverPause 事件走独立 aquan/castd 通道：
                                // aquan/cast 的 Dart 侧 handler 被 MirrorController
                                // 独占，共用会互相顶掉（见 receiver_android_bridge.dart）。
                                if (ReceiverService.dartChannel == null) {
                                    ReceiverService.dartChannel = MethodChannel(
                                        flutterEngine.dartExecutor.binaryMessenger,
                                        "aquan/castd",
                                    )
                                }
                                ReceiverService.start(applicationContext, call.argument<Int>("port"))
                                call.argument<Int>("port")
                            }.getOrElse { e ->
                                Log.w(TAG, "start receiver failed", e)
                                null
                            }
                            result.success(port)
                        }
                        "receiverStop" -> {
                            runCatching { ReceiverService.stop(applicationContext) }
                                .onFailure { Log.w(TAG, "stop receiver failed", it) }
                            result.success(true)
                        }
                        "setSessionMeta" -> {
                            // 通知栏「正在接收：<标题>」+ 首个会话申请音频焦点。
                            runCatching { ReceiverService.setSessionMeta(call.argument<String>("title")) }
                                .onFailure { Log.w(TAG, "set session meta failed", it) }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }.onFailure { e ->
                    // 兜底：即便分支有遗漏也不把异常抛回 Flutter 线程；
                    // 回复可能已提交，这里再包一层避免二次回复异常外泄。
                    Log.e(TAG, "aquan/cast ${call.method} crashed", e)
                    runCatching {
                        if (call.method == "requestMirrorPermission") {
                            result.success(mapOf("granted" to false, "reason" to "internal-error"))
                        } else {
                            result.success(null)
                        }
                    }
                }
            }

        // TV 判定：电视盒子 / Android TV 与手机共用同一个包，启动时读系统特性。
        // 只读、不产生副作用；任何异常都回空 map，Dart 侧会按「有触摸屏」处理。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/tv")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> {
                        try {
                            val pm = packageManager
                            result.success(mapOf(
                                "leanback" to pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK),
                                "television" to pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION),
                                "touchscreen" to pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
                            ))
                        } catch (e: Exception) {
                            result.success(emptyMap<String, Boolean>())
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Android 13+ 的通知权限：听书的后台通知/锁屏控制的前提。
        // 不引入 permission_handler：只有这一个权限，一个通道就够。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasNotificationPermission())
                    "requestPermission" -> {
                        if (hasNotificationPermission()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        // 上一次还没回：先把旧结果落成 false，避免 Dart 侧永远 await。
                        pendingNotificationResult?.success(false)
                        pendingNotificationResult = result
                        try {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS,
                            )
                        } catch (e: Exception) {
                            pendingNotificationResult = null
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 应用内更新：把下载好的 APK 交给系统安装器。
        // Dart 侧只负责下载 + SHA-256 校验，安装确认交给系统（不能静默安装）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "安装包路径为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("NOT_FOUND", "安装包不存在", null)
                                return@setMethodCallHandler
                            }
                            // API 24+ 不允许 file:// 跨应用暴露：必须走 FileProvider。
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive",
                                )
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 11-08 真机修复：默认未捕获异常处理器装饰器——任何线程的未捕获
    /// Throwable 先落 `<filesDir>/native_crash.log`（256KB 滚动）+ logcat，
    /// 再交还原 handler（**崩溃行为不变**，只增可观测）：真机闪退后可经
    /// 「导出运行日志」或 adb 拿到原生堆栈，不再黑盒排查。
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous == null) return
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching { writeNativeCrashLog(thread, throwable) }
                .onFailure { Log.e(TAG, "write native crash log failed", it) }
            previous.uncaughtException(thread, throwable)
        }
    }

    private fun writeNativeCrashLog(thread: Thread, throwable: Throwable) {
        val dir = filesDir ?: return
        val file = File(dir, "native_crash.log")
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val text = "$stamp thread=${thread.name}\n${throwable.stackTraceToString()}\n\n"
        if (file.length() > CRASH_LOG_MAX_BYTES) {
            // 只留最近一次：滚动即重写，日志永不超限。
            file.writeText(text)
        } else {
            file.appendText(text)
        }
        Log.e(TAG, "uncaught exception on ${thread.name}", throwable)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_MIRROR_PERMISSION) return
        val result = pendingMirrorResult
        pendingMirrorResult = null
        val granted = runCatching {
            if (data != null && resultCode == android.app.Activity.RESULT_OK) {
                // token 只在服务进程内保存一次，由 MirrorService 启动时一次性消费；
                // 绝不塞进 startForegroundService 的 extra（Android 14 起禁止二次传递）。
                MirrorService.saveProjection(resultCode, data)
                true
            } else {
                false
            }
        }.getOrElse { e ->
            Log.e(TAG, "save projection failed", e)
            false
        }
        // 回复本身也可能抛（result 已失效）：包住，绝不向系统回调外抛异常。
        runCatching {
            if (granted) {
                result?.success(mapOf("granted" to true))
            } else {
                result?.success(mapOf("granted" to false, "reason" to "denied"))
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_POST_NOTIFICATIONS) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }

    /// Android 13 (API 33) 起才需要动态申请；更早版本安装时即授予。
    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    /// 接收端开启时的通知权限请求（复用 REQ_POST_NOTIFICATIONS 先例与挂起
    /// 结果机制）：已有申请在飞时不重复弹；拒绝只影响通知显示，前台服务照跑。
    /// 这里不挂起 receiverStart 的回复——权限与起服务互不阻塞。
    private fun requestReceiverNotificationPermission() {
        if (hasNotificationPermission()) return
        if (pendingNotificationResult != null) return
        try {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
        } catch (e: Exception) {
            Log.w(TAG, "receiver notification permission request failed", e)
        }
    }
}
