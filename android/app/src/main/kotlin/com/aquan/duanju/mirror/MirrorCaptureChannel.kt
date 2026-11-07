package com.aquan.duanju.mirror

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.util.Log
import android.view.Display
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/**
 * 采集通道抽象（R4.1 MIUI 兼容 / design §5-1）。
 *
 * 两个实现：
 * - [SurfaceCaptureChannel]（默认）：VirtualDisplay 直连编码器输入 Surface，零拷贝，
 *   P1b/P1e 既有行为——普通设备永远走这条，行为不变（硬约束：默认路径不动）；
 * - [ImageReaderCaptureChannel]（备选）：VirtualDisplay → ImageReader → Canvas 回灌
 *   编码器输入 Surface，仅在默认通道确认无帧且 1~3 级恢复无效后由 MirrorService
 *   的多级恢复档位（videoLoop）互切启用，平时不启用。
 */
internal interface MirrorCaptureChannel {

    /** 通道名：进恢复档位日志的原因字段（design §5-3「档位间记录原因」） */
    val name: String

    /**
     * 已采集帧计数。surface 通道没有独立观测点（画面直写编码器，只能以编码器
     * 输出作帧证据），恒为 -1；imageReader 通道由泵线程真实计数。
     */
    val frameCount: Long

    /**
     * 启动通道，把镜像画面送进 [target]（编码器输入 Surface）。
     * 返回 false 表示通道建不起来，调用方回退默认通道 / 升级恢复档位。
     */
    fun start(target: Surface): Boolean

    /** 释放通道全部资源（VirtualDisplay / ImageReader / 泵线程），可重复调用 */
    fun stop()

    /**
     * 编码器重建后换绑到新输入 Surface（第 2 级恢复语义：保留 VirtualDisplay
     * 会话、不重走 MediaProjection 授权）。
     * - surface 通道：VirtualDisplay.setSurface 换绑，会话对象不释放；
     * - imageReader 通道：VirtualDisplay 仍指向 ImageReader（采集分辨率不变），
     *   只把回灌泵的目标换成新编码器 Surface，画面经缩放适配新编码尺寸。
     * 返回 false 表示换绑失败，调用方升级到第 3 级热重启。
     */
    fun reattach(target: Surface): Boolean
}

/**
 * 默认采集通道：VirtualDisplay 直连编码器输入 Surface（P1b 现状行为原样迁移）。
 *
 * flags 沿用现状 Display.FLAG_PRESENTATION：默认路径字节级不动（硬约束）。
 * MIUI 上该直连链路可能收不到帧（见 ImageReaderCaptureChannel 头注释），
 * 由互切机制兜底，这里不做任何厂商分叉。
 */
internal class SurfaceCaptureChannel(
    private val projection: MediaProjection?,
    private val width: Int,
    private val height: Int,
    private val dpi: Int,
) : MirrorCaptureChannel {

    override val name = "surface"
    override val frameCount: Long = -1L

    private var virtualDisplay: VirtualDisplay? = null

    override fun start(target: Surface): Boolean {
        virtualDisplay = try {
            projection?.createVirtualDisplay(
                "aquan-mirror", width, height, dpi,
                Display.FLAG_PRESENTATION, target, null, null,
            )
        } catch (e: Exception) {
            Log.e(TAG, "surface channel createVirtualDisplay failed", e)
            null
        }
        return virtualDisplay != null
    }

    override fun stop() {
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
    }

    override fun reattach(target: Surface): Boolean {
        val vd = virtualDisplay ?: return false
        return try {
            // setSurface 换绑不释放 VirtualDisplay 对象 → MediaProjection 会话保住，
            // 不重走授权（这正是第 2 级恢复与第 3 级热重启的本质区别）。
            vd.setSurface(target)
            true
        } catch (e: Exception) {
            Log.e(TAG, "VirtualDisplay.setSurface failed", e)
            false
        }
    }

    companion object {
        private const val TAG = "MirrorCapture"
    }
}

