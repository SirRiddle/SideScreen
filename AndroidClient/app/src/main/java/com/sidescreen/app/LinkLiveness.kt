package com.sidescreen.app

/**
 * Dead-link detection for the stream socket (issue #72). The socket has no read timeout, so when
 * the Mac vanishes without a FIN/RST (WiFi off, sleep, AP power-cycle) the receive loop blocks
 * until the kernel gives up 15+ minutes later, showing a frozen frame and a green "Connected".
 * The client already pings once a second and the Mac answers on its network queue, so a pong
 * gap far beyond any healthy RTT means the link is gone.
 *
 * Not tripped by the app being in the background: the receive loop keeps reading there, so pongs
 * keep arriving. When the process itself was frozen, the ping timer did not run either, and that
 * time is not blamed on the link ([PING_GAP_RESET_NS]).
 */
object LinkLiveness {
    /** No pong for this long → the link is considered dead. Generous: a few lost pongs are fine. */
    const val TIMEOUT_NS = 10_000_000_000L

    /**
     * The ping timer fires every second. A gap this large between two of its calls means our
     * own process was not running (cached-app freezer, debugger), so the pong clock restarts.
     */
    const val PING_GAP_RESET_NS = 3_000_000_000L

    fun isDead(
        nowNs: Long,
        lastPongNs: Long,
        timeoutNs: Long = TIMEOUT_NS,
    ): Boolean = lastPongNs != 0L && nowNs - lastPongNs > timeoutNs

    fun timerWasPaused(
        nowNs: Long,
        previousPingCallNs: Long,
    ): Boolean = previousPingCallNs != 0L && nowNs - previousPingCallNs > PING_GAP_RESET_NS
}
