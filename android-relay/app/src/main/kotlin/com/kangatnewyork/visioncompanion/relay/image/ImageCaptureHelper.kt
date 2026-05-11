package com.kangatnewyork.visioncompanion.relay.image

import android.annotation.SuppressLint
import android.content.Context
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import com.google.common.util.concurrent.ListenableFuture
import com.kangatnewyork.visioncompanion.relay.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * Single-shot JPEG capture using CameraX. Lives separately from
 * GlassesTransport because CameraX is heavy and only the phone-mode
 * transport actually needs it.
 *
 * Usage:
 *   val helper = ImageCaptureHelper(context, lifecycleOwner)
 *   helper.start()
 *   val jpeg = helper.captureJpeg()   // suspends until one frame is ready
 *   helper.stop()
 */
class ImageCaptureHelper(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) {
    private val tag = "Image"
    private val cameraExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vc-camera").apply { isDaemon = true }
    }

    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null

    suspend fun start() = withContext(Dispatchers.Main) {
        if (imageCapture != null) return@withContext
        Logger.i(tag, "ImageCapture start")
        val provider = ProcessCameraProvider.getInstance(context).await()
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
        try {
            provider.unbindAll()
            provider.bindToLifecycle(
                lifecycleOwner,
                CameraSelector.DEFAULT_BACK_CAMERA,
                capture
            )
        } catch (t: Throwable) {
            Logger.e(tag, "CameraX bindToLifecycle failed", t)
            throw t
        }
        cameraProvider = provider
        imageCapture = capture
        Logger.i(tag, "ImageCapture ready")
    }

    fun stop() {
        Logger.i(tag, "ImageCapture stop")
        try {
            cameraProvider?.unbindAll()
        } catch (t: Throwable) {
            Logger.w(tag, "unbindAll failed", t)
        }
        cameraProvider = null
        imageCapture = null
    }

    /** Captures one JPEG. Returns null on failure (logged). */
    @SuppressLint("UnsafeOptInUsageError")
    suspend fun captureJpeg(): ByteArray? {
        val capture = imageCapture ?: run {
            Logger.w(tag, "captureJpeg: not started yet")
            return null
        }
        return suspendCoroutine { cont ->
            capture.takePicture(cameraExecutor, object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        Logger.d(tag, "captureJpeg bytes=${bytes.size}")
                        cont.resume(bytes)
                    } catch (t: Throwable) {
                        Logger.e(tag, "JPEG buffer read failed", t)
                        cont.resume(null)
                    } finally {
                        image.close()
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Logger.e(tag, "takePicture error code=${exception.imageCaptureError}", exception)
                    cont.resume(null)
                }
            })
        }
    }

    private suspend fun <T> ListenableFuture<T>.await(): T =
        suspendCancellableCoroutine { cont ->
            addListener({
                try {
                    cont.resume(get())
                } catch (t: Throwable) {
                    cont.cancel(t)
                }
            }, cameraExecutor)
        }
}
