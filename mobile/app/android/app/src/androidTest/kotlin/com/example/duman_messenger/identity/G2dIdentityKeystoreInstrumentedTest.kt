package com.example.duman_messenger.identity

import android.content.Context
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Device tests for the G2-D Android adapter.
 *
 * These run against the real Android Keystore on a real device:
 *
 * ```powershell
 * cd mobile\app\android
 * .\gradlew connectedDebugAndroidTest
 * ```
 *
 * They are the only evidence that AES-GCM, key deletion, tag failure and the
 * write protocol behave as designed — the Dart tests replace the platform with a
 * double and prove nothing about Android. Nothing here is executed in CI, and
 * none of it is a claim about production security.
 *
 * Every test starts from an empty identity directory and no G2-D keys, so tests
 * can run in any order.
 */
@RunWith(AndroidJUnit4::class)
class G2dIdentityKeystoreInstrumentedTest {

    private val keyring = G2dIdentityKeyring()

    private fun context(): Context = ApplicationProvider.getApplicationContext()

    private fun storage(): G2dIdentityStorage = G2dIdentityStorage(context().filesDir, keyring)

    private fun identityDirectory(): File = File(context().filesDir, "identity")

    private fun slotFile(index: Int): File = File(identityDirectory(), "identity.$index.bin")

    @Before
    fun cleanSlate() {
        for (alias in listOf(G2D_WRAPPING_KEY_ALIAS, G2D_PROBE_KEY_ALIAS, G2D_STRONGBOX_PROBE_ALIAS)) {
            try {
                keyring.deleteKeyIfPresent(alias)
            } catch (ignored: Exception) {
                // A key that cannot be removed will fail the test that needs it.
            }
        }
        identityDirectory().deleteRecursively()
    }

    // --- wrapping primitive -------------------------------------------------

    @Test
    fun aesGcmRoundTripReturnsTheOriginalBytes() {
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        val key = keyring.createKey(G2D_WRAPPING_KEY_ALIAS, strongBox = false)
        val plaintext = "the identity record".toByteArray(Charsets.UTF_8)
        val associatedData = buildAssociatedData(G2D_RECORD_DOMAIN, 1L, randomKeyId())
        val sealed = keyring.encrypt(key, plaintext, associatedData)
        val opened = keyring.decrypt(key, sealed.iv, sealed.ciphertext, associatedData)
        assertArrayEqualsMessage(plaintext, opened)
    }

