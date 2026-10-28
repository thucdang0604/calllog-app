package com.example.call_log_manager

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

class OrderScanCaptureActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_SESSION_ID = "payment_session_id"
        const val EXTRA_PHONE = "payment_phone"
        const val EXTRA_MESSAGE = "payment_message"

        private const val TAG = "OrderScanCapture"
        private const val CAMERA_PERMISSION_REQUEST = 2401
        private const val MAX_STORED_IMAGE_SIDE = 2048
        private const val JPEG_QUALITY = 86
    }

    private val sessionId: String by lazy { intent.getStringExtra(EXTRA_SESSION_ID).orEmpty() }
    private val phone: String by lazy { intent.getStringExtra(EXTRA_PHONE).orEmpty() }
    private val smsMessage: String by lazy { intent.getStringExtra(EXTRA_MESSAGE).orEmpty() }

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val statusHandler = Handler(Looper.getMainLooper())
    private val isAnalyzing = AtomicBoolean(false)
    private val captureStarted = AtomicBoolean(false)

    private val barcodeScannerDelegate = lazy {
        val options = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_CODE_39,
                Barcode.FORMAT_EAN_13,
                Barcode.FORMAT_EAN_8,
                Barcode.FORMAT_UPC_A,
                Barcode.FORMAT_UPC_E,
                Barcode.FORMAT_ITF,
                Barcode.FORMAT_PDF417,
                Barcode.FORMAT_AZTEC,
                Barcode.FORMAT_DATA_MATRIX
            )
            .build()
        BarcodeScanning.getClient(options)
    }
    private val barcodeScanner: BarcodeScanner by barcodeScannerDelegate

    private lateinit var previewFrame: FrameLayout
    private lateinit var previewView: PreviewView
    private lateinit var scanMessageView: TextView
    private lateinit var resultPanel: ScrollView
    private lateinit var resultImage: ImageView
    private lateinit var resultStatus: TextView
    private lateinit var orderCodeView: TextView
    private lateinit var phoneView: TextView
    private lateinit var smsMessageView: TextView

    private var cameraProvider: ProcessCameraProvider? = null
    private var imageCapture: ImageCapture? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var previewBitmap: Bitmap? = null
    private var smsStatusPollAttempts = 0
    private val refreshSmsStatus = object : Runnable {
        override fun run() {
            val status = readSmsStatus()
            resultStatus.text = status.second
            if (status.first != "sending") return

            smsStatusPollAttempts++
            if (smsStatusPollAttempts < 30) {
                statusHandler.postDelayed(this, 1000)
            } else {
                resultStatus.text = "Chưa nhận được kết quả gửi SMS. Hãy kiểm tra tin nhắn trên máy."
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        if (sessionId.isBlank()) {
            Toast.makeText(this, "Thiếu thông tin phiên tin nhắn", Toast.LENGTH_LONG).show()
            finish()
            return
        }

        buildScreen()
        checkCameraPermissionAndStart()
    }

    private fun buildScreen() {
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        previewFrame = FrameLayout(this)
        previewView = PreviewView(this).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        previewFrame.addView(
            previewView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        val instruction = TextView(this).apply {
            text = "Quét QR hoặc mã vạch trên đơn hàng"
            setTextColor(Color.WHITE)
            textSize = 17f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(12), dp(18), dp(12))
            background = roundedBackground(Color.argb(190, 0, 0, 0), 12)
        }
        val instructionParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP
        ).apply {
            setMargins(dp(18), dp(34), dp(18), 0)
        }
        previewFrame.addView(instruction, instructionParams)

        val scanGuide = View(this).apply {
            background = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(2), Color.WHITE)
                cornerRadius = dp(12).toFloat()
            }
        }
        previewFrame.addView(
            scanGuide,
            FrameLayout.LayoutParams(dp(300), dp(170), Gravity.CENTER)
        )

        scanMessageView = TextView(this).apply {
            text = "Đưa mã vào khung để quét"
            setTextColor(Color.WHITE)
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(10), dp(16), dp(10))
            background = roundedBackground(Color.argb(190, 0, 0, 0), 10)
        }
        previewFrame.addView(
            scanMessageView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM
            ).apply { setMargins(dp(22), 0, dp(22), dp(34)) }
        )

        val closeButton = Button(this).apply {
            text = "Đóng"
            setOnClickListener { finish() }
        }
        previewFrame.addView(
            closeButton,
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(48), Gravity.TOP or Gravity.END)
                .apply { setMargins(0, dp(78), dp(18), 0) }
        )

        resultPanel = ScrollView(this).apply {
            visibility = View.GONE
            setBackgroundColor(Color.BLACK)
        }
        val resultContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(18), dp(16), dp(18))
        }
        resultImage = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            contentDescription = "Ảnh chụp sau khi quét mã đơn"
        }
        resultContent.addView(
            resultImage,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(310))
        )

        resultStatus = resultText("", 13f, Color.LTGRAY)
        resultStatus.setPadding(0, dp(10), 0, dp(8))
        resultContent.addView(resultStatus)

        orderCodeView = resultText("", 18f, Color.WHITE, bold = true)
        resultContent.addView(orderCodeView)

        phoneView = resultText("", 15f, Color.WHITE)
        phoneView.setPadding(0, dp(6), 0, dp(10))
        resultContent.addView(phoneView)

        val messageTitle = resultText("Nội dung tin nhắn", 14f, Color.LTGRAY, bold = true)
        resultContent.addView(messageTitle)
        smsMessageView = resultText("", 15f, Color.WHITE)
        smsMessageView.setTextIsSelectable(true)
        smsMessageView.setPadding(0, dp(5), 0, dp(16))
        resultContent.addView(smsMessageView)

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val scanAgainButton = Button(this).apply {
            text = "Quét lại"
            setOnClickListener { resumeScanning() }
        }
        val doneButton = Button(this).apply {
            text = "Xong"
            setOnClickListener { finish() }
        }
        buttons.addView(scanAgainButton)
        buttons.addView(doneButton)
        resultContent.addView(buttons)
        resultPanel.addView(resultContent)

        root.addView(
            previewFrame,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        root.addView(
            resultPanel,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        setContentView(root)
    }

    private fun checkCameraPermissionAndStart() {
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

    @Deprecated("Deprecated in Android API; retained for compatibility with the app's min SDK")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST) return
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            Toast.makeText(this, "Cần quyền camera để quét mã đơn", Toast.LENGTH_LONG).show()
            finish()
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
                val capture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .build()
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(cameraExecutor) { imageProxy -> analyzeFrame(imageProxy) }

                imageCapture = capture
                imageAnalysis = analysis
                provider.unbindAll()
                provider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    capture,
                    analysis
                )
            } catch (error: Exception) {
                Log.e(TAG, "Không thể mở camera quét mã", error)
                Toast.makeText(this, "Không thể khởi tạo camera", Toast.LENGTH_LONG).show()
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeFrame(imageProxy: androidx.camera.core.ImageProxy) {
        if (captureStarted.get() || !isAnalyzing.compareAndSet(false, true)) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            isAnalyzing.set(false)
            imageProxy.close()
            return
        }

        var orderCode: String? = null
        try {
            val inputImage = InputImage.fromMediaImage(
                mediaImage,
                imageProxy.imageInfo.rotationDegrees
            )
            barcodeScanner.process(inputImage)
                .addOnSuccessListener { barcodes ->
                    orderCode = barcodes.firstOrNull { !it.rawValue.isNullOrBlank() }?.rawValue
                }
                .addOnFailureListener { error ->
                    Log.w(TAG, "Không đọc được mã trong khung hình", error)
                }
                .addOnCompleteListener {
                    imageProxy.close()
                    isAnalyzing.set(false)
                    val detected = orderCode?.trim().orEmpty()
                    if (detected.isNotEmpty() && captureStarted.compareAndSet(false, true)) {
                        runOnUiThread { captureAfterScan(detected) }
                    }
                }
        } catch (error: Exception) {
            isAnalyzing.set(false)
            imageProxy.close()
            Log.w(TAG, "Lỗi phân tích khung hình", error)
        }
    }

    private fun captureAfterScan(orderCode: String) {
        imageAnalysis?.clearAnalyzer()
        scanMessageView.text = "Đã quét ${orderCode}\nĐang chụp ảnh..."

        val capture = imageCapture
        if (capture == null) {
            resetScanner("Camera chưa sẵn sàng, hãy quét lại")
            return
        }

        val folder = File(filesDir, "payment_receipts")
        if (!folder.exists() && !folder.mkdirs()) {
            resetScanner("Không tạo được thư mục lưu ảnh")
            return
        }
        val imageName = "${sessionId}_${System.currentTimeMillis()}"
        val rawFile = File(folder, ".$imageName.capture.jpg")
        val outputFile = File(folder, "$imageName.jpg")

        val outputOptions = ImageCapture.OutputFileOptions.Builder(rawFile).build()
        capture.takePicture(
            outputOptions,
            ContextCompat.getMainExecutor(this),
            object : ImageCapture.OnImageSavedCallback {
                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "Chụp ảnh đơn hàng thất bại", exception)
                    resetScanner("Chụp ảnh lỗi, hãy quét lại")
                }

                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val capturedAt = System.currentTimeMillis()
                    scanMessageView.text = "Đã quét $orderCode\nĐang tối ưu ảnh..."
                    try {
                        cameraExecutor.execute {
                            val savedFile = try {
                                optimizeCapturedImage(rawFile, outputFile)
                            } catch (error: Exception) {
                                Log.w(TAG, "Không nén được ảnh, giữ ảnh gốc", error)
                                rawFile
                            }
                            val appContext = applicationContext
                            val previousPath = PaymentTrackingStore.findRecord(appContext, sessionId)
                                ?.optString("imagePath")
                                .orEmpty()
                            PaymentTrackingStore.setOrderCapture(
                                appContext,
                                sessionId,
                                orderCode,
                                savedFile.absolutePath,
                                capturedAt
                            )
                            if (previousPath.isNotBlank() && previousPath != savedFile.absolutePath) {
                                File(previousPath).delete()
                            }
                            runOnUiThread {
                                if (!isFinishing && !isDestroyed) showCapturedResult(savedFile, orderCode)
                            }
                        }
                    } catch (error: RejectedExecutionException) {
                        PaymentTrackingStore.setOrderCapture(
                            applicationContext,
                            sessionId,
                            orderCode,
                            rawFile.absolutePath,
                            capturedAt
                        )
                        if (!isFinishing && !isDestroyed) showCapturedResult(rawFile, orderCode)
                    }
                }
            }
        )
    }

    private fun optimizeCapturedImage(sourceFile: File, outputFile: File): File {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(sourceFile.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalStateException("Không đọc được ảnh vừa chụp")
        }

        var sampleSize = 1
        while (maxOf(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize)
            > MAX_STORED_IMAGE_SIDE * 3 / 2) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        val decoded = BitmapFactory.decodeFile(sourceFile.absolutePath, options)
            ?: throw IllegalStateException("Không giải mã được ảnh vừa chụp")

        var bitmap = decoded
        try {
            val rotation = try {
                ExifInterface(sourceFile).rotationDegrees
            } catch (_: Exception) {
                0
            }
            if (rotation != 0) {
                val rotated = Bitmap.createBitmap(
                    bitmap, 0, 0, bitmap.width, bitmap.height,
                    Matrix().apply { postRotate(rotation.toFloat()) }, true
                )
                if (rotated !== bitmap) bitmap.recycle()
                bitmap = rotated
            }

            val longestSide = maxOf(bitmap.width, bitmap.height)
            if (longestSide > MAX_STORED_IMAGE_SIDE) {
                val scale = MAX_STORED_IMAGE_SIDE.toFloat() / longestSide
                val scaled = Bitmap.createScaledBitmap(
                    bitmap,
                    maxOf(1, (bitmap.width * scale).toInt()),
                    maxOf(1, (bitmap.height * scale).toInt()),
                    true
                )
                if (scaled !== bitmap) bitmap.recycle()
                bitmap = scaled
            }

            val temporaryFile = File(outputFile.parentFile, ".${outputFile.name}.tmp")
            try {
                temporaryFile.outputStream().use { output ->
                    if (!bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, output)) {
                        throw IllegalStateException("Không nén được ảnh đơn hàng")
                    }
                    output.flush()
                }

                if (temporaryFile.length() >= sourceFile.length()) {
                    temporaryFile.delete()
                    if (outputFile.exists()) outputFile.delete()
                    return if (sourceFile.renameTo(outputFile)) outputFile else sourceFile
                }
                if (outputFile.exists() && !outputFile.delete()) {
                    throw IllegalStateException("Không thay thế được ảnh đơn hàng cũ")
                }
                if (!temporaryFile.renameTo(outputFile)) {
                    throw IllegalStateException("Không hoàn tất được ảnh đã nén")
                }
                val originalLength = sourceFile.length()
                sourceFile.delete()
                Log.i(TAG, "Ảnh đơn hàng: $originalLength → ${outputFile.length()} bytes")
                return outputFile
            } finally {
                temporaryFile.delete()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun showCapturedResult(imageFile: File, orderCode: String) {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        cameraProvider?.unbindAll()
        imageCapture = null
        imageAnalysis = null
        previewFrame.visibility = View.GONE
        resultPanel.visibility = View.VISIBLE
        previewBitmap?.recycle()
        previewBitmap = null
        resultImage.setImageDrawable(null)
        if (!isFinishing && !isDestroyed) {
            try {
                cameraExecutor.execute {
                    val decodedPreview = decodeResultPreview(imageFile)
                    runOnUiThread {
                        if (decodedPreview == null) return@runOnUiThread
                        if (isFinishing || isDestroyed || resultPanel.visibility != View.VISIBLE) {
                            decodedPreview.recycle()
                        } else {
                            previewBitmap?.recycle()
                            previewBitmap = decodedPreview
                            resultImage.setImageBitmap(decodedPreview)
                        }
                    }
                }
            } catch (_: RejectedExecutionException) {
                // The activity may be closing while CameraX finishes its capture callback.
            }
        }
        statusHandler.removeCallbacks(refreshSmsStatus)
        smsStatusPollAttempts = 0
        val status = readSmsStatus()
        resultStatus.text = status.second
        if (status.first == "sending") statusHandler.postDelayed(refreshSmsStatus, 1000)
        orderCodeView.text = "Mã đơn: $orderCode"
        val lastFour = phone.filter { it.isDigit() }.takeLast(4)
        phoneView.text = "4 số cuối SĐT: ${if (lastFour.isEmpty()) "----" else lastFour}"
        smsMessageView.text = smsMessage.ifBlank { "(Không có nội dung)" }
    }

    private fun resumeScanning() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        captureStarted.set(false)
        previewBitmap?.recycle()
        previewBitmap = null
        resultImage.setImageDrawable(null)
        resultPanel.visibility = View.GONE
        previewFrame.visibility = View.VISIBLE
        scanMessageView.text = "Đưa mã vào khung để quét"
        startCamera()
    }

    private fun decodeResultPreview(imageFile: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(imageFile.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sampleSize = 1
        val maxPreviewSide = 1400
        while (maxOf(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize)
            > maxPreviewSide * 3 / 2) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        val decoded = BitmapFactory.decodeFile(imageFile.absolutePath, options) ?: return null
        val rotation = try {
            ExifInterface(imageFile).rotationDegrees
        } catch (_: Exception) {
            0
        }
        if (rotation == 0) return decoded
        val rotated = Bitmap.createBitmap(
            decoded, 0, 0, decoded.width, decoded.height,
            Matrix().apply { postRotate(rotation.toFloat()) }, true
        )
        if (rotated !== decoded) decoded.recycle()
        return rotated
    }

    private fun resetScanner(message: String) {
        captureStarted.set(false)
        runOnUiThread {
            scanMessageView.text = message
            imageAnalysis?.setAnalyzer(cameraExecutor) { imageProxy -> analyzeFrame(imageProxy) }
        }
    }

    private fun readSmsStatus(): Pair<String, String> {
        val status = PaymentTrackingStore.findRecord(this, sessionId)?.optString("smsStatus")
        val message = when (status) {
            "sent" -> "SMS đã được gửi lên mạng · Ảnh lưu trên thiết bị"
            "simulated" -> "SMS ảo đã nằm trong mục Đã gửi, khách không nhận · Ảnh lưu trên thiết bị"
            "failed" -> "SMS gửi thất bại · Ảnh đã lưu, hãy kiểm tra trước khi dùng"
            else -> "Đang chờ kết quả gửi SMS · Ảnh lưu trên thiết bị"
        }
        return Pair(status ?: "sending", message)
    }

    private fun resultText(
        text: String,
        sizeSp: Float,
        color: Int,
        bold: Boolean = false
    ): TextView = TextView(this).apply {
        this.text = text
        textSize = sizeSp
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun roundedBackground(color: Int, radiusDp: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        statusHandler.removeCallbacks(refreshSmsStatus)
        cameraProvider?.unbindAll()
        if (barcodeScannerDelegate.isInitialized()) barcodeScanner.close()
        previewBitmap?.recycle()
        previewBitmap = null
        cameraExecutor.shutdown()
        super.onDestroy()
    }
}
