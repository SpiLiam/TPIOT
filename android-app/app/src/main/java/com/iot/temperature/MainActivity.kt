package com.iot.temperature

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ImageButton
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.hivemq.client.mqtt.MqttClient
import com.hivemq.client.mqtt.mqtt3.Mqtt3AsyncClient
import com.hivemq.client.mqtt.mqtt3.message.publish.Mqtt3Publish
import com.hivemq.client.mqtt.datatypes.MqttQos
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*

// ══════════════════════════════════════════════════════════════════════════════
// CONFIGURATION — modifiable via le bouton ⚙ dans l'app
// ══════════════════════════════════════════════════════════════════════════════
private const val DEFAULT_BROKER_HOST = "VOTRE_NLB_DNS_ICI"
private const val DEFAULT_BROKER_PORT = 1883
private const val TOPIC               = "sensors/temperature"
private const val PREFS_NAME          = "iot_prefs"
private const val PREFS_KEY_HOST      = "broker_host"
// ══════════════════════════════════════════════════════════════════════════════

data class HistoryEntry(val time: String, val value: String)

class HistoryAdapter(private val items: List<HistoryEntry>) :
    RecyclerView.Adapter<HistoryAdapter.VH>() {

    inner class VH(view: View) : RecyclerView.ViewHolder(view) {
        val tvTime:  TextView = view.findViewById(R.id.tvHistTime)
        val tvValue: TextView = view.findViewById(R.id.tvHistValue)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = VH(
        LayoutInflater.from(parent.context).inflate(R.layout.item_history, parent, false)
    )

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.tvTime.text  = items[position].time
        holder.tvValue.text = items[position].value
    }

    override fun getItemCount() = items.size
}

class MainActivity : AppCompatActivity() {

    private lateinit var tvTemperature: TextView
    private lateinit var tvSensorId:    TextView
    private lateinit var tvLastUpdate:  TextView
    private lateinit var tvStatus:      TextView
    private lateinit var rvHistory:     RecyclerView
    private lateinit var btnSettings:   ImageButton

    private var mqttClient: Mqtt3AsyncClient? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val history = mutableListOf<HistoryEntry>()
    private lateinit var adapter: HistoryAdapter
    private val timeFmt = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    private var currentHost = DEFAULT_BROKER_HOST

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvTemperature = findViewById(R.id.tvTemperature)
        tvSensorId    = findViewById(R.id.tvSensorId)
        tvLastUpdate  = findViewById(R.id.tvLastUpdate)
        tvStatus      = findViewById(R.id.tvStatus)
        rvHistory     = findViewById(R.id.rvHistory)
        btnSettings   = findViewById(R.id.btnSettings)

        currentHost = getPrefs().getString(PREFS_KEY_HOST, DEFAULT_BROKER_HOST) ?: DEFAULT_BROKER_HOST

        adapter = HistoryAdapter(history)
        rvHistory.layoutManager = LinearLayoutManager(this)
        rvHistory.adapter = adapter