    @Test
    fun aDifferentKeyFailsAuthentication() {
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        keyring.deleteKeyIfPresent(G2D_PROBE_KEY_ALIAS)
        val first = keyring.createKey(G2D_WRAPPING_KEY_ALIAS, strongBox = false)
        val second = keyring.createKey(G2D_PROBE_KEY_ALIAS, strongBox = false)
        val associatedData = buildAssociatedData(G2D_RECORD_DOMAIN, 1L, randomKeyId())
        val sealed = keyring.encrypt(first, "secret".toByteArray(Charsets.UTF_8), associatedData)
        try {
            keyring.decrypt(second, sealed.iv, sealed.ciphertext, associatedData)
            fail("decryption with the wrong key must not succeed")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.AUTH_FAILED, error.code)
        }
    }

    @Test
    fun corruptedCiphertextFailsAuthentication() {
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        val key = keyring.createKey(G2D_WRAPPING_KEY_ALIAS, strongBox = false)
        val associatedData = buildAssociatedData(G2D_RECORD_DOMAIN, 1L, randomKeyId())
        val sealed = keyring.encrypt(key, "secret".toByteArray(Charsets.UTF_8), associatedData)
        val corrupted = sealed.ciphertext.copyOf()
        corrupted[0] = (corrupted[0].toInt() xor 0x01).toByte()
        try {
            keyring.decrypt(key, sealed.iv, corrupted, associatedData)
            fail("a modified ciphertext must not authenticate")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.AUTH_FAILED, error.code)
        }
    }

    @Test
    fun associatedDataIsBoundToTheGeneration() {
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        val key = keyring.createKey(G2D_WRAPPING_KEY_ALIAS, strongBox = false)
        val keyId = randomKeyId()
        val sealed = keyring.encrypt(
            key,
            "record".toByteArray(Charsets.UTF_8),
            buildAssociatedData(G2D_RECORD_DOMAIN, 3L, keyId),
        )
        try {
            keyring.decrypt(key, sealed.iv, sealed.ciphertext, buildAssociatedData(G2D_RECORD_DOMAIN, 4L, keyId))
            fail("a replayed generation must not authenticate")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.AUTH_FAILED, error.code)
        }
    }

    // --- storage ------------------------------------------------------------

    @Test
    fun theStoredRecordIsNotPlaintext() {
        val marker = "PLAINTEXT-MARKER-12345"
        storage().saveRecord("{\"marker\":\"$marker\"}")
        for (index in 0 until 2) {
            val file = slotFile(index)
            if (!file.exists()) {
                continue
            }
            val asText = String(file.readBytes(), Charsets.ISO_8859_1)
            assertFalse("slot $index contains the plaintext payload", asText.contains(marker))
        }
    }

    @Test
    fun aStoredRecordSurvivesAReconstructedStorage() {
        storage().saveRecord("{\"recordVersion\":1}")
        // A new instance models the next process start: no shared state, same files.
        val reopened = G2dIdentityStorage(context().filesDir, G2dIdentityKeyring())
        assertEquals("{\"recordVersion\":1}", reopened.loadRecord())
    }

    @Test
    fun noRecordMeansNullNotAnError() {
        assertNull(storage().loadRecord())
    }

    @Test
    fun aMissingWrappingKeyIsReportedAndNeverRecreated() {
        storage().saveRecord("{\"recordVersion\":1}")
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        try {
            storage().loadRecord()
            fail("a missing wrapping key must not decrypt anything")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.KEY_MISSING, error.code)
        }
        assertFalse(
            "the adapter must not regenerate a wrapping key while data exists",
            keyring.hasKey(G2D_WRAPPING_KEY_ALIAS),
        )
    }

    @Test
    fun anOlderGenerationIsRefusedAsStale() {
        storage().saveRecord("{\"generation\":1}")
        storage().saveRecord("{\"generation\":2}")
        // Roll the newest slot back to the previous generation's bytes.
        val previous = slotFile(1)
        val newest = slotFile(0)
        assertTrue("expected both slots to exist", previous.exists() && newest.exists())
        newest.writeBytes(previous.readBytes())
        try {
            storage().loadRecord()
            fail("a rolled back record must not be accepted")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.STALE_RECORD, error.code)
        }
    }

    @Test
    fun anInterruptedWriteLeavesThePreviousRecordReadable() {
        storage().saveRecord("{\"generation\":1}")
        // Model a crash between writing the temporary file and renaming it onto
        // the slot: the committed record is untouched and the partial file is
        // never read.
        File(identityDirectory(), "identity.0.bin.tmp").writeBytes(byteArrayOf(0x47, 0x32))
        assertEquals("{\"generation\":1}", storage().loadRecord())

        // The next write replaces the partial file and supersedes the record.
        storage().saveRecord("{\"generation\":2}")
        assertEquals("{\"generation\":2}", storage().loadRecord())
    }

    @Test
    fun deleteRemovesEverythingAndIsIdempotent() {
        storage().saveRecord("{\"recordVersion\":1}")
        storage().deleteRecord()
        assertNull(storage().loadRecord())
        assertFalse(keyring.hasKey(G2D_WRAPPING_KEY_ALIAS))
        storage().deleteRecord()
        assertNull(storage().loadRecord())
    }

    @Test
    fun aRecordWrittenAfterAResetUsesAFreshKey() {
        storage().saveRecord("{\"recordVersion\":1}")
        keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        // Only an explicit reset may clear the data; a save alone must not.
        try {
            storage().saveRecord("{\"recordVersion\":2}")
            fail("saving over an undecryptable record must not silently re-key it")
        } catch (error: G2dProtectionException) {
            assertEquals(G2dProtectionException.KEY_MISSING, error.code)
        }

        storage().deleteRecord()
        storage().saveRecord("{\"recordVersion\":3}")
        assertEquals("{\"recordVersion\":3}", storage().loadRecord())
    }

    // --- probe --------------------------------------------------------------

    @Test
    fun theProbeReportsTheRealApiLevel() {
        val result = G2dCapabilityProbe(keyring).probe(forceRefresh = true)
        assertEquals(Build.VERSION.SDK_INT, result["apiLevel"])
        assertEquals("AndroidKeyStore", result["keystoreProvider"])
    }

    @Test
    fun theProbeMeasuresARealRoundTrip() {
        val result = G2dCapabilityProbe(keyring).probe(forceRefresh = true)
        assertEquals(true, result["aesGcmSupported"])
        assertEquals(true, result["probeKeyGenerated"])
        assertEquals(true, result["roundTripVerified"])
        assertEquals(G2D_KEY_SIZE_BITS, result["probeKeySizeBits"])
        // The probe key is transient: nothing may be left behind.
        assertFalse(keyring.hasKey(G2D_PROBE_KEY_ALIAS))
    }

    @Test
    fun hardwareBackingComesFromThePlatformAndNotFromTheApiLevel() {
        val result = G2dCapabilityProbe(keyring).probe(forceRefresh = true)
        val reported = result["probeKeyHardwareBacked"] as Boolean
        keyring.deleteKeyIfPresent(G2D_PROBE_KEY_ALIAS)
        val key = keyring.createKey(G2D_PROBE_KEY_ALIAS, strongBox = false)
        val facts = keyring.inspectKey(G2D_PROBE_KEY_ALIAS)
        keyring.deleteKeyIfPresent(G2D_PROBE_KEY_ALIAS)
        assertNotNull("the platform must describe its own key", facts)
        assertEquals(facts!!.hardwareBacked, reported)
        assertNotNull(key)
    }

    @Test
    fun strongBoxIsReportedOnlyWhenThePlatformSupportsIt() {
        val result = G2dCapabilityProbe(keyring).probe(forceRefresh = true)
        val requested = result["strongBoxRequested"] as Boolean
        val created = result["strongBoxKeyCreated"] as Boolean
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            assertFalse("StrongBox must not be attempted below API 28", requested)
            assertFalse(created)
        } else {
            assertTrue("StrongBox must be attempted on API 28 and newer", requested)
        }
        if (!created) {
            assertFalse(keyring.hasKey(G2D_STRONGBOX_PROBE_ALIAS))
        }
    }

    private fun assertArrayEqualsMessage(expected: ByteArray, actual: ByteArray) {
        assertEquals(expected.size, actual.size)
        for (index in expected.indices) {
            assertEquals("byte $index differs", expected[index], actual[index])
        }
    }
}
