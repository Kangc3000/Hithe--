package com.kangatnewyork.visioncompanion.relay

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.widget.ArrayAdapter
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.kangatnewyork.visioncompanion.relay.databinding.ActivityMainBinding
import com.kangatnewyork.visioncompanion.relay.net.RelayClient
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

class MainActivity : AppCompatActivity() {

    private val tag = "Activity"
    private lateinit var binding: ActivityMainBinding
    private lateinit var settings: Settings

    private val requiredPerms: Array<String> by lazy {
        val list = mutableListOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.CAMERA,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list += Manifest.permission.POST_NOTIFICATIONS
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list += Manifest.permission.BLUETOOTH_CONNECT
            list += Manifest.permission.BLUETOOTH_SCAN
        }
        list.toTypedArray()
    }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            val granted = result.all { it.value }
            Logger.i(tag, "permissions granted=$granted detail=$result")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        settings = Settings(applicationContext)
        Logger.init(applicationContext, settings.logLevel)
        Logger.i(tag, "onCreate")

        bindUi()
        maybeRequestPermissions()
    }

    private fun bindUi() {
        binding.serverUrlField.setText(settings.serverUrl)
        binding.imageFpsField.setText(settings.imageFps.toString())

        when (settings.transport) {
            Settings.Transport.PHONE -> binding.transportPhone.isChecked = true
            Settings.Transport.META  -> binding.transportMeta.isChecked = true
        }

        val levels = Logger.Level.values().map { it.name }
        binding.logLevelSpinner.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_dropdown_item, levels
        )
        binding.logLevelSpinner.setSelection(levels.indexOf(settings.logLevel.name).coerceAtLeast(0))

        binding.startStopBtn.setOnClickListener {
            persistFromUi()
            // Toggle service. Service decides what to do based on its current state.
            val isRunning = binding.startStopBtn.text == getString(R.string.btn_stop)
            if (isRunning) {
                RelayService.stop(this)
                binding.startStopBtn.setText(R.string.btn_start)
                binding.statusText.setText(R.string.status_stopped)
            } else {
                RelayService.start(this)
                binding.startStopBtn.setText(R.string.btn_stop)
                binding.statusText.setText(R.string.status_connecting)
            }
        }

        binding.testBtn.setOnClickListener {
            persistFromUi()
            runTestConnection()
        }

        binding.openLogsBtn.setOnClickListener { openLogsFolder() }
    }

    private fun persistFromUi() {
        settings.serverUrl = binding.serverUrlField.text?.toString().orEmpty().trim()
        settings.imageFps = binding.imageFpsField.text?.toString()?.toIntOrNull() ?: 0
        settings.transport =
            if (binding.transportPhone.isChecked) Settings.Transport.PHONE
            else Settings.Transport.META
        settings.logLevel = Logger.Level.fromName(
            binding.logLevelSpinner.selectedItem?.toString() ?: "INFO"
        )
        Logger.setLevel(settings.logLevel)
        // Strip token from URL before logging so it doesn't end up in log files.
        val safeUrl = settings.serverUrl.substringBefore('?')
        Logger.i(tag, "settings persisted url=$safeUrl fps=${settings.imageFps} transport=${settings.transport} log=${settings.logLevel}")
    }

    private fun runTestConnection() {
        val url = settings.serverUrl.trim()
        val rejection = settings.validateServerUrl(url)
        if (rejection != null) {
            binding.statusText.text = getString(R.string.status_error, rejection)
            return
        }
        binding.statusText.setText(R.string.status_connecting)
        lifecycleScope.launch {
            val client = RelayClient(url)
            val gotPong = CompletableDeferred<Boolean>()
            val drain = launch {
                client.events.collect { ev ->
                    when (ev) {
                        is RelayClient.Incoming.Open -> {
                            val nonce = System.currentTimeMillis().toString()
                            client.sendText(
                                JSONObject().put("type", "ping").put("nonce", nonce)
                            )
                        }
                        is RelayClient.Incoming.TextEvent -> {
                            if (ev.event.optString("type") == "pong") {
                                gotPong.complete(true)
                            }
                        }
                        is RelayClient.Incoming.Failure -> {
                            gotPong.complete(false)
                        }
                        else -> {}
                    }
                }
            }
            try {
                client.connect()
                val success = withTimeoutOrNull(5_000) { gotPong.await() } ?: false
                val display = url.substringBefore('?')
                if (success) {
                    binding.statusText.text = getString(R.string.status_connected, display)
                } else {
                    binding.statusText.text = getString(R.string.status_error, "timeout")
                }
            } catch (t: Throwable) {
                Logger.e(tag, "test connection failed", t)
                binding.statusText.text = getString(R.string.status_error, t.message ?: "?")
            } finally {
                drain.cancel()
                client.close()
            }
        }
    }

    private fun openLogsFolder() {
        val dir = getExternalFilesDir(null)?.resolve("logs") ?: return
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.fromFile(dir), DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (t: Throwable) {
            Logger.w(tag, "no file viewer; logs are at ${dir.absolutePath}", t)
            binding.statusText.text = "logs: ${dir.absolutePath}"
        }
    }

    private fun maybeRequestPermissions() {
        val missing = requiredPerms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            Logger.i(tag, "requesting ${missing.size} permissions: $missing")
            permissionLauncher.launch(missing.toTypedArray())
        }
    }
}
