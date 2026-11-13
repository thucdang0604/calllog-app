package com.example.call_log_manager

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.YuvImage
import android.media.Image
import android.media.MediaActionSound
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.util.Size
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class BarcodeScanActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "BarcodeScanActivity"
        private const val CAMERA_PERMISSION_REQUEST = 3001
        private const val DEBOUNCE_SAME_CODE_MS = 1500L
        private const val CONSENSUS_WINDOW_MS = 1200L
        private const val REQUIRED_FRAMES_2D = 2
        private const val REQUIRED_FRAMES_1D = 3
        private const val MIN_1D_CODE_LENGTH = 5
        private const val PREF_NAME = "floating_window_state"
        private const val KEY_SAVE_BARCODE_PHOTO = "barcode_save_photo_enabled"
        private const val PHOTO_SUBDIR = "barcode_scan_photos"
        private const val MAX_SAVED_IMAGE_DIM = 900
        private const val WEBP_QUALITY = 75
        private const val PHOTO_FLUSH_TIMEOUT_MS = 1500L

        // Allow alphanumeric characters with optional single '.', '-', '_' separators inside
        // (e.g. AVN90452708-1.1, 38861094_402533213) while rejecting leading/trailing symbols or noise.
        private val ONE_D_CODE_REGEX = Regex("^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$")

        private val barcodeScannerOptions = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_CODE_39,
                Barcode.FORMAT_CODE_93,
                Barcode.FORMAT_EAN_13,
                Barcode.FORMAT_EAN_8,
                Barcode.FORMAT_UPC_A,
                Barcode.FORMAT_UPC_E,
                Barcode.FORMAT_DATA_MATRIX
            )
            .build()
    }

    private data class CapturedYuvFrame(
        val nv21: ByteArray,
        val width: Int,
        val height: Int,
        val rotationDegrees: Int
    )

    private lateinit var previewView: PreviewView
    private lateinit var viewfinderBox: View
    private lateinit var btnClose: ImageButton
    private lateinit var btnFlash: ImageButton
    private lateinit var btnTogglePhoto: TextView
    private lateinit var tvLastScanned: TextView
    private lateinit var tvCounter: TextView
    private lateinit var btnDone: Button
    private lateinit var laserLine: View

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var isTorchOn = false
    private var isSavePhotoEnabled = true
    private var isFinishingSession = false
    private val isAnalyzing = AtomicBoolean(false)
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val photoExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val pendingPhotoTasks = AtomicInteger(0)
    private val photoSequence = AtomicInteger(0)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val barcodeScanner: BarcodeScanner by lazy {
        BarcodeScanning.getClient(barcodeScannerOptions)
    }

    private val shutterSound: MediaActionSound? by lazy {
        try {
            MediaActionSound().also { it.load(MediaActionSound.SHUTTER_CLICK) }
        } catch (_: Exception) { null }
    }

    private val scannedCodesList = ArrayList<JSONObject>()
    private val candidateHits = HashMap<String, MutableList<Long>>()
    private var lastScannedCode: String = ""
    private var lastScannedTime: Long = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_barcode_scan)

        initViews()
        checkAndStartCamera()
    }

    private fun initViews() {
        previewView = findViewById(R.id.barcode_camera_preview)
        viewfinderBox = findViewById(R.id.viewfinder_box)
        btnClose = findViewById(R.id.btn_barcode_close)
        btnFlash = findViewById(R.id.btn_barcode_flash)
        btnTogglePhoto = findViewById(R.id.btn_barcode_toggle_photo)
        tvLastScanned = findViewById(R.id.tv_last_scanned)
        tvCounter = findViewById(R.id.tv_barcode_counter)
        btnDone = findViewById(R.id.btn_barcode_done)
        laserLine = findViewById(R.id.laser_line)

        val prefs = getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        isSavePhotoEnabled = prefs.getBoolean(KEY_SAVE_BARCODE_PHOTO, true)
        updatePhotoToggleUi()

        btnTogglePhoto.setOnClickListener {
            isSavePhotoEnabled = !isSavePhotoEnabled
            prefs.edit().putBoolean(KEY_SAVE_BARCODE_PHOTO, isSavePhotoEnabled).apply()
            updatePhotoToggleUi()
        }

        btnClose.setOnClickListener {
            finishWithResult()
        }

        btnDone.setOnClickListener {
            finishWithResult()
        }

        btnFlash.setOnClickListener {
            toggleFlash()
        }

        previewView.setOnTouchListener { view, event ->
            if (event.action == MotionEvent.ACTION_UP) {
                focusAt(event.x, event.y)
                view.performClick()
            }
            true
        }
    }

    private fun updatePhotoToggleUi() {
        if (isSavePhotoEnabled) {
            btnTogglePhoto.text = "📷 Lưu ảnh ngoại quan: BẬT"
            btnTogglePhoto.setTextColor(Color.parseColor("#81C784"))
        } else {
            btnTogglePhoto.text = "📷 Lưu ảnh ngoại quan: TẮT"
            btnTogglePhoto.setTextColor(Color.parseColor("#BDBDBD"))
        }
    }

    private fun toggleFlash() {
        val cam = camera ?: return
        if (!cam.cameraInfo.hasFlashUnit()) {
            Toast.makeText(this, "Thiết bị không có đèn Flash", Toast.LENGTH_SHORT).show()
            return
        }
        isTorchOn = !isTorchOn
        cam.cameraControl.enableTorch(isTorchOn)
        btnFlash.setImageResource(
            if (isTorchOn) R.drawable.ic_camera_flash_on else R.drawable.ic_camera_flash_off
        )
    }

    private fun checkAndStartCamera() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                CAMERA_PERMISSION_REQUEST
            )
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startCamera()
            } else {
                Toast.makeText(this, "Cần quyền camera để quét mã", Toast.LENGTH_SHORT).show()
                finish()
            }
        }
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener({
            try {
                val provider = providerFuture.get()
                cameraProvider = provider

                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }

                // Request 4:3 HD frames so vertical FOV is ~25-30% wider for parcel overview while keeping 1D bars crisp.
                val resolutionSelector = ResolutionSelector.Builder()
                    .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(1280, 960),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                        )
                    )
                    .build()

                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(resolutionSelector)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()

                analysis.setAnalyzer(cameraExecutor) { imageProxy ->
                    analyzeFrame(imageProxy)
                }

                provider.unbindAll()
                camera = provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis
                )

                previewView.post { focusOnViewfinderCenter() }
            } catch (error: Exception) {
                Log.e(TAG, "Lỗi khởi tạo camera quét", error)
                Toast.makeText(this, "Không thể mở camera: ${error.message}", Toast.LENGTH_SHORT).show()
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun focusOnViewfinderCenter() {
        if (previewView.width <= 0 || previewView.height <= 0) return
        val pvLoc = IntArray(2)
        val vfLoc = IntArray(2)
        previewView.getLocationInWindow(pvLoc)
        viewfinderBox.getLocationInWindow(vfLoc)

        val centerX = if (viewfinderBox.width > 0) {
            (vfLoc[0] - pvLoc[0]) + viewfinderBox.width / 2f
        } else {
            previewView.width / 2f
        }
        val centerY = if (viewfinderBox.height > 0) {
            (vfLoc[1] - pvLoc[1]) + viewfinderBox.height / 2f
        } else {
            previewView.height / 2f
        }
        focusAt(centerX, centerY)
    }

    private fun focusAt(x: Float, y: Float) {
        val cam = camera ?: return
        try {
            val point = previewView.meteringPointFactory.createPoint(x, y)
            val action = FocusMeteringAction.Builder(
                point,
                FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE
            )
                .setAutoCancelDuration(2, TimeUnit.SECONDS)
                .build()
            cam.cameraControl.startFocusAndMetering(action)
        } catch (_: Exception) {}
    }

    private fun analyzeFrame(imageProxy: androidx.camera.core.ImageProxy) {
        if (isFinishingSession || !isAnalyzing.compareAndSet(false, true)) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            isAnalyzing.set(false)
            imageProxy.close()
            return
        }

        try {
            val rotationDegrees = imageProxy.imageInfo.rotationDegrees
            val uprightWidth = if (rotationDegrees == 90 || rotationDegrees == 270) {
                mediaImage.height
            } else {
                mediaImage.width
            }
            val uprightHeight = if (rotationDegrees == 90 || rotationDegrees == 270) {
                mediaImage.width
            } else {
                mediaImage.height
            }
            val inputImage = InputImage.fromMediaImage(mediaImage, rotationDegrees)

            barcodeScanner.process(inputImage)
                .addOnSuccessListener { barcodes ->
                    processDetectedBarcodes(
                        barcodes = barcodes,
                        imageWidth = uprightWidth,
                        imageHeight = uprightHeight,
                        mediaImage = mediaImage,
                        rotationDegrees = rotationDegrees
                    )
                }
                .addOnFailureListener { error ->
                    Log.w(TAG, "Không đọc được mã trong khung hình", error)
                }
                .addOnCompleteListener {
                    imageProxy.close()
                    isAnalyzing.set(false)
                }
        } catch (e: Exception) {
            isAnalyzing.set(false)
            imageProxy.close()
            Log.w(TAG, "Lỗi phân tích khung hình", e)
        }
    }

    private fun processDetectedBarcodes(
        barcodes: List<Barcode>,
        imageWidth: Int,
        imageHeight: Int,
        mediaImage: Image,
        rotationDegrees: Int
    ) {
        if (isFinishingSession || barcodes.isEmpty()) return

        val roi = computeViewfinderRoi(imageWidth, imageHeight)
        var bestRaw: String? = null
        var bestFormat = Barcode.FORMAT_UNKNOWN
        var bestDistanceSq = Float.MAX_VALUE

        for (barcode in barcodes) {
            val raw = barcode.rawValue?.trim() ?: continue
            if (!isValidScannedCode(raw, barcode.format)) continue

            val box = barcode.boundingBox
            if (roi != null) {
                if (box == null) continue
                val cx = box.centerX().toFloat()
                val cy = box.centerY().toFloat()
                if (!roi.contains(cx, cy)) continue

                val dx = cx - roi.centerX()
                val dy = cy - roi.centerY()
                val distSq = dx * dx + dy * dy
                if (distSq < bestDistanceSq) {
                    bestDistanceSq = distSq
                    bestRaw = raw
                    bestFormat = barcode.format
                }
            } else {
                bestRaw = raw
                bestFormat = barcode.format
                break
            }
        }

        if (bestRaw != null) {
            handleBarcodeCandidate(bestRaw, bestFormat, mediaImage, rotationDegrees)
        }
    }

    private fun computeViewfinderRoi(imageWidth: Int, imageHeight: Int): RectF? {
        val pvW = previewView.width.toFloat()
        val pvH = previewView.height.toFloat()
        val vfW = viewfinderBox.width.toFloat()
        val vfH = viewfinderBox.height.toFloat()
        if (pvW <= 0f || pvH <= 0f || vfW <= 0f || vfH <= 0f || imageWidth <= 0 || imageHeight <= 0) {
            return null
        }

        val pvLoc = IntArray(2)
        val vfLoc = IntArray(2)
        previewView.getLocationInWindow(pvLoc)
        viewfinderBox.getLocationInWindow(vfLoc)

        val boxLeft = (vfLoc[0] - pvLoc[0]).toFloat()
        val boxTop = (vfLoc[1] - pvLoc[1]).toFloat()
        val boxRight = boxLeft + vfW
        val boxBottom = boxTop + vfH

        val padX = vfW * 0.08f
        val padY = vfH * 0.10f

        // PreviewView uses ScaleType.FILL_CENTER
        val scale = maxOf(pvW / imageWidth.toFloat(), pvH / imageHeight.toFloat())
        val dx = (imageWidth * scale - pvW) / 2f
        val dy = (imageHeight * scale - pvH) / 2f

        return RectF(
            ((boxLeft - padX + dx) / scale).coerceIn(0f, imageWidth.toFloat()),
            ((boxTop - padY + dy) / scale).coerceIn(0f, imageHeight.toFloat()),
            ((boxRight + padX + dx) / scale).coerceIn(0f, imageWidth.toFloat()),
            ((boxBottom + padY + dy) / scale).coerceIn(0f, imageHeight.toFloat())
        )
    }

    private fun is2DFormat(format: Int): Boolean {
        return format == Barcode.FORMAT_QR_CODE || format == Barcode.FORMAT_DATA_MATRIX
    }

    private fun isValidScannedCode(rawCode: String, format: Int): Boolean {
        if (rawCode.isEmpty()) return false
        if (rawCode.any { it.code < 32 || it.code == 127 }) return false

        if (is2DFormat(format)) {
            return rawCode.length >= 4 && !rawCode.any { it == '\n' || it == '\r' }
        }

        if (rawCode.any { it.isWhitespace() }) return false
        if (rawCode.length < MIN_1D_CODE_LENGTH) return false
        return ONE_D_CODE_REGEX.matches(rawCode)
    }

    private fun handleBarcodeCandidate(
        rawCode: String,
        format: Int,
        mediaImage: Image,
        rotationDegrees: Int
    ) {
        val now = System.currentTimeMillis()
        if (rawCode == lastScannedCode && (now - lastScannedTime) < DEBOUNCE_SAME_CODE_MS) {
            return
        }

        val iterator = candidateHits.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.removeAll { (now - it) > CONSENSUS_WINDOW_MS }
            if (entry.value.isEmpty()) {
                iterator.remove()
            }
        }

        val hits = candidateHits.getOrPut(rawCode) { ArrayList() }
        hits.add(now)

        val requiredFrames = if (is2DFormat(format)) REQUIRED_FRAMES_2D else REQUIRED_FRAMES_1D
        if (hits.size < requiredFrames) {
            return
        }

        candidateHits.remove(rawCode)
        handleBarcodeDetected(rawCode, getFormatName(format), mediaImage, rotationDegrees)
    }

    private fun handleBarcodeDetected(
        rawCode: String,
        format: String,
        mediaImage: Image,
        rotationDegrees: Int
    ) {
        val now = System.currentTimeMillis()
        if (rawCode == lastScannedCode && (now - lastScannedTime) < DEBOUNCE_SAME_CODE_MS) {
            return
        }

        lastScannedCode = rawCode
        lastScannedTime = now

        // Check if duplicate in the whole current session
        val isDuplicate = scannedCodesList.any { it.optString("code") == rawCode }
        if (!isDuplicate) {
            var savedImagePath: String? = null
            if (isSavePhotoEnabled && !photoExecutor.isShutdown) {
                val frame = extractYuvFrame(mediaImage, rotationDegrees)
                if (frame != null) {
                    val outFile = createPhotoOutputFile(now)
                    savedImagePath = outFile.absolutePath
                    pendingPhotoTasks.incrementAndGet()
                    try {
                        photoExecutor.execute {
                            try {
                                compressAndSaveFrame(frame, outFile)
                            } finally {
                                pendingPhotoTasks.decrementAndGet()
                            }
                        }
                    } catch (e: Exception) {
                        pendingPhotoTasks.decrementAndGet()
                        savedImagePath = null
                        Log.w(TAG, "Không thể xếp hàng lưu ảnh", e)
                    }
                }
            }

            val obj = JSONObject().apply {
                put("code", rawCode)
                put("format", format)
                put("timestamp", now)
                if (!savedImagePath.isNullOrEmpty()) {
                    put("imagePath", savedImagePath)
                }
            }
            scannedCodesList.add(obj)
        }

        mainHandler.post {
            playFeedback()

            val prefix = if (isDuplicate) "🔁 Đã có: " else "✅ Đã quét: "
            tvLastScanned.text = "$prefix$rawCode\n($format)"
            tvCounter.text = "Đã quét: ${scannedCodesList.size} mã"
            btnDone.text = "✓ Hoàn tất (${scannedCodesList.size})"

            // Laser line animation
            laserLine.animate()
                .scaleX(1.15f)
                .setDuration(120)
                .withEndAction { laserLine.animate().scaleX(1.0f).setDuration(120).start() }
                .start()
        }
    }

    private fun createPhotoOutputFile(timestamp: Long): File {
        val dir = File(filesDir, PHOTO_SUBDIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        val seq = photoSequence.incrementAndGet()
        return File(dir, "scan_${timestamp}_$seq.webp")
    }

    private fun extractYuvFrame(image: Image, rotationDegrees: Int): CapturedYuvFrame? {
        return try {
            val planes = image.planes
            if (planes.size < 3) return null

            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return null

            val nv21 = ByteArray(width * height * 3 / 2)

            val yPlane = planes[0]
            val yBuf = yPlane.buffer.duplicate()
            val yRowStride = yPlane.rowStride
            val yPixelStride = yPlane.pixelStride
            val yCapacity = yBuf.capacity()
            val yRowBytes = ByteArray(yRowStride.coerceAtLeast(width))

            for (row in 0 until height) {
                val rowStart = row * yRowStride
                if (rowStart >= yCapacity) break
                val destOffset = row * width
                if (yPixelStride == 1) {
                    val count = minOf(width, yCapacity - rowStart)
                    yBuf.position(rowStart)
                    yBuf.get(nv21, destOffset, count)
                } else {
                    val needed = (width - 1) * yPixelStride + 1
                    val count = minOf(needed, yCapacity - rowStart)
                    yBuf.position(rowStart)
                    yBuf.get(yRowBytes, 0, count)
                    for (col in 0 until width) {
                        val srcIdx = col * yPixelStride
                        if (srcIdx < count) {
                            nv21[destOffset + col] = yRowBytes[srcIdx]
                        }
                    }
                }
            }

            val uPlane = planes[1]
            val vPlane = planes[2]
            val uBuf = uPlane.buffer.duplicate()
            val vBuf = vPlane.buffer.duplicate()
            val uRowStride = uPlane.rowStride
            val vRowStride = vPlane.rowStride
            val uPixelStride = uPlane.pixelStride
            val vPixelStride = vPlane.pixelStride
            val uCapacity = uBuf.capacity()
            val vCapacity = vBuf.capacity()

            val chromaWidth = width / 2
            val chromaHeight = height / 2
            val uRowNeed = (chromaWidth - 1) * uPixelStride + 1
            val vRowNeed = (chromaWidth - 1) * vPixelStride + 1
            val uRowBytes = ByteArray(uRowNeed.coerceAtLeast(1))
            val vRowBytes = ByteArray(vRowNeed.coerceAtLeast(1))

            var uvOutPos = width * height
            for (row in 0 until chromaHeight) {
                val uStart = row * uRowStride
                val vStart = row * vRowStride
                if (uStart >= uCapacity || vStart >= vCapacity) break

                val uAvail = minOf(uRowNeed, uCapacity - uStart)
                val vAvail = minOf(vRowNeed, vCapacity - vStart)
                uBuf.position(uStart)
                uBuf.get(uRowBytes, 0, uAvail)
                vBuf.position(vStart)
                vBuf.get(vRowBytes, 0, vAvail)

                for (col in 0 until chromaWidth) {
                    val vIdx = col * vPixelStride
                    val uIdx = col * uPixelStride
                    nv21[uvOutPos++] = if (vIdx < vAvail) vRowBytes[vIdx] else 128.toByte()
                    nv21[uvOutPos++] = if (uIdx < uAvail) uRowBytes[uIdx] else 128.toByte()
                }
            }

            CapturedYuvFrame(nv21, width, height, rotationDegrees)
        } catch (e: Exception) {
            Log.w(TAG, "Không trích xuất được khung hình YUV", e)
            null
        }
    }

    private fun compressAndSaveFrame(frame: CapturedYuvFrame, outputFile: File) {
        var decoded: Bitmap? = null
        var finalBitmap: Bitmap? = null
        try {
            val jpegStream = ByteArrayOutputStream()
            val yuvImage = YuvImage(frame.nv21, ImageFormat.NV21, frame.width, frame.height, null)
            yuvImage.compressToJpeg(Rect(0, 0, frame.width, frame.height), 92, jpegStream)
            val jpegBytes = jpegStream.toByteArray()

            val options = BitmapFactory.Options().apply {
                inSampleSize = if (maxOf(frame.width, frame.height) >= 1920) 2 else 1
            }
            decoded = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size, options) ?: return

            val rotDeg = frame.rotationDegrees
            val rotW = if (rotDeg == 90 || rotDeg == 270) decoded.height else decoded.width
            val rotH = if (rotDeg == 90 || rotDeg == 270) decoded.width else decoded.height
            val longest = maxOf(rotW, rotH)
            val scale = if (longest > MAX_SAVED_IMAGE_DIM) {
                MAX_SAVED_IMAGE_DIM.toFloat() / longest.toFloat()
            } else {
                1f
            }

            val matrix = Matrix().apply {
                if (rotDeg != 0) postRotate(rotDeg.toFloat())
                if (scale < 1f) postScale(scale, scale)
            }

            finalBitmap = if (rotDeg == 0 && scale >= 1f) {
                decoded
            } else {
                Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            }

            outputFile.parentFile?.let { parent ->
                if (!parent.exists()) parent.mkdirs()
            }

            FileOutputStream(outputFile).use { fos ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    finalBitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, WEBP_QUALITY, fos)
                } else {
                    @Suppress("DEPRECATION")
                    finalBitmap.compress(Bitmap.CompressFormat.WEBP, WEBP_QUALITY, fos)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi lưu ảnh ngoại quan", e)
            try {
                if (outputFile.exists()) outputFile.delete()
            } catch (_: Exception) {}
        } finally {
            if (finalBitmap != null && finalBitmap !== decoded && !finalBitmap.isRecycled) {
                finalBitmap.recycle()
            }
            if (decoded != null && !decoded.isRecycled) {
                decoded.recycle()
            }
        }
    }

    private fun playFeedback() {
        try {
            shutterSound?.play(MediaActionSound.SHUTTER_CLICK)
        } catch (_: Exception) {}

        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(45)
            }
        } catch (_: Exception) {}
    }

    private fun getFormatName(format: Int): String {
        return when (format) {
            Barcode.FORMAT_QR_CODE -> "QR Code"
            Barcode.FORMAT_CODE_128 -> "Code 128"
            Barcode.FORMAT_CODE_39 -> "Code 39"
            Barcode.FORMAT_CODE_93 -> "Code 93"
            Barcode.FORMAT_EAN_13 -> "EAN-13"
            Barcode.FORMAT_EAN_8 -> "EAN-8"
            Barcode.FORMAT_UPC_A -> "UPC-A"
            Barcode.FORMAT_UPC_E -> "UPC-E"
            Barcode.FORMAT_DATA_MATRIX -> "Data Matrix"
            else -> "Mã vạch"
        }
    }

    private fun finishWithResult() {
        if (isFinishingSession) return
        isFinishingSession = true
        btnDone.isEnabled = false
        btnClose.isEnabled = false

        if (pendingPhotoTasks.get() <= 0) {
            deliverResultAndFinish()
            return
        }

        photoExecutor.shutdown()
        Thread {
            try {
                photoExecutor.awaitTermination(PHOTO_FLUSH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {}
            mainHandler.post {
                if (!isDestroyed && !isFinishing) {
                    deliverResultAndFinish()
                }
            }
        }.start()
    }

    private fun deliverResultAndFinish() {
        val jsonArray = JSONArray()
        for (item in scannedCodesList) {
            jsonArray.put(item)
        }
        val resultIntent = Intent().apply {
            putExtra("scanned_codes_json", jsonArray.toString())
            putExtra("scanned_count", scannedCodesList.size)
        }
        setResult(Activity.RESULT_OK, resultIntent)
        finish()
    }

    override fun onBackPressed() {
        finishWithResult()
    }

    override fun onDestroy() {
        isFinishingSession = true
        mainHandler.removeCallbacksAndMessages(null)
        cameraExecutor.shutdown()
        photoExecutor.shutdown()
        barcodeScanner.close()
        super.onDestroy()
    }
}

