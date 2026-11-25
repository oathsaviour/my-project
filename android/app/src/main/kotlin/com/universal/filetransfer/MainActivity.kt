package com.universal.filetransfer

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.universal.filetransfer/native"
    private var multicastLock: WifiManager.MulticastLock? = null
    private var cpuWakeLock: PowerManager.WakeLock? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Multicast Lock for reliable mDNS packet reception
                "acquireMulticastLock" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        if (multicastLock == null) {
                            multicastLock = wifiManager.createMulticastLock("universal_share_multicast_lock")
                            multicastLock?.setReferenceCounted(true)
                        }
                        if (multicastLock?.isHeld == false) {
                            multicastLock?.acquire()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to acquire multicast lock: ${e.message}", null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        if (multicastLock?.isHeld == true) {
                            multicastLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCK_ERROR", "Failed to release multicast lock: ${e.message}", null)
                    }
                }

                // Wake Lock: Keep CPU & Screen awake during multi-gigabyte transfers
                "acquireWakeLock" -> {
                    try {
                        // 1. Keep Screen Awake on UI thread
                        activity.runOnUiThread {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }

                        // 2. Acquire CPU Partial WakeLock (prevents Android Doze mode CPU suspension)
                        val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (cpuWakeLock == null) {
                            cpuWakeLock = powerManager.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK,
                                "UniversalTransfer:ActiveTransferCpuWakeLock"
                            )
                            cpuWakeLock?.setReferenceCounted(false)
                        }
                        if (cpuWakeLock?.isHeld == false) {
                            // 2-hour safety timeout to prevent permanent battery drain if app crashes
                            cpuWakeLock?.acquire(2 * 60 * 60 * 1000L)
                        }

                        // 3. Start Foreground Service so Android does not kill sockets when app goes to background
                        val reason = call.argument<String>("reason") ?: "Transferring files..."
                        val serviceIntent = Intent(applicationContext, TransferForegroundService::class.java).apply {
                            putExtra(TransferForegroundService.EXTRA_REASON, reason)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            applicationContext.startForegroundService(serviceIntent)
                        } else {
                            applicationContext.startService(serviceIntent)
                        }

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", "Failed to acquire wake lock: ${e.message}", null)
                    }
                }
                "releaseWakeLock" -> {
                    try {
                        // 1. Clear Screen On Flag
                        activity.runOnUiThread {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }

                        // 2. Release CPU WakeLock
                        if (cpuWakeLock?.isHeld == true) {
                            cpuWakeLock?.release()
                        }

                        // 3. Stop Foreground Service
                        applicationContext.stopService(Intent(applicationContext, TransferForegroundService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", "Failed to release wake lock: ${e.message}", null)
                    }
                }

                // Scoped Storage: Save raw documents/APKs to Downloads/UniversalShare via MediaStore API
                // Fully compliant with Android 10, 11, 12, 13, 14, 15, and 16+ WITHOUT MANAGE_EXTERNAL_STORAGE!
                "saveToDownloads" -> {
                    val tempPath = call.argument<String>("tempPath")
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"

                    if (tempPath == null || fileName == null) {
                        result.error("INVALID_ARGS", "tempPath and fileName are required", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val destination = saveFileUsingMediaStore(tempPath, fileName, mimeType, isMedia = false, isVideo = false)
                            runOnUiThread { result.success(destination) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", "Failed to save file to Downloads: ${e.message}", null) }
                        }
                    }
                }

                // Scoped Storage: Save photos/videos to Pictures/Movies via MediaStore API
                "saveMediaToGallery" -> {
                    val tempPath = call.argument<String>("tempPath")
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                    val isVideo = call.argument<Boolean>("isVideo") ?: false

                    if (tempPath == null || fileName == null) {
                        result.error("INVALID_ARGS", "tempPath and fileName are required", null)
                        return@setMethodCallHandler
                    }

                    ioExecutor.execute {
                        try {
                            val destination = saveFileUsingMediaStore(tempPath, fileName, mimeType, isMedia = true, isVideo = isVideo)
                            runOnUiThread { result.success(destination) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", "Failed to save media to Gallery: ${e.message}", null) }
                        }
                    }
                }

                "scanMediaFile" -> {
                    val filePath = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType")
                    if (filePath != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(filePath),
                            if (mimeType != null) arrayOf(mimeType) else null
                        ) { _, _ -> }
                        result.success(true)
                    } else {
                        result.error("INVALID_PATH", "File path cannot be null", null)
                    }
                }

                "getUniversalShareDirectory" -> {
                    val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    val shareDir = File(downloadDir, "UniversalShare")
                    if (!shareDir.exists()) {
                        shareDir.mkdirs()
                    }
                    result.success(shareDir.absolutePath)
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Saves a temporary file into public storage using Android MediaStore Scoped Storage API.
     * Uses MediaStore.Downloads for documents/APKs and MediaStore.Images/Video for media.
     * Works on Android 10-16+ without requiring MANAGE_EXTERNAL_STORAGE.
     */
    private fun saveFileUsingMediaStore(
        tempPath: String,
        fileName: String,
        mimeType: String,
        isMedia: Boolean,
        isVideo: Boolean
    ): String {
        val sourceFile = File(tempPath)
        if (!sourceFile.exists()) {
            throw IllegalArgumentException("Source file does not exist: $tempPath")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentResolver = applicationContext.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.IS_PENDING, 1)

                val relativePath = if (isMedia) {
                    if (isVideo) Environment.DIRECTORY_MOVIES + "/UniversalShare"
                    else Environment.DIRECTORY_PICTURES + "/UniversalShare"
                } else {
                    Environment.DIRECTORY_DOWNLOADS + "/UniversalShare"
                }
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            }

            val collectionUri: Uri = if (isMedia) {
                if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }

            val targetUri = contentResolver.insert(collectionUri, contentValues)
                ?: throw IllegalStateException("Failed to create MediaStore entry in $collectionUri")

            // Stream file contents into content resolver output stream
            FileInputStream(sourceFile).use { input ->
                contentResolver.openOutputStream(targetUri)?.use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                    output.flush()
                } ?: throw IllegalStateException("Failed to open output stream for $targetUri")
            }

            // Clear IS_PENDING flag so the file becomes immediately visible to all apps
            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(targetUri, contentValues, null, null)

            // Clean up source temp file
            sourceFile.delete()

            return targetUri.toString()
        } else {
            // Legacy Android 9 and below fallback (using traditional File system with MediaScanner)
            val baseDir = if (isMedia) {
                if (isVideo) Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
                else Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            }

            val targetDir = File(baseDir, "UniversalShare")
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }

            var destFile = File(targetDir, fileName)
            if (destFile.exists()) {
                val dot = fileName.lastIndexOf('.')
                val name = if (dot != -1) fileName.substring(0, dot) else fileName
                val ext = if (dot != -1) fileName.substring(dot) else ""
                destFile = File(targetDir, "${name}_${System.currentTimeMillis()}$ext")
            }

            sourceFile.copyTo(destFile, overwrite = true)
            sourceFile.delete()

            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(destFile.absolutePath),
                arrayOf(mimeType),
                null
            )

            return destFile.absolutePath
        }
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) {
            multicastLock?.release()
        }
        if (cpuWakeLock?.isHeld == true) {
            cpuWakeLock?.release()
        }
        super.onDestroy()
    }
}
