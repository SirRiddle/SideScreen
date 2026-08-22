package com.sidescreen.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import org.w3c.dom.Node

class LandscapeSettingsLayoutTest {
    private val androidNamespace = "http://schemas.android.com/apk/res/android"

    @Test
    fun landscapeLayoutGroupsSettingsAndKeepsActionsOutsideScrollingContent() {
        val layout = locateLandscapeLayout()
        assertTrue("Landscape settings layout must exist", layout.isFile)

        val document =
            DocumentBuilderFactory
                .newInstance()
                .apply { isNamespaceAware = true }
                .newDocumentBuilder()
                .parse(layout)

        val columns = findById(document.documentElement, "settingsColumns")
        assertNotNull("Landscape settings must have a grouped columns container", columns)
        assertEquals("horizontal", columns!!.getAttributeNS(androidNamespace, "orientation"))

        val overlayColumn = findById(document.documentElement, "overlaySettingsColumn")
        val buttonColumn = findById(document.documentElement, "buttonSettingsColumn")
        assertNotNull("Overlay controls must form the first column", overlayColumn)
        assertNotNull("Settings-button controls must form the second column", buttonColumn)
        assertTrue("Overlay controls must be inside the columns container", isDescendantOf(overlayColumn!!, columns))
        assertTrue("Button controls must be inside the columns container", isDescendantOf(buttonColumn!!, columns))

        val actionBar = findById(document.documentElement, "settingsActionBar")
        val disconnect = findById(document.documentElement, "disconnectSettingsButton")
        val done = findById(document.documentElement, "closeButton")
        assertNotNull("Landscape settings must have a fixed action bar", actionBar)
        assertNotNull("Disconnect action must remain available", disconnect)
        assertNotNull("Done action must remain available", done)
        assertTrue("Disconnect must be in the fixed action bar", isDescendantOf(disconnect!!, actionBar!!))
        assertTrue("Done must be in the fixed action bar", isDescendantOf(done!!, actionBar))
        assertFalse("The fixed action bar must not scroll", hasAncestorNamed(actionBar, "ScrollView"))
    }

    private fun locateLandscapeLayout(): File {
        val workingDirectory = File(requireNotNull(System.getProperty("user.dir")))
        val candidates =
            listOf(
                File(workingDirectory, "app/src/main/res/layout-land/dialog_settings.xml"),
                File(workingDirectory, "src/main/res/layout-land/dialog_settings.xml"),
            )
        return candidates.firstOrNull(File::exists) ?: candidates.first()
    }

    private fun findById(root: Element, id: String): Element? {
        if (root.getAttributeNS(androidNamespace, "id").endsWith("/$id")) {
            return root
        }
        val children = root.childNodes
        for (index in 0 until children.length) {
            val child = children.item(index)
            if (child is Element) {
                findById(child, id)?.let { return it }
            }
        }
        return null
    }

    private fun isDescendantOf(
        node: Node,
        ancestor: Node,
    ): Boolean {
        var parent = node.parentNode
        while (parent != null) {
            if (parent == ancestor) return true
            parent = parent.parentNode
        }
        return false
    }

    private fun hasAncestorNamed(
        node: Node,
        name: String,
    ): Boolean {
        var parent = node.parentNode
        while (parent != null) {
            if (parent.nodeName.substringAfterLast('.') == name) return true
            parent = parent.parentNode
        }
        return false
    }
}
