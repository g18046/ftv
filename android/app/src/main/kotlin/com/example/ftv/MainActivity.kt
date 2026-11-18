package com.example.ftv

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.content.ActivityNotFoundException
import android.net.Uri
import android.os.Bundle
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.example.ftv/pip"
        private const val STORAGE_CHANNEL = "com.example.ftv/storage"
        private const val DOWNLOADER_CHANNEL = "com.example.ftv/downloader"
        private const val REQ_PICK_CONFIG = 9001
    }

    /** 由 Dart 侧按「后台播放 = 画中画」设置下发，默认 false 绝不上滑误入画中画 */
    private var keepPipOnResume = false
    private var isInPip = false
    private var pipChannel: MethodChannel? = null
    private var pipNumerator = 16
    private var pipDenominator = 9
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 存储权限与原生 SAF 文件选择通道：用于 Android 读取本地配置及同级 js/lib 目录
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            result.success(Environment.isExternalStorageManager())
                        } else {
                            result.success(true)
                        }
                    }
                    "requestAllFilesAccess" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (_: Exception) {
                                try {
                                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                                    result.success(true)
                                } catch (_: Exception) {
                                    result.success(false)
                                }
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "pickConfigFile" -> {
                        if (pendingPickResult != null) {
                            result.error("ALREADY_ACTIVE", "文件选择器已在运行中", null)
                            return@setMethodCallHandler
                        }
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        try {
                            startActivityForResult(intent, REQ_PICK_CONFIG)
                        } catch (e: Exception) {
                            pendingPickResult = null
                            result.error("PICK_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchExternalPlayer" -> {
                        val url = call.argument<String>("url") ?: ""
                        val title = call.argument<String>("title") ?: ""
                        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                        if (url.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(Uri.parse(url), "video/*")
                                if (title.isNotEmpty()) putExtra("title", title)
                                if (headers.isNotEmpty()) {
                                    val headerArray = ArrayList<String>()
                                    for ((k, v) in headers) {
                                        headerArray.add(k)
                                        headerArray.add(v)
                                    }
                                    putExtra("headers", headerArray.toTypedArray())
                                    headers["User-Agent"]?.let { putExtra("user_agent", it) }
                                    headers["Referer"]?.let { putExtra("referer", it) }
                                    headers["Cookie"]?.let { putExtra("cookie", it) }
                                }
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            val chooser = Intent.createChooser(intent, "选择外部播放器")
                            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(chooser)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "getUidRxBytes" -> {
                        val rx = android.net.TrafficStats.getUidRxBytes(android.os.Process.myUid())
                        result.success(if (rx >= 0) rx else 0L)
                    }
                    "launchIdmPlus" -> {
                        val url = call.argument<String>("url") ?: ""
                        val filename = call.argument<String>("filename") ?: ""
                        val headersMap = call.argument<Map<String, Any?>>("headers") ?: emptyMap()
                        if (url.isEmpty()) {
                            result.success(mapOf("ok" to false, "error" to "下载地址为空"))
                            return@setMethodCallHandler
                        }

                        val headerBundle = Bundle()
                        val headerList = ArrayList<String>()
                        var uaVal: String? = null
                        var cookieVal: String? = null
                        var refererVal: String? = null
                        for ((k, v) in headersMap) {
                            if (v != null) {
                                val valStr = v.toString()
                                headerBundle.putString(k, valStr)
                                headerList.add("$k: $valStr")
                                when (k.lowercase()) {
                                    "user-agent" -> uaVal = valStr
                                    "cookie" -> cookieVal = valStr
                                    "referer" -> refererVal = valStr
                                }
                            }
                        }

                        fun buildIntent(pkg: String?): Intent {
                            return Intent(Intent.ACTION_VIEW).apply {
                                data = Uri.parse(url)
                                if (pkg != null) setPackage(pkg)
                                if (filename.isNotEmpty()) {
                                    putExtra("extra_filename", filename)
                                    putExtra("title", filename)
                                }
                                if (!headerBundle.isEmpty) {
                                    putExtra("extra_headers", headerBundle)
                                    putExtra("android.media.intent.extra.HTTP_HEADERS", headerBundle)
                                    putExtra("headers", headerList.toTypedArray())
                                    if (!uaVal.isNullOrEmpty()) putExtra("extra_useragent", uaVal)
                                    if (!cookieVal.isNullOrEmpty()) putExtra("extra_cookies", cookieVal)
                                    if (!refererVal.isNullOrEmpty()) putExtra("extra_referer", refererVal)
                                }
                                putExtra("secure_uri", true)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        }

                        val pkgs = listOf(
                            "idm.internet.download.manager.plus",
                            "idm.internet.download.manager",
                            "idm.internet.download.manager.adm.lite"
                        )
                        var launchedPkg: String? = null
                        for (pkg in pkgs) {
                            try {
                                startActivity(buildIntent(pkg))
                                launchedPkg = pkg
                                break
                            } catch (_: ActivityNotFoundException) {
                            } catch (_: Exception) {
                            }
                        }

                        if (launchedPkg != null) {
                            result.success(mapOf("ok" to true, "package" to launchedPkg))
                        } else {
                            try {
                                val chooser = Intent.createChooser(buildIntent(null), "选择下载器").apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(chooser)
                                result.success(mapOf("ok" to true, "package" to "chooser"))
                            } catch (e: Exception) {
                                result.success(mapOf("ok" to false, "error" to (e.message ?: "未找到 IDM+ 或可用下载器")))
                            }
                        }
                    }
                    "openInBrowser" -> {
                        val url = call.argument<String>("url") ?: ""
                        try {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "getAppVersion" -> {
                        try {
                            val pInfo = packageManager.getPackageInfo(packageName, 0)
                            result.success(pInfo.versionName ?: "1.0.0")
                        } catch (_: Exception) {
                            result.success("1.0.0")
                        }
                    }
                    "getBatteryInfo" -> {
                        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                        val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                        val status = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS) ?: -1
                        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                            status == BatteryManager.BATTERY_STATUS_FULL
                        result.success(mapOf("level" to level, "charging" to charging))
                    }
                    "setScreenBrightness" -> {
                        val b = (call.argument<Double>("brightness") ?: -1.0).toFloat()
                        runOnUiThread {
                            val lp = window.attributes
                            lp.screenBrightness = if (b < 0f) -1f else b.coerceIn(0.01f, 1.0f)
                            window.attributes = lp
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    result.success(false)
                    return@setMethodCallHandler
                }

                val w = call.argument<Int>("numerator") ?: 16
                val h = call.argument<Int>("denominator") ?: 9
                pipNumerator = if (w > 0) w else 16
                pipDenominator = if (h > 0) h else 9

                when (call.method) {
                    "enterPip" -> {
                        try {
                            result.success(enterPictureInPictureMode(buildPipParams()))
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "enableAutoPip" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        keepPipOnResume = call.argument<Boolean>("keepOnResume") ?: false
                        try {
                            setPictureInPictureParams(buildPipParams(autoEnter = enabled))
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PICK_CONFIG) {
            val callback = pendingPickResult
            pendingPickResult = null
            if (callback == null) return

            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                callback.success(null)
                return
            }

            val uri = data.data!!
            try {
                val realPath = resolveRealPathFromUri(uri)
                val name = queryDisplayName(uri) ?: "config.json"
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                callback.success(
                    mapOf(
                        "path" to realPath,
                        "name" to name,
                        "bytes" to bytes
                    )
                )
            } catch (e: Exception) {
                callback.error("READ_ERROR", e.message, null)
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        } catch (_: Exception) {}
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun resolveRealPathFromUri(uri: Uri): String? {
        try {
            if ("file".equals(uri.scheme, ignoreCase = true)) {
                return uri.path
            }
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val docId = DocumentsContract.getDocumentId(uri)
                val authority = uri.authority ?: ""
                if (authority == "com.android.externalstorage.documents") {
                    val split = docId.split(":")
                    if (split.size >= 2 && "primary".equals(split[0], ignoreCase = true)) {
                        val rel = docId.substringAfter(":").trimStart('/')
                        return "${Environment.getExternalStorageDirectory().absolutePath}/$rel"
                    }
                } else if (authority == "com.android.providers.downloads.documents") {
                    if (docId.startsWith("raw:")) {
                        return docId.removePrefix("raw:")
                    }
                }
            }
            val decoded = Uri.decode(uri.toString())
            val primaryIdx = decoded.indexOf("primary:")
            if (primaryIdx >= 0) {
                val rel = decoded.substring(primaryIdx + "primary:".length).trimStart('/')
                return "${Environment.getExternalStorageDirectory().absolutePath}/$rel"
            }
            val storageIdx = decoded.indexOf("/storage/")
            if (storageIdx >= 0) {
                return decoded.substring(storageIdx)
            }
        } catch (_: Exception) {}
        return null
    }

    /** 构建原生标准画中画参数：画面宽高比、Android 12+ 手势自动进入 (由系统原生提供单一大全屏展开按键，绝无双重重复按钮) */
    private fun buildPipParams(autoEnter: Boolean = keepPipOnResume): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(safeAspectRatio())

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnter)
        }
        return builder.build()
    }

    private fun safeAspectRatio(): Rational {
        val ratio = pipNumerator.toDouble() / pipDenominator.toDouble()
        // 系统限制 PiP 宽高比约在 0.418 ~ 2.39，超出会抛 IllegalArgumentException
        return if (ratio in 0.42..2.38) {
            Rational(pipNumerator, pipDenominator)
        } else {
            Rational(16, 9)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 针对 Android 8.0 ~ 11 设备手势上滑退至后台时，严格根据设置开关判定是否进入画中画
        if (keepPipOnResume && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                enterPictureInPictureMode(buildPipParams())
            } catch (_: Exception) {
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        isInPip = isInPictureInPictureMode
        pipChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
        // 点击画中画中央的系统全屏展开按钮时，系统原生流畅展开并回到前台播放页面，绝不强行拦截弹回
    }
}
