package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #72: a dead WiFi link must be noticed in seconds, not after the kernel's 15+ minutes. */
class LinkLivenessTest {
    private val second = 1_000_000_000L

    @Test
    fun `recent pong keeps the link alive`() {
        val now = 100 * second
        assertFalse(LinkLiveness.isDead(nowNs = now, lastPongNs = now - 2 * second))
        assertFalse(LinkLiveness.isDead(nowNs = now, lastPongNs = now - LinkLiveness.TIMEOUT_NS))
    }

    @Test
    fun `no pong past the timeout means the link is dead`() {
        val now = 100 * second
        assertTrue(LinkLiveness.isDead(nowNs = now, lastPongNs = now - LinkLiveness.TIMEOUT_NS - 1))
        assertTrue(LinkLiveness.isDead(nowNs = now, lastPongNs = now - 60 * second))
    }

    @Test
    fun `an unarmed watchdog never fires`() {
        assertFalse(LinkLiveness.isDead(nowNs = 100 * second, lastPongNs = 0L))
    }

    @Test
    fun `a long gap between ping calls means our own process was paused`() {
        val now = 100 * second
        assertFalse(LinkLiveness.timerWasPaused(nowNs = now, previousPingCallNs = 0L))
        assertFalse(LinkLiveness.timerWasPaused(nowNs = now, previousPingCallNs = now - second))
        assertTrue(LinkLiveness.timerWasPaused(nowNs = now, previousPingCallNs = now - 30 * second))
    }

    @Test
    fun `timeout is well beyond the 1 s ping interval and the pause threshold`() {
        assertTrue(LinkLiveness.TIMEOUT_NS >= 5 * second)
        assertTrue(LinkLiveness.TIMEOUT_NS > LinkLiveness.PING_GAP_RESET_NS)
    }
}
