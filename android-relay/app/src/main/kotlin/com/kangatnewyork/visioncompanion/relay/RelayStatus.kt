package com.kangatnewyork.visioncompanion.relay

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Process-wide live status shared between RelayService (writer) and
 * MainActivity (observer). Both run in the same process, so a singleton
 * StateFlow is the simplest reliable bridge — no broadcasts needed.
 *
 * The service pushes connection transitions and recognition/enrollment
 * events here; the activity collects and renders them so the user can see
 * what's happening without reading server logs.
 */
object RelayStatus {

    enum class Conn { DISCONNECTED, CONNECTING, CONNECTED }

    data class Snapshot(
        val conn: Conn = Conn.DISCONNECTED,
        /** Most recent human-readable event line (recognition / enrollment). */
        val detail: String = "",
    )

    private val _state = MutableStateFlow(Snapshot())
    val state: StateFlow<Snapshot> = _state.asStateFlow()

    fun setConn(conn: Conn) = _state.update { it.copy(conn = conn) }

    fun setDetail(detail: String) = _state.update { it.copy(detail = detail) }

    fun set(conn: Conn, detail: String) {
        _state.value = Snapshot(conn, detail)
    }
}
