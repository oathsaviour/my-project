package com.universal.filetransfer

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.universal.filetransfer/native"
    private var methodChannel: MethodChannel? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var cpuWakeLock: PowerManager.WakeLock? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

    // NSD (Android native mDNS/Bonjour)
    private var nsdManager: NsdManager? = null
    private var nsdRegistrationListener: NsdManager.RegistrationListener? = null
    private var nsdDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var registeredServiceName: String? = null

    // Wi-Fi Direct (P2P)
    private var wifiP2pManager: WifiP2pManager? = null
    private var wifiP2pChannel: WifiP2pManager.Channel? = null
    private var p2pReceiver: BroadcastReceiver? = null
    private var pendingP2pConnectResult: MethodChannel.Result? = null

    // BLE Proximity Discovery
    private val bleServiceUuid = ParcelUuid(UUID.fromString("00005284-0000-1000-8000-00805f9b34fb"))
    private var bleAdvertiser: BluetoothLeAdvertiser? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var bleAdvertiseCallback: AdvertiseCallback? = null
    private var bleScanCallback: ScanCallback? = null

    // Local-Only Hotspot (Offline QR without Router)
    private var localOnlyHotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var hotspotNetworkCallback: ConnectivityManager.NetworkCallback? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkRadioStates" -> {
                    result.success(getRadioStates())
                }

                "openRadioSettings" -> {
                    val radio = call.argument<String>("radio") ?: "wifi"
                    openRadioSettings(radio)
                    result.success(true)
                }

                // Multicast Lock for reliable mDNS / UDP discovery packet reception (ColorOS / Realme UI / MIUI)
                "acquireMulticastLock" -> {
                    try {
                        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        if (multicastLock == null) {
                            multicastLock = wifiManager.createMulticastLock("universal_share_multicast_lock")
                            multicastLock?.setReferenceCounted(false)
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

                // Native Android NSD (mDNS) registration + discovery
                "startNsdDiscovery" -> {
                    val deviceName = call.argument<String>("deviceName") ?: "UniversalDevice"
                    val port = call.argument<Int>("port") ?: 52840
                    startNsd(deviceName, port)
                    result.success(true)
                }
                "stopNsdDiscovery" -> {
                    stopNsd()
                    result.success(true)
                }

                // Offline P2P Discovery (Wi-Fi Direct + BLE)
                "startP2pDiscovery" -> {
                    val deviceName = call.argument<String>("deviceName") ?: "UniversalDevice"
                    startP2pAndBle(deviceName)
                    result.success(true)
                }
                "stopP2pDiscovery" -> {
                    stopP2pAndBle()
                    result.success(true)
                }
                "connectP2pPeer" -> {
                    val deviceAddress = call.argument<String>("deviceAddress")
                    if (deviceAddress.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "deviceAddress is required", null)
                    } else {
                        connectToP2pPeer(deviceAddress, result)
                    }
                }

                // Offline Local-Only Hotspot (for QR pairing without router)
                "startLocalOnlyHotspot" -> {
                    startLocalOnlyHotspot(result)
                }
                "stopLocalOnlyHotspot" -> {
                    stopLocalOnlyHotspot()
                    result.success(true)
                }
                "connectToWifiHotspot" -> {
                    val ssid = call.argument<String>("ssid")
                    val passphrase = call.argument<String>("passphrase")
                    if (ssid.isNullOrEmpty() || passphrase.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "ssid and passphrase are required", null)
                    } else {
                        connectToWifiHotspot(ssid, passphrase, result)
                    }
                }

                // Wake Lock + Foreground Service: Keep CPU, Screen & TCP sockets alive in background
                "acquireWakeLock" -> {
                    try {
                        activity.runOnUiThread {
                            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }

                        val powerManager = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (cpuWakeLock == null) {
                            cpuWakeLock = powerManager.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK,
                                "UniversalTransfer:ActiveTransferCpuWakeLock"
                            )
                            cpuWakeLock?.setReferenceCounted(false)
                        }
                        if (cpuWakeLock?.isHeld == false) {
                            cpuWakeLock?.acquire(2 * 60 * 60 * 1000L)
                        }

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
                        activity.runOnUiThread {
                            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }

                        if (cpuWakeLock?.isHeld == true) {
                            cpuWakeLock?.release()
                        }

                        applicationContext.stopService(Intent(applicationContext, TransferForegroundService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", "Failed to release wake lock: ${e.message}", null)
                    }
                }

                // Scoped Storage: Save raw documents/APKs to Downloads/UniversalShare via MediaStore API
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

    override fun onDestroy() {
        stopNsd()
        stopP2pAndBle()
        stopLocalOnlyHotspot()
        super.onDestroy()
    }

    private fun getRadioStates(): Map<String, Boolean> {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val bluetoothManager = applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val locationManager = applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

        val wifiEnabled = wifiManager?.isWifiEnabled ?: false
        val btEnabled = bluetoothManager?.adapter?.isEnabled ?: false
        val locationEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager?.isLocationEnabled ?: false
        } else {
            (locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true) ||
                (locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true)
        }

        return mapOf(
            "wifi" to wifiEnabled,
            "bluetooth" to btEnabled,
            "location" to locationEnabled
        )
    }

    @SuppressLint("MissingPermission")
    private fun openRadioSettings(radio: String) {
        when (radio) {
            "wifi" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startActivity(Intent(Settings.Panel.ACTION_WIFI))
                } else {
                    startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                }
            }
            "bluetooth" -> {
                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                startActivity(intent)
            }
            "location" -> {
                startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            }
        }
    }

    // --- NSD (Android Native mDNS) ---
    private fun startNsd(deviceName: String, port: Int) {
        stopNsd()
        try {
            nsdManager = applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
            val serviceType = "_universal-share._tcp."

            val serviceInfo = NsdServiceInfo().apply {
                serviceName = deviceName
                this.serviceType = serviceType
                setPort(port)
            }

            nsdRegistrationListener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {
                    registeredServiceName = info.serviceName
                }
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                override fun onServiceUnregistered(arg0: NsdServiceInfo) {}
                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            }
            nsdManager?.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, nsdRegistrationListener)

            nsdDiscoveryListener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(regType: String) {}
                override fun onServiceFound(service: NsdServiceInfo) {
                    if (service.serviceName == registeredServiceName) return
                    nsdManager?.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                        override fun onServiceResolved(resolved: NsdServiceInfo) {
                            val host = resolved.host?.hostAddress ?: return
                            runOnUiThread {
                                methodChannel?.invokeMethod("onNsdPeerFound", mapOf(
                                    "name" to resolved.serviceName,
                                    "ip" to host,
                                    "port" to resolved.port
                                ))
                            }
                        }
                    })
                }
                override fun onServiceLost(service: NsdServiceInfo) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            }
            nsdManager?.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, nsdDiscoveryListener)
        } catch (_: Exception) {}
    }

    private fun stopNsd() {
        try {
            nsdDiscoveryListener?.let { nsdManager?.stopServiceDiscovery(it) }
            nsdRegistrationListener?.let { nsdManager?.unregisterService(it) }
        } catch (_: Exception) {}
        nsdDiscoveryListener = null
        nsdRegistrationListener = null
    }

    // --- Wi-Fi Direct + BLE Offline P2P ---
    @SuppressLint("MissingPermission")
    private fun startP2pAndBle(deviceName: String) {
        stopP2pAndBle()

        // 1. Wi-Fi Direct Discovery
        try {
            wifiP2pManager = applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            wifiP2pChannel = wifiP2pManager?.initialize(applicationContext, mainLooper, null)

            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            }

            p2pReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    when (intent.action) {
                        WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                            wifiP2pManager?.requestPeers(wifiP2pChannel) { peers ->
                                for (device: WifiP2pDevice in peers.deviceList) {
                                    runOnUiThread {
                                        methodChannel?.invokeMethod("onP2pPeerFound", mapOf(
                                            "name" to device.deviceName,
                                            "address" to device.deviceAddress,
                                            "status" to device.status
                                        ))
                                    }
                                }
                            }
                        }
                        WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                            wifiP2pManager?.requestConnectionInfo(wifiP2pChannel) { info: WifiP2pInfo? ->
                                val ownerIp = info?.groupOwnerAddress?.hostAddress
                                if (info?.groupFormed == true && ownerIp != null) {
                                    pendingP2pConnectResult?.success(mapOf(
                                        "groupFormed" to true,
                                        "isGroupOwner" to info.isGroupOwner,
                                        "groupOwnerIp" to ownerIp
                                    ))
                                    pendingP2pConnectResult = null

                                    runOnUiThread {
                                        methodChannel?.invokeMethod("onP2pConnected", mapOf(
                                            "isGroupOwner" to info.isGroupOwner,
                                            "groupOwnerIp" to ownerIp
                                        ))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(p2pReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(p2pReceiver, filter)
            }

            wifiP2pManager?.discoverPeers(wifiP2pChannel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}
                override fun onFailure(reason: Int) {}
            })
        } catch (_: Exception) {}

        // 2. BLE Proximity Advertising & Scanning
        try {
            val btManager = applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = btManager?.adapter
            if (adapter != null && adapter.isEnabled) {
                bleAdvertiser = adapter.bluetoothLeAdvertiser
                bleScanner = adapter.bluetoothLeScanner

                val settings = AdvertiseSettings.Builder()
                    .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                    .setConnectable(false)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                    .build()

                val shortName = deviceName.take(12).toByteArray(Charsets.UTF_8)
                val data = AdvertiseData.Builder()
                    .addServiceUuid(bleServiceUuid)
                    .addServiceData(bleServiceUuid, shortName)
                    .setIncludeDeviceName(false)
                    .build()

                bleAdvertiseCallback = object : AdvertiseCallback() {}
                bleAdvertiser?.startAdvertising(settings, data, bleAdvertiseCallback)

                val scanFilter = ScanFilter.Builder().setServiceUuid(bleServiceUuid).build()
                val scanSettings = ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build()

                bleScanCallback = object : ScanCallback() {
                    override fun onScanResult(callbackType: Int, result: ScanResult) {
                        val serviceBytes = result.scanRecord?.getServiceData(bleServiceUuid)
                        val peerName = serviceBytes?.toString(Charsets.UTF_8)
                            ?: result.device?.name
                            ?: "Nearby BLE Peer"
                        val addr = result.device?.address ?: return
                        runOnUiThread {
                            methodChannel?.invokeMethod("onBlePeerFound", mapOf(
                                "name" to peerName,
                                "address" to addr,
                                "rssi" to result.rssi
                            ))
                        }
                    }
                }
                bleScanner?.startScan(listOf(scanFilter), scanSettings, bleScanCallback)
            }
        } catch (_: Exception) {}
    }

    @SuppressLint("MissingPermission")
    private fun stopP2pAndBle() {
        try {
            p2pReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {}
        p2pReceiver = null

        try {
            bleAdvertiseCallback?.let { bleAdvertiser?.stopAdvertising(it) }
            bleScanCallback?.let { bleScanner?.stopScan(it) }
        } catch (_: Exception) {}
        bleAdvertiseCallback = null
        bleScanCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun connectToP2pPeer(deviceAddress: String, result: MethodChannel.Result) {
        val manager = wifiP2pManager
        val channel = wifiP2pChannel
        if (manager == null || channel == null) {
            result.error("P2P_UNAVAILABLE", "Wi-Fi Direct is not initialized", null)
            return
        }

        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
        }
        pendingP2pConnectResult = result
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                // Result will be resolved when WIFI_P2P_CONNECTION_CHANGED_ACTION delivers groupOwnerIp
            }
            override fun onFailure(reason: Int) {
                pendingP2pConnectResult?.error("P2P_CONNECT_FAILED", "Wi-Fi Direct connect failed ($reason)", null)
                pendingP2pConnectResult = null
            }
        })
    }

    // --- Local-Only Hotspot (Offline QR Pairing Without Router) ---
    @SuppressLint("MissingPermission")
    private fun startLocalOnlyHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("UNSUPPORTED", "LocalOnlyHotspot requires Android 8.0+", null)
            return
        }

        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        localOnlyHotspotReservation?.close()
        localOnlyHotspotReservation = null

        wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                localOnlyHotspotReservation = reservation
                val ssid: String
                val passphrase: String
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val softAp = reservation.softApConfiguration
                    ssid = softAp.ssid ?: ""
                    passphrase = softAp.passphrase ?: ""
                } else {
                    @Suppress("DEPRECATION")
                    val config = reservation.wifiConfiguration
                    @Suppress("DEPRECATION")
                    ssid = config?.SSID ?: ""
                    @Suppress("DEPRECATION")
                    passphrase = config?.preSharedKey ?: ""
                }
                val hotspotIp = findLocalHotspotIp() ?: "192.168.43.1"
                runOnUiThread {
                    result.success(mapOf(
                        "ssid" to ssid,
                        "passphrase" to passphrase,
                        "ip" to hotspotIp
                    ))
                }
            }

            override fun onFailed(reason: Int) {
                runOnUiThread {
                    result.error("HOTSPOT_FAILED", "Local-Only Hotspot failed with code $reason", null)
                }
            }
        }, Handler(Looper.getMainLooper()))
    }

    private fun stopLocalOnlyHotspot() {
        try {
            localOnlyHotspotReservation?.close()
        } catch (_: Exception) {}
        localOnlyHotspotReservation = null
    }

    private fun findLocalHotspotIp(): String? {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                val name = iface.name.lowercase()
                if (name.contains("ap") || name.contains("swlan") || name.contains("wlan")) {
                    val addrs = iface.inetAddresses
                    while (addrs.hasMoreElements()) {
                        val addr = addrs.nextElement()
                        if (!addr.isLoopbackAddress && addr is Inet4Address) {
                            return addr.hostAddress
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }

    private fun connectToWifiHotspot(ssid: String, passphrase: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED", "Programmatic Wi-Fi hotspot join requires Android 10+", null)
            return
        }

        val connectivityManager = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        hotspotNetworkCallback?.let {
            try { connectivityManager.unregisterNetworkCallback(it) } catch (_: Exception) {}
        }

        var completed = false
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                connectivityManager.bindProcessToNetwork(network)
                if (!completed) {
                    completed = true
                    runOnUiThread { result.success(true) }
                }
            }

            override fun onUnavailable() {
                if (!completed) {
                    completed = true
                    runOnUiThread {
                        result.error("WIFI_UNAVAILABLE", "Could not connect to hotspot $ssid", null)
                    }
                }
            }
        }
        hotspotNetworkCallback = callback
        connectivityManager.requestNetwork(request, callback)
    }

    /**
     * Saves a temporary file into public storage using Android MediaStore Scoped Storage API.
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

            FileInputStream(sourceFile).use { input ->
                contentResolver.openOutputStream(targetUri)?.use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                    output.flush()
                } ?: throw IllegalStateException("Failed to open output stream for $targetUri")
            }

            contentValues.clear()
            contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(targetUri, contentValues, null, null)

            sourceFile.delete()
            return targetUri.toString()
        } else {
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

            FileInputStream(sourceFile).use { input ->
                FileOutputStream(destFile).use { output ->
                    input.copyTo(output, bufferSize = 64 * 1024)
                }
            }
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
}