        btnSettings.setOnClickListener { showSettingsDialog() }
        connectMqtt()
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Dialog paramètres
    // ──────────────────────────────────────────────────────────────────────────
    private fun showSettingsDialog() {
        val editText = EditText(this).apply {
            hint = "ex: iot-nlb-xxx.elb.amazonaws.com"
            setText(currentHost)
            setPadding(48, 32, 48, 16)
            setTextColor(0xFFFFFFFF.toInt())
            setHintTextColor(0xFF888888.toInt())
        }
        AlertDialog.Builder(this)
            .setTitle("Adresse du broker MQTT")
            .setMessage("Port : $DEFAULT_BROKER_PORT  |  Topic : $TOPIC")
            .setView(editText)
            .setPositiveButton("Connecter") { _, _ ->
                val newHost = editText.text.toString().trim()
                if (newHost.isNotEmpty() && newHost != currentHost) {
                    getPrefs().edit().putString(PREFS_KEY_HOST, newHost).apply()
                    currentHost = newHost
                    disconnectMqtt()
                    history.clear()
                    adapter.notifyDataSetChanged()
                    tvTemperature.text = "--.-"
                    connectMqtt()
                }
            }
            .setNegativeButton("Annuler", null)
            .show()
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Connexion MQTT (HiveMQ async client)
    // ──────────────────────────────────────────────────────────────────────────
    private fun connectMqtt() {
        if (currentHost.isBlank() || currentHost == DEFAULT_BROKER_HOST) {
            updateStatus(false, "● Configurer l'adresse du broker (⚙)")
            return
        }

        updateStatus(false, "● Connexion en cours...")

        mqttClient = MqttClient.builder()
            .useMqttVersion3()
            .serverHost(currentHost)
            .serverPort(DEFAULT_BROKER_PORT)
            .identifier("android-${System.currentTimeMillis()}")
            .buildAsync()

        mqttClient?.connectWith()
            ?.cleanSession(true)
            ?.keepAlive(30)
            ?.send()
            ?.whenComplete { _, throwable ->
                if (throwable != null) {
                    updateStatus(false, "● Erreur : ${throwable.message?.take(50)}")
                    mainHandler.postDelayed({ connectMqtt() }, 5000)
                } else {
                    updateStatus(true)
                    subscribeToTopic()
                }
            }
    }

    private fun subscribeToTopic() {
        mqttClient?.subscribeWith()
            ?.topicFilter(TOPIC)
            ?.qos(MqttQos.AT_LEAST_ONCE)
            ?.callback { publish -> onMessageReceived(publish) }
            ?.send()
            ?.whenComplete { _, throwable ->
                if (throwable != null) {
                    updateStatus(false, "● Erreur abonnement")
                }
            }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Traitement d'un message MQTT
    // ──────────────────────────────────────────────────────────────────────────
    private fun onMessageReceived(publish: Mqtt3Publish) {
        val payloadBuf = publish.payload.orElse(null) ?: return
        val bytes = ByteArray(payloadBuf.remaining())
        payloadBuf.get(bytes)
        val raw = String(bytes)

        val (temp, sensorId) = try {
            val json = JSONObject(raw)
            Pair(json.getDouble("value"), json.optString("sensor_id", "inconnu"))
        } catch (e: Exception) {
            Pair(raw.toDoubleOrNull() ?: 0.0, "inconnu")
        }

        val now     = timeFmt.format(Date())
        val tempStr = String.format("%.1f", temp)

        mainHandler.post {
            tvTemperature.text = tempStr
            tvSensorId.text    = "Capteur : $sensorId"
            tvLastUpdate.text  = "Dernière MAJ : $now"
            tvTemperature.setTextColor(when {
                temp < 18  -> 0xFF2196F3.toInt()
                temp < 26  -> 0xFF4CAF50.toInt()
                temp < 30  -> 0xFFFF9800.toInt()
                else       -> 0xFFF44336.toInt()
            })
            history.add(0, HistoryEntry(now, "$tempStr °C"))
            if (history.size > 20) history.removeLast()
            adapter.notifyDataSetChanged()
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Statut + utilitaires
    // ──────────────────────────────────────────────────────────────────────────
    private fun disconnectMqtt() {
        try { mqttClient?.disconnect() } catch (_: Exception) {}
        mqttClient = null
    }

    private fun updateStatus(connected: Boolean, message: String? = null) {
        mainHandler.post {
            tvStatus.text = if (connected) "● Connecté — $currentHost" else message ?: "● Déconnecté"
            tvStatus.setTextColor(when {
                connected                                -> 0xFF4CAF50.toInt()
                message?.contains("Configurer") == true -> 0xFFFF9800.toInt()
                else                                    -> 0xFFF44336.toInt()
            })
        }
    }

    private fun getPrefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun onDestroy() {
        super.onDestroy()
        disconnectMqtt()
    }
}
