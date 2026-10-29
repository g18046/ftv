package com.example.ftv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.URL
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private val CHANNEL_NAME = "com.example.ftv/pip_and_session"
    private val NOTIFICATION_CHANNEL_ID = "ftv_media_playback"
    private val NOTIFICATION_ID = 9978

    private val ACTION_PREV = "com.example.ftv.ACTION_PREV"
    private val ACTION_PLAY_PAUSE = "com.example.ftv.ACTION_PLAY_PAUSE"
    private val ACTION_NEXT = "com.example.ftv.ACTION_NEXT"

    private var methodChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null
    private var notificationManager: NotificationManager? = null

    private var autoPipEnabled = false
    private var pipNumerator = 16
    private var pipDenominator = 9

    private var isPlayingState = false
    private var lastTitle = ""
    private var lastEpisode = ""
    private var lastCoverBitmap: Bitmap? = null

    private val mediaActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PREV -> methodChannel?.invokeMethod("onPrevious", null)
                ACTION_PLAY_PAUSE -> methodChannel?.invokeMethod("onPlayPause", null)
                ACTION_NEXT -> methodChannel?.invokeMethod("onNext", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enableAutoPip" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val num = call.argument<Int>("numerator") ?: 16
                    val den = call.argument<Int>("denominator") ?: 9
                    autoPipEnabled = enabled
                    pipNumerator = num
                    pipDenominator = den
                    setupAutoPipParams()
                    result.success(true)
                }
                "enterPip" -> {
                    val num = call.argument<Int>("numerator") ?: pipNumerator
                    val den = call.argument<Int>("denominator") ?: pipDenominator
                    val success = enterPipMode(num, den)
                    result.success(success)
                }
                "updateMediaSession" -> {
                    val title = call.argument<String>("title") ?: ""
                    val episode = call.argument<String>("episode") ?: ""
                    val coverUrl = call.argument<String>("coverUrl") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val pos = call.argument<Int>("positionSec") ?: 0
                    val dur = call.argument<Int>("durationSec") ?: 0
                    updateMediaSessionCard(title, episode, coverUrl, isPlaying, pos.toLong(), dur.toLong())
                    result.success(true)
                }
                "closeMediaSession" -> {
                    closeMediaSessionCard()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        initMediaSession()
        createNotificationChannel()

        val filter = IntentFilter().apply {
            addAction(ACTION_PREV)
            addAction(ACTION_PLAY_PAUSE)
            addAction(ACTION_NEXT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(mediaActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(mediaActionReceiver, filter)
        }
    }

    private fun setupAutoPipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val validNum = pipNumerator.coerceAtLeast(1)
            val validDen = pipDenominator.coerceAtLeast(1)
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(validNum, validDen))
                .setAutoEnterEnabled(autoPipEnabled)
                .build()
            setPictureInPictureParams(params)
        }
    }

    private fun enterPipMode(num: Int, den: Int): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return try {
                val validNum = num.coerceAtLeast(1)
                val validDen = den.coerceAtLeast(1)
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(validNum, validDen))
                    .build()
                enterPictureInPictureMode(params)
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // 针对 Android 8.0 ~ 11 设备手势上滑退至后台时自动进入画中画
        if (autoPipEnabled && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            enterPipMode(pipNumerator, pipDenominator)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "影视媒体播放服务"
            val desc = "在通知中心与锁屏展示媒体播控卡片"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(NOTIFICATION_CHANNEL_ID, name, importance).apply {
                description = desc
                setShowBadge(false)
            }
            notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager?.createNotificationChannel(channel)
        } else {
            notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        }
    }

    private fun initMediaSession() {
        mediaSession = MediaSession(this, "FTV_MediaSession").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    methodChannel?.invokeMethod("onPlay", null)
                }
                override fun onPause() {
                    methodChannel?.invokeMethod("onPause", null)
                }
                override fun onSkipToNext() {
                    methodChannel?.invokeMethod("onNext", null)
                }
                override fun onSkipToPrevious() {
                    methodChannel?.invokeMethod("onPrevious", null)
                }
                override fun onSeekTo(pos: Long) {
                    methodChannel?.invokeMethod("onSeekTo", (pos / 1000).toInt())
                }
            })
            isActive = true
        }
    }

    private fun updateMediaSessionCard(
        title: String,
        episode: String,
        coverUrl: String,
        isPlaying: Boolean,
        positionSec: Long,
        durationSec: Long
    ) {
        val session = mediaSession ?: return
        isPlayingState = isPlaying
        lastTitle = title
        lastEpisode = episode

        val posMs = positionSec * 1000L
        val durMs = durationSec * 1000L

        val state = if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
        val stateBuilder = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or
                PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                PlaybackState.ACTION_SEEK_TO
            )
            .setState(state, posMs, 1.0f)
        session.setPlaybackState(stateBuilder.build())

        val metaBuilder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, episode)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durMs)

        if (coverUrl.isNotEmpty()) {
            thread {
                try {
                    val url = URL(coverUrl)
                    val bmp = BitmapFactory.decodeStream(url.openStream())
                    if (bmp != null) {
                        lastCoverBitmap = bmp
                        metaBuilder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bmp)
                        session.setMetadata(metaBuilder.build())
                        postNotification(title, episode, isPlaying, bmp)
                    }
                } catch (_: Exception) {
                    session.setMetadata(metaBuilder.build())
                    postNotification(title, episode, isPlaying, lastCoverBitmap)
                }
            }
        } else {
            session.setMetadata(metaBuilder.build())
            postNotification(title, episode, isPlaying, lastCoverBitmap)
        }
    }

    private fun postNotification(title: String, episode: String, isPlaying: Boolean, iconBmp: Bitmap?) {
        val session = mediaSession ?: return

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val prevIntent = PendingIntent.getBroadcast(
            this,
            1,
            Intent(ACTION_PREV).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val playPauseIntent = PendingIntent.getBroadcast(
            this,
            2,
            Intent(ACTION_PLAY_PAUSE).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val nextIntent = PendingIntent.getBroadcast(
            this,
            3,
            Intent(ACTION_NEXT).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notifBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        notifBuilder
            .setContentTitle(title)
            .setContentText(episode)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(isPlaying)

        if (iconBmp != null) {
            notifBuilder.setLargeIcon(iconBmp)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            notifBuilder.style = Notification.MediaStyle()
                .setMediaSession(session.sessionToken)
                .setShowActionsInCompactView(0, 1, 2)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            notifBuilder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_media_previous),
                    "上一集",
                    prevIntent
                ).build()
            )
            notifBuilder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(
                        this,
                        if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
                    ),
                    if (isPlaying) "暂停" else "播放",
                    playPauseIntent
                ).build()
            )
            notifBuilder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_media_next),
                    "下一集",
                    nextIntent
                ).build()
            )
        } else {
            notifBuilder.addAction(android.R.drawable.ic_media_previous, "上一集", prevIntent)
            notifBuilder.addAction(
                if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (isPlaying) "暂停" else "播放",
                playPauseIntent
            )
            notifBuilder.addAction(android.R.drawable.ic_media_next, "下一集", nextIntent)
        }

        notificationManager?.notify(NOTIFICATION_ID, notifBuilder.build())
    }

    private fun closeMediaSessionCard() {
        notificationManager?.cancel(NOTIFICATION_ID)
        mediaSession?.isActive = false
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(mediaActionReceiver)
        } catch (_: Exception) {}
        closeMediaSessionCard()
        mediaSession?.release()
        super.onDestroy()
    }
}
