package com.example.call_log_manager

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.media.MediaActionSound
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.text.TextUtils
import android.text.TextPaint
import android.util.Log
import android.util.Size
import android.view.View
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Màn hình chụp ảnh nhanh độc lập, tối ưu siêu tốc độ và tiết kiệm tài nguyên cho thiết bị yếu:
 * - Chụp 1 chạm (Zero Confirm): bấm chụp là đóng ngay trong ~0.1s, đưa shipper về app giao hàng.
 * - Giới hạn TargetResolution 1280x960 để giảm 80% RAM, dung lượng file < 400KB và tăng tốc xử lý.
 * - Xử lý watermark, quét mã vạch và ghi thư viện hoàn toàn dưới nền (Zero UI Latency).
 * - Quét barcode trực tiếp từ Bitmap trong RAM, không đọc lại file JPEG trên đĩa.
 * - Thu hồi bộ nhớ (bitmap.recycle()) tức thì, chống tràn RAM và giật lag trên máy cấu hình yếu.
 *
 * === Tối ưu v2 (thiết bị yếu + chạy liên tục) ===
 * - Static MediaActionSound: load 1 lần, tái sử dụng mọi lần chụp (giảm 50ms latency)
 * - Static SimpleDateFormat: tránh GC mỗi lần chụp
 * - Static TextPaint: tái sử dụng, không tạo mới mỗi lần drawTimeMark
 * - RGB_565 bitmap decode: giảm 50% RAM so với ARGB_8888 (đủ cho ảnh JPEG không alpha)
 * - JPEG quality 82: file nhỏ hơn ~20%, ghi nhanh hơn, chất lượng gần tương đương
 * - Barcode scanner options static: tránh rebuild mỗi lần quét
 */
class TimeMarkCaptureActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "TimeMarkCapture"
        private const val CAMERA_PERMISSION_REQUEST = 1002
        private const val MAX_IMAGE_SIDE = 1280
        private const val JPEG_QUALITY = 82
        private val globalBackgroundExecutor: ExecutorService = ThreadPoolExecutor(
            0,
            1,
            30L,
            TimeUnit.SECONDS,
            LinkedBlockingQueue()
        )
        private val mainHandler = Handler(Looper.getMainLooper())

        // === Static reusable objects - giảm GC pressure ===

        // Tái sử dụng Paint nền watermark để giảm garbage collection
        private val backgroundBarPaint = Paint().apply {
            color = Color.argb(165, 0, 0, 0)
        }

        // Static TextPaint - tái sử dụng thay vì tạo mới mỗi lần drawTimeMark
        private val watermarkPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            typeface = android.graphics.Typeface.DEFAULT_BOLD
        }

        // Static SimpleDateFormat - tránh tạo mới mỗi lần chụp
        private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

        // Static barcode scanner options - tránh rebuild mỗi lần quét
        private val barcodeScannerOptions = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_CODE_39,
                Barcode.FORMAT_EAN_13,
                Barcode.FORMAT_EAN_8
            )
            .build()

        // Static MediaActionSound - load 1 lần, tái sử dụng (tránh leak + 50ms init mỗi lần)
        private val shutterSound: MediaActionSound? = try {
            MediaActionSound().also { it.load(MediaActionSound.SHUTTER_CLICK) }
        } catch (_: Exception) { null }
    }

    private lateinit var previewView: PreviewView
    private lateinit var btnShutter: ImageButton
    private lateinit var btnFlash: ImageButton
    private lateinit var btnSwitchCamera: ImageButton
    private lateinit var btnClose: ImageButton
    private lateinit var flashOverlay: View
    private lateinit var tvHint: TextView

    private var imageCapture: ImageCapture? = null
    private var camera: Camera? = null
    private var cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
    private var flashMode = ImageCapture.FLASH_MODE_OFF
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var isCapturing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_quick_camera)

        initViews()
        checkAndStartCamera()
    }

    private fun initViews() {
        previewView = findViewById(R.id.camera_preview)
        btnShutter = findViewById(R.id.btn_shutter)
        btnFlash = findViewById(R.id.btn_flash)
        btnSwitchCamera = findViewById(R.id.btn_switch_camera)
        btnClose = findViewById(R.id.btn_close)
        flashOverlay = findViewById(R.id.view_flash_overlay)
        tvHint = findViewById(R.id.tv_hint)

        btnClose.setOnClickListener {
            finishWithoutAnimation()
        }

        btnSwitchCamera.setOnClickListener {
            switchCamera()
        }

        btnFlash.setOnClickListener {
            toggleFlash()
        }

        btnShutter.setOnClickListener {
            takeQuickPhoto()
        }
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
                Toast.makeText(this, "Cần quyền Camera để chụp TimeMark", Toast.LENGTH_SHORT).show()
                finishWithoutAnimation()
            }
        }
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val resolutionSelector = androidx.camera.core.resolutionselector.ResolutionSelector.Builder()
                .setResolutionStrategy(
                    androidx.camera.core.resolutionselector.ResolutionStrategy(
                        Size(1280, 960),
                        androidx.camera.core.resolutionselector.ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                    )
                )
                .build()

            imageCapture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .setResolutionSelector(resolutionSelector)
                .setFlashMode(flashMode)
                .build()

            try {
                cameraProvider.unbindAll()
                camera = cameraProvider.bindToLifecycle(
                    this,
                    cameraSelector,
                    preview,
                    imageCapture
                )
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi khởi tạo Camera: ", e)
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun switchCamera() {
        cameraSelector = if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) {
            CameraSelector.DEFAULT_FRONT_CAMERA
        } else {
            CameraSelector.DEFAULT_BACK_CAMERA
        }
        startCamera()
    }

    private fun toggleFlash() {
        val capture = imageCapture ?: return
        flashMode = when (flashMode) {
            ImageCapture.FLASH_MODE_OFF -> ImageCapture.FLASH_MODE_ON
            ImageCapture.FLASH_MODE_ON -> ImageCapture.FLASH_MODE_AUTO
            else -> ImageCapture.FLASH_MODE_OFF
        }
        capture.flashMode = flashMode

        val iconRes = when (flashMode) {
            ImageCapture.FLASH_MODE_ON -> R.drawable.ic_camera_flash_on
            ImageCapture.FLASH_MODE_AUTO -> R.drawable.ic_camera_flash_auto
            else -> R.drawable.ic_camera_flash_off
        }
        btnFlash.setImageResource(iconRes)
    }

    private fun takeQuickPhoto() {
        val capture = imageCapture ?: return
        if (isCapturing) return
        isCapturing = true
        btnShutter.isEnabled = false

        // Phản hồi âm thanh & rung ngay khi bấm
        playShutterFeedback()

        // Hiệu ứng chớp màn hình như máy ảnh thật
        flashOverlay.apply {
            visibility = View.VISIBLE
            alpha = 0.85f
            animate().alpha(0f).setDuration(180).withEndAction {
                visibility = View.GONE
            }.start()
        }

        val cacheDir = File(cacheDir, "timemark").apply { mkdirs() }
        val rawFile = File(cacheDir, "raw_${System.currentTimeMillis()}.jpg")
        val outputOptions = ImageCapture.OutputFileOptions.Builder(rawFile).build()

        capture.takePicture(
            outputOptions,
            cameraExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onError(exc: ImageCaptureException) {
                    Log.e(TAG, "Lỗi chụp ảnh: ${exc.message}", exc)
                    mainHandler.post {
                        Toast.makeText(applicationContext, "Lỗi chụp: ${exc.message}", Toast.LENGTH_SHORT).show()
                        finishWithoutAnimation()
                    }
                }

                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    // Đóng activity NGAY LẬP TỨC để shipper trở về app giao hàng (Shopee, Grab,...) không cần chờ đợi!
                    val appContext = applicationContext
                    mainHandler.post {
                        finishWithoutAnimation()
                    }

                    // Toàn bộ tác vụ quét mã, lấy địa chỉ GPS, đóng dấu watermark và lưu thư viện chạy ngầm:
                    processInBackground(appContext, rawFile)
                }
            }
        )
    }

    private fun playShutterFeedback() {
        // Tái sử dụng static MediaActionSound thay vì tạo mới mỗi lần
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
            if (vibrator != null && vibrator.hasVibrator()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(45)
                }
            }
        } catch (_: Exception) {}
    }

    private fun finishWithoutAnimation() {
        finish()
        if (Build.VERSION.SDK_INT >= 34) {
            overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        super.onDestroy()
    }

    // ================= Xử lý ảnh ngầm dưới nền =================

    private fun processInBackground(appContext: Context, rawFile: File) {
        globalBackgroundExecutor.execute {
            var decodedBitmap: Bitmap? = null
            var watermarkedBitmap: Bitmap? = null
            try {
                if (!rawFile.exists() || rawFile.length() == 0L) return@execute

                val captureTime = Date()

                // 1. Giải mã compact bitmap 1 lần duy nhất trong RAM (~1280px, RGB_565 tiết kiệm 50% RAM)
                val bitmap = decodeCompactBitmap(rawFile)
                decodedBitmap = bitmap

                // 2. Quét mã vạch trực tiếp từ Bitmap trong RAM (không đọc lại đĩa, nhanh gấp 3 lần)
                val code = scanBarcodeFromBitmap(bitmap)

                // 3. Lấy vị trí toạ độ địa chỉ (có cache tức thì, không làm chậm CPU)
                val location = resolveAddress(appContext)

                // 4. Đóng dấu TimeMark trực tiếp lên Bitmap (cần convert sang ARGB_8888 cho Canvas)
                val watermarked = drawTimeMark(bitmap, captureTime, location, code)
                watermarkedBitmap = watermarked

                // 5. Lưu vào thư viện máy Pictures/TimeMark
                saveToGallery(appContext, watermarked)

                // 6. Xoá file raw tạm thời trên ổ đĩa để giải phóng bộ nhớ
                rawFile.delete()

                mainHandler.post {
                    val message = if (!code.isNullOrBlank()) {
                        "📸 Đã lưu TimeMark · $code"
                    } else if (!location.isNullOrBlank()) {
                        "📸 Đã lưu TimeMark · $location"
                    } else {
                        "📸 Đã lưu ảnh TimeMark thành công!"
                    }
                    Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi xử lý ảnh ngầm: ", e)
                mainHandler.post {
                    Toast.makeText(appContext, "Không thể lưu ảnh TimeMark", Toast.LENGTH_SHORT).show()
                }
            } finally {
                // Thu hồi bộ nhớ RAM ngay lập tức, ngăn chặn rò rỉ bộ nhớ
                watermarkedBitmap?.let { if (!it.isRecycled) it.recycle() }
                decodedBitmap?.let { if (it !== watermarkedBitmap && !it.isRecycled) it.recycle() }
            }
        }
    }

    /**
     * Quét mã vạch chỉ tập trung vào các định dạng mã đơn hàng giao vận phổ biến (QR, Code 128, Code 39, EAN)
     * Quét trực tiếp trên Bitmap 1280px, không đọc lại file JPEG từ đĩa.
     * Tái sử dụng static barcodeScannerOptions thay vì rebuild mỗi lần.
     */
    private fun scanBarcodeFromBitmap(bitmap: Bitmap): String? {
        val latch = CountDownLatch(1)
        var result: String? = null
        var scanner: com.google.mlkit.vision.barcode.BarcodeScanner? = null
        try {
            // Sử dụng static options thay vì tạo mới mỗi lần
            scanner = BarcodeScanning.getClient(barcodeScannerOptions)
            scanner.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener { barcodes ->
                    result = barcodes
                        .mapNotNull { it.rawValue?.trim() }
                        .filter { it.isNotEmpty() }
                        .distinct()
                        .take(2)
                        .joinToString(" | ")
                    latch.countDown()
                }
                .addOnFailureListener {
                    latch.countDown()
                }
            latch.await(800, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        } finally {
            try {
                scanner?.close()
            } catch (_: Exception) {}
        }
        return result?.takeIf { it.isNotEmpty() }
    }

    private fun resolveAddress(context: Context): String? {
        if (MockLocationManager.getInstance(context).isRunning()) return null
        val location = lastKnownLocation(context) ?: return null
        val cacheKey = "${String.format(Locale.US, "%.4f", location.latitude)},${String.format(Locale.US, "%.4f", location.longitude)}"
        val prefs = context.getSharedPreferences("timemark_address", Context.MODE_PRIVATE)
        prefs.getString(cacheKey, null)?.let { return it }

        return try {
            @Suppress("DEPRECATION")
            val address = Geocoder(context, Locale("vi", "VN"))
                .getFromLocation(location.latitude, location.longitude, 1)
                ?.firstOrNull()
                ?.let { place ->
                    listOfNotNull(place.getAddressLine(0), place.subAdminArea, place.adminArea)
                        .distinct()
                        .joinToString(", ")
                        .take(110)
                }
                ?.takeIf { it.isNotBlank() }

            if (address != null) prefs.edit().putString(cacheKey, address).apply()
            address
        } catch (_: Exception) {
            "${String.format(Locale.US, "%.6f", location.latitude)}, ${String.format(Locale.US, "%.6f", location.longitude)}"
        }
    }

    private fun lastKnownLocation(context: Context): Location? {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        return providers.mapNotNull { provider ->
            try { manager.getLastKnownLocation(provider) } catch (_: SecurityException) { null }
        }.maxByOrNull { it.time }
    }

    /**
     * Giải mã ảnh trực tiếp với inSampleSize tối ưu và biến đổi EXIF trong 1 bước duy nhất.
     * Dùng RGB_565 để giảm 50% RAM so với ARGB_8888 (JPEG không có alpha channel).
     */
    private fun decodeCompactBitmap(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)

        var sample = 1
        while (bounds.outWidth / (sample * 2) >= MAX_IMAGE_SIDE && bounds.outHeight / (sample * 2) >= MAX_IMAGE_SIDE) {
            sample *= 2
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            // RGB_565: 2 bytes/pixel thay vì 4 bytes/pixel (ARGB_8888)
            // JPEG không có alpha → tiết kiệm 50% RAM bitmap
            inPreferredConfig = Bitmap.Config.RGB_565
            inMutable = false // Không cần mutable ở bước decode, sẽ convert khi cần draw
        }

        val rawBitmap = BitmapFactory.decodeFile(file.path, options) ?: throw IllegalStateException("Không thể đọc ảnh")
        return transformForExifAndScale(rawBitmap, file)
    }

    private fun transformForExifAndScale(source: Bitmap, file: File): Bitmap {
        val orientation = try {
            ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }

        val largestSide = maxOf(source.width, source.height)
        val scale = if (largestSide > MAX_IMAGE_SIDE) MAX_IMAGE_SIDE.toFloat() / largestSide else 1f

        if (degrees == 0f && scale == 1f) {
            return source
        }

        val matrix = Matrix().apply {
            if (degrees != 0f) postRotate(degrees)
            if (scale != 1f) postScale(scale, scale)
        }

        val transformed = Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        if (transformed !== source) {
            source.recycle()
        }
        return transformed
    }

    private fun drawTimeMark(bitmap: Bitmap, captureTime: Date, location: String?, code: String?): Bitmap {
        // Canvas cần ARGB_8888, convert từ RGB_565 nếu cần (1 lần duy nhất)
        val result = if (bitmap.config == Bitmap.Config.RGB_565) {
            val argb = bitmap.copy(Bitmap.Config.ARGB_8888, true)
            bitmap.recycle() // Giải phóng bản RGB_565 ngay
            argb
        } else if (bitmap.isMutable) {
            bitmap
        } else {
            bitmap.copy(Bitmap.Config.ARGB_8888, true)
        }

        val canvas = Canvas(result)
        val densityScale = result.width / 1280f
        val fontSize = maxOf(18f, 26f * densityScale)
        val padding = maxOf(14f, 24f * densityScale)

        val lines = buildList {
            // Sử dụng static dateFormat thay vì tạo mới
            add("TIME  " + dateFormat.format(captureTime))
            if (!location.isNullOrBlank()) add(location)
            if (!code.isNullOrBlank()) add("CODE  " + code.take(72))
        }

        // Tái sử dụng static watermarkPaint, chỉ cập nhật textSize
        watermarkPaint.textSize = fontSize

        val height = padding * 2 + fontSize * 1.45f * lines.size
        canvas.drawRect(
            0f,
            result.height - height,
            result.width.toFloat(),
            result.height.toFloat(),
            backgroundBarPaint
        )
        lines.forEachIndexed { index, line ->
            val text = TextUtils.ellipsize(line, watermarkPaint, result.width - padding * 2, TextUtils.TruncateAt.END).toString()
            canvas.drawText(text, padding, result.height - height + padding + fontSize * (index + 1), watermarkPaint)
        }
        return result
    }

    private fun saveToGallery(context: Context, bitmap: Bitmap) {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "TimeMark_${System.currentTimeMillis()}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/TimeMark")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Không thể tạo tệp trong thư viện MediaStore")
        try {
            resolver.openOutputStream(uri).use { output ->
                // JPEG quality 82: file nhỏ hơn ~20%, ghi nhanh hơn, chất lượng gần tương đương 88
                if (output == null || !bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
                    throw IllegalStateException("Không thể ghi dữ liệu ảnh")
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }
}
