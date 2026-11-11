package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #118: the Advanced Settings port is parsed and validated before it is saved. */
class PortSettingTest {
    @Test
    fun `default matches the Mac app's default port`() {
        assertEquals(54321, PreferencesManager.DEFAULT_PORT)
    }

    @Test
    fun `valid ports parse, surrounding whitespace ignored`() {
        assertEquals(8888, PreferencesManager.parsePort("8888"))
        assertEquals(54322, PreferencesManager.parsePort(" 54322 "))
        assertEquals(1, PreferencesManager.parsePort("1"))
        assertEquals(65535, PreferencesManager.parsePort("65535"))
    }

    @Test
    fun `empty, non-numeric and out-of-range text is rejected`() {
        assertNull(PreferencesManager.parsePort(null))
        assertNull(PreferencesManager.parsePort(""))
        assertNull(PreferencesManager.parsePort("abc"))
        assertNull(PreferencesManager.parsePort("0"))
        assertNull(PreferencesManager.parsePort("65536"))
        assertNull(PreferencesManager.parsePort("-1"))
    }

    @Test
    fun `port range check`() {
        assertTrue(PreferencesManager.isValidPort(54321))
        assertFalse(PreferencesManager.isValidPort(0))
        assertFalse(PreferencesManager.isValidPort(70000))
    }
}
