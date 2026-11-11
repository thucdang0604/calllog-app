package com.example.call_log_manager

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaActionSound
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class BarcodeScanActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "BarcodeScanActivity"
        private const val CAMERA_PERMISSION_REQUEST = 3001
        private const val DEBOUNCE_SAME_CODE_MS = 1500L

        private val barcodeScannerOptions = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_CODE_39,
                Barcode.FORMAT_CODE_93,
                Barcode.FORMAT_CODABAR,
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
    }

    private lateinit var previewView: PreviewView
    private lateinit var btnClose: ImageButton
    private lateinit var btnFlash: ImageButton
    private lateinit var tvLastScanned: TextView
    private lateinit var tvCounter: TextView
    private lateinit var btnDone: Button
    private lateinit var laserLine: View

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var isTorchOn = false
    private val isAnalyzing = AtomicBoolean(false)
    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
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
        btnClose = findViewById(R.id.btn_barcode_close)
        btnFlash = findViewById(R.id.btn_barcode_flash)
        tvLastScanned = findViewById(R.id.tv_last_scanned)
        tvCounter = findViewById(R.id.tv_barcode_counter)
        btnDone = findViewById(R.id.btn_barcode_done)
        laserLine = findViewById(R.id.laser_line)

        btnClose.setOnClickListener {
            finishWithResult()
        }

        btnDone.setOnClickListener {
            finishWithResult()
        }

        btnFlash.setOnClickListener {
            toggleFlash()
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

                val analysis = ImageAnalysis.Builder()
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
            } catch (error: Exception) {
                Log.e(TAG, "Lỗi khởi tạo camera quét", error)
                Toast.makeText(this, "Không thể mở camera: ${error.message}", Toast.LENGTH_SHORT).show()
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeFrame(imageProxy: androidx.camera.core.ImageProxy) {
        if (!isAnalyzing.compareAndSet(false, true)) {
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
            val inputImage = InputImage.fromMediaImage(
                mediaImage,
                imageProxy.imageInfo.rotationDegrees
            )

            barcodeScanner.process(inputImage)
                .addOnSuccessListener { barcodes ->
                    for (barcode in barcodes) {
                        val raw = barcode.rawValue?.trim()
                        if (!raw.isNullOrEmpty()) {
                            val formatName = getFormatName(barcode.format)
                            handleBarcodeDetected(raw, formatName)
                            break
                        }
                    }
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

    private fun handleBarcodeDetected(rawCode: String, format: String) {
        val now = System.currentTimeMillis()
        if (rawCode == lastScannedCode && (now - lastScannedTime) < DEBOUNCE_SAME_CODE_MS) {
            return
        }

        lastScannedCode = rawCode
        lastScannedTime = now

        // Check if duplicate in the whole current session
        val isDuplicate = scannedCodesList.any { it.optString("code") == rawCode }
        if (!isDuplicate) {
            val obj = JSONObject().apply {
                put("code", rawCode)
                put("format", format)
                put("timestamp", now)
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
            Barcode.FORMAT_CODABAR -> "Codabar"
            Barcode.FORMAT_EAN_13 -> "EAN-13"
            Barcode.FORMAT_EAN_8 -> "EAN-8"
            Barcode.FORMAT_UPC_A -> "UPC-A"
            Barcode.FORMAT_UPC_E -> "UPC-E"
            Barcode.FORMAT_ITF -> "ITF"
            Barcode.FORMAT_PDF417 -> "PDF417"
            Barcode.FORMAT_AZTEC -> "Aztec"
            Barcode.FORMAT_DATA_MATRIX -> "Data Matrix"
            else -> "Mã vạch"
        }
    }

    private fun finishWithResult() {
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
        cameraExecutor.shutdown()
        barcodeScanner.close()
        super.onDestroy()
    }
}