/**
 * 备选采集通道（R4.1 / design §5-1，MIUI 兼容，蓝本 DlnaCast ImageReaderCaptureManager）。
 *
 * 为什么存在：MIUI 上 VirtualDisplay 直连编码器 Surface 可能一帧都送不进去
 * （蓝本 DlnaCast ScreenCaptureManager.kt:112 注释佐证：编码器 Qinput=0），
 * 编码器本身健康，软恢复/重建编码器都救不回来。本通道把 VirtualDisplay 的
 * 消费端换成 ImageReader（flags 用蓝本口径 PUBLIC | AUTO_MIRROR、去掉
 * PRESENTATION），拿到帧后再经 Canvas 回灌编码器输入 Surface，绕开直连断点。
 *
 * 格式取舍：设计稿写 ImageReader(YUV_420_888)，但蓝本实测可用的是 RGBA_8888
 * （VirtualDisplay 的 GPU 合成输出就是 RGBA；YUV_420_888 消费端在多数设备上
 * 拿不到有效帧）。按蓝本口径实现，兼容目标一致。
 *
 * 代价：每帧多一次 CPU 拷贝 + Canvas 绘制（蓝本注释同款「性能较差但兼容性好」），
 * 只在备选通道上发生，不影响默认路径。
 */
internal class ImageReaderCaptureChannel(
    private val projection: MediaProjection?,
    private val width: Int,
    private val height: Int,
    private val dpi: Int,
) : MirrorCaptureChannel {

    override val name = "imageReader"
    override val frameCount: Long get() = frames.get()

    private val frames = AtomicLong(0)
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var pumpThread: Thread? = null

    // 泵线程 ↔ 编码器线程共享：回灌目标与停机位
    @Volatile private var pumpTarget: Surface? = null
    @Volatile private var stopped = false

    // 复用的位图与行对齐暂存（1080p 一张 ARGB_8888 ≈ 8MB，复用避免每帧分配）
    @Volatile private var frameBitmap: Bitmap? = null
    @Volatile private var packedRows: ByteBuffer? = null

    override fun start(target: Surface): Boolean {
        stop()
        stopped = false
        pumpTarget = target
        val reader = try {
            ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, IMAGE_QUEUE_DEPTH)
        } catch (e: Exception) {
            Log.e(TAG, "ImageReader.newInstance failed", e)
            return false
        }
        imageReader = reader
        // 蓝本 DlnaCast 口径：PUBLIC | AUTO_MIRROR，不带 PRESENTATION——
        // PRESENTATION 正是 MIUI 上镜像内容进不了消费端的嫌疑点。
        val flags = DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR
        virtualDisplay = try {
            projection?.createVirtualDisplay(
                "aquan-mirror-ir", width, height, dpi, flags, reader.surface, null, null,
            )
        } catch (e: Exception) {
            Log.e(TAG, "imageReader channel createVirtualDisplay failed", e)
            null
        }
        if (virtualDisplay == null) {
            try { reader.close() } catch (_: Exception) {}
            imageReader = null
            return false
        }
        pumpThread = Thread({ pumpLoop() }, "aquan-mirror-ir-pump").apply { start() }
        Log.i(TAG, "imageReader channel started: ${width}x${height}")
        return true
    }

    override fun stop() {
        stopped = true
        pumpThread = null // 泵循环看到 stopped/资源清空后自行退出；不 join，避免卡住编码器恢复节奏
        try { virtualDisplay?.release() } catch (_: Exception) {}
        virtualDisplay = null
        try { imageReader?.close() } catch (_: Exception) {}
        imageReader = null
        // 位图/暂存只清引用不 recycle：泵线程可能仍在 drawBitmap 中途，交给 GC 回收。
        frameBitmap = null
        packedRows = null
        pumpTarget = null
    }

    override fun reattach(target: Surface): Boolean {
        // VirtualDisplay 仍指向 ImageReader（采集分辨率维持旧档，画面缩放适配新编码尺寸），
        // 只切换回灌目标——会话与 ImageReader 都不动。
        pumpTarget = target
        return true
    }

    /** 泵循环：取最新帧 → Bitmap → Canvas 画进编码器输入 Surface */
    private fun pumpLoop() {
        var consecutiveFailures = 0
        while (!stopped) {
            val reader = imageReader ?: break
            val target = pumpTarget
            if (target == null || !target.isValid) {
                sleepQuiet()
                continue
            }
            val image = try {
                reader.acquireLatestImage()
            } catch (e: Exception) {
                if (!stopped) Log.w(TAG, "acquireLatestImage failed", e)
                sleepQuiet()
                continue
            }
            if (image == null) {
                // 无新帧：静态画面属正常，按节拍继续轮询。
                sleepQuiet()
                continue
            }
            var drawn = false
            try {
                val bitmap = ensureBitmap(image.width, image.height)
                if (bitmap != null) {
                    copyImageToBitmap(image, bitmap)
                    drawn = drawToEncoder(bitmap, target)
                }
            } catch (e: Exception) {
                if (!stopped) Log.w(TAG, "image pump frame failed", e)
            } finally {
                // Image 必须归还，否则 maxImages 用尽后 acquireLatestImage 永久失败。
                try { image.close() } catch (_: Exception) {}
            }
            if (drawn) {
                consecutiveFailures = 0
                frames.incrementAndGet()
            } else if (++consecutiveFailures >= PUMP_FAILURE_GIVE_UP) {
                // 通道整体失效（如该设备编码器 Surface 不支持 Canvas 渲染）：
                // 停泵等帧计数停涨，由 MirrorService 的互切/热重启链接管，不抛出。
                Log.w(TAG, "image pump giving up after $consecutiveFailures consecutive failures")
                break
            }
            sleepQuiet()
        }
    }

    private fun sleepQuiet() {
        try {
            Thread.sleep(PUMP_INTERVAL_MS)
        } catch (_: InterruptedException) {
        }
    }

    private fun ensureBitmap(w: Int, h: Int): Bitmap? {
        val existing = frameBitmap
        if (existing != null && existing.width == w && existing.height == h) return existing
        return try {
            Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { frameBitmap = it }
        } catch (e: Exception) {
            Log.e(TAG, "allocate capture bitmap failed", e)
            null
        }
    }

    /** Image(RGBA) → Bitmap：rowStride 与宽×4 对齐时整块拷贝，否则逐行剔除对齐冗余 */
    private fun copyImageToBitmap(image: Image, bitmap: Bitmap) {
        val plane = image.planes[0]
        val buf = plane.buffer
        val rowStride = plane.rowStride
        val rowBytes = image.width * 4
        if (rowStride == rowBytes) {
            buf.rewind()
            bitmap.copyPixelsFromBuffer(buf)
            return
        }
        // BufferQueue 常按对齐要求放大行跨度：逐行拷进紧凑暂存再喂 Bitmap。
        // 原始字节序直拷（RGBA → Bitmap ARGB_8888 内存布局同为 R,G,B,A），无通道交换。
        var packed = packedRows
        if (packed == null || packed.capacity() < rowBytes * image.height) {
            packed = ByteBuffer.allocate(rowBytes * image.height)
            packedRows = packed
        }
        packed.clear()
        for (row in 0 until image.height) {
            buf.position(row * rowStride)
            buf.limit(buf.position() + rowBytes)
            packed.put(buf)
        }
        packed.flip()
        bitmap.copyPixelsFromBuffer(packed)
    }

    /** Bitmap → 编码器输入 Surface（MediaCodec surface 输入支持 Canvas 渲染），缩放适配编码尺寸 */
    private fun drawToEncoder(bitmap: Bitmap, target: Surface): Boolean {
        val canvas = try {
            target.lockCanvas(null)
        } catch (e: Exception) {
            lockCanvasFailures++
            if (lockCanvasFailures % LOG_EVERY_N_FAILURES == 1) {
                Log.w(TAG, "lockCanvas on encoder surface failed (该编码器可能不支持 CPU 渲染，通道将失效)", e)
            }
            return false
        } ?: return false
        try {
            canvas.drawBitmap(bitmap, null, Rect(0, 0, canvas.width, canvas.height), null)
        } finally {
            try { target.unlockCanvasAndPost(canvas) } catch (_: Exception) {}
        }
        return true
    }

    private var lockCanvasFailures = 0

    companion object {
        private const val TAG = "MirrorCapture"
        // 蓝本口径：浅队列只取最新帧，画面不滞后
        private const val IMAGE_QUEUE_DEPTH = 2
        // ≈30fps 轮询，与编码器帧率匹配；泵线程被 lockCanvas 背压拖慢也无害
        private const val PUMP_INTERVAL_MS = 33L
        // 连续回灌失败≈4s 判定通道失效（给真机低端编码器留余量）
        private const val PUMP_FAILURE_GIVE_UP = 120
        private const val LOG_EVERY_N_FAILURES = 60
    }
}
