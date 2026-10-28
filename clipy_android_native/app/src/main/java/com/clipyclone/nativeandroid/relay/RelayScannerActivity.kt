package com.clipyclone.nativeandroid.relay

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.clipyclone.nativeandroid.ui.*
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.CameraPreview
import com.journeyapps.barcodescanner.camera.CenterCropStrategy

/** Same app bar and full-frame camera surface as the existing invitation scanner. */
class RelayScannerActivity : ComponentActivity() {
    private var completed = false
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val chinese = intent.getBooleanExtra("chinese", resources.configuration.locales[0].language == "zh")
        val appearance = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).getString("flutter.appearance", "system")
        setContent {
            val dark = when (appearance) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
            CompositionLocalProvider(LocalStrings provides AppStrings(chinese)) { ClipyTheme(dark = dark) { Scanner(chinese) } }
        }
    }
    @Composable private fun Scanner(chinese: Boolean) {
        var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
        var error by remember { mutableStateOf<String?>(null) }
        var view by remember { mutableStateOf<BarcodeView?>(null) }
        val lifecycle = LocalLifecycleOwner.current
        val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
            granted = it; error = if (it) null else "Camera permission denied."
        }
        LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
        DisposableEffect(lifecycle, view) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_RESUME) {
                    val nowGranted = ContextCompat.checkSelfPermission(this@RelayScannerActivity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                    if (nowGranted && !granted) error = null
                    else if (!nowGranted && granted) error = "Camera permission denied."
                    granted = nowGranted
                    if (granted && !completed) view?.resume()
                } else if (event == Lifecycle.Event.ON_PAUSE) view?.pause()
            }
            lifecycle.lifecycle.addObserver(observer)
            if (lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) && granted && !completed) view?.resume()
            onDispose { lifecycle.lifecycle.removeObserver(observer); view?.pause() }
        }
        Scaffold(containerColor = MaterialTheme.colorScheme.background, contentWindowInsets = WindowInsets(0, 0, 0, 0), topBar = {
            SecondaryAppBar(if (chinese) "扫描邀请二维码" else "Scan invitation", { finish() })
        }) { padding ->
            Box(Modifier.fillMaxSize().padding(padding).background(Color.Black), contentAlignment = Alignment.Center) {
                if (granted) AndroidView(factory = { context ->
                    object : BarcodeView(context) {
                        override fun calculateFramingRect(container: Rect, surface: Rect): Rect = Rect(container).apply { intersect(surface) }
                    }.apply {
                        previewScalingStrategy = CenterCropStrategy()
                        addStateListener(object : CameraPreview.StateListener {
                            override fun previewSized() { }
                            override fun previewStarted() { error = null }
                            override fun previewStopped() { }
                            override fun cameraClosed() { }
                            override fun cameraError(exception: Exception) { error = "An unexpected error occurred." }
                        })
                        decodeContinuous(object : BarcodeCallback {
                            override fun barcodeResult(result: BarcodeResult?) {
                                val value = result?.text ?: return
                                if (!completed && value.startsWith("common-relay://")) {
                                    completed = true; pause()
                                    setResult(RESULT_OK, Intent().putExtra("invitation", value)); finish()
                                }
                            }
                        })
                        view = this
                    }
                }, modifier = Modifier.fillMaxSize())
                error?.let { detail ->
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        ClipyIcon(ClipyIcons.error, color = Color.White)
                        Spacer(Modifier.height(16.dp))
                        Text(detail, color = Color.White)
                    }
                }
            }
        }
    }
}
