package dev.x56.verify

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HashUtilsTest {

    @Test
    fun `sha-256 of abc equals reference digest`() {
        val input = "abc".toByteArray(Charsets.UTF_8)
        val hash = HashUtils.hashStream(ByteArrayInputStream(input), HashAlgorithm.SHA_256)
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hash)
    }

    @Test
    fun `sha-256 of empty input equals reference digest`() {
        val hash = HashUtils.hashStream(ByteArrayInputStream(ByteArray(0)), HashAlgorithm.SHA_256)
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash)
    }

    @Test
    fun `sha-512 of abc equals reference digest`() {
        val input = "abc".toByteArray(Charsets.UTF_8)
        val hash = HashUtils.hashStream(ByteArrayInputStream(input), HashAlgorithm.SHA_512)
        assertEquals(
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd" +
                "454d4423643ce80e2a9ac94fa54ca49f",
            hash,
        )
    }

    @Test
    fun `sha-512 of empty input equals reference digest`() {
        val hash = HashUtils.hashStream(ByteArrayInputStream(ByteArray(0)), HashAlgorithm.SHA_512)
        assertEquals(
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f" +
                "63b931bd47417a81a538327af927da3e",
            hash,
        )
    }

    @Test
    fun `normalize trims whitespace and lower-cases`() {
        assertEquals("abc123", HashUtils.normalize("  ABC123  \n"))
    }

    @Test
    fun `isValidHexHash accepts correct length and hex characters`() {
        val validSha256 = "a".repeat(64)
        assertTrue(HashUtils.isValidHexHash(validSha256, HashAlgorithm.SHA_256))
    }

    @Test
    fun `isValidHexHash rejects wrong length`() {
        val tooShort = "a".repeat(10)
        assertFalse(HashUtils.isValidHexHash(tooShort, HashAlgorithm.SHA_256))
    }

    @Test
    fun `isValidHexHash rejects non-hex characters`() {
        val nonHex = "g".repeat(64)
        assertFalse(HashUtils.isValidHexHash(nonHex, HashAlgorithm.SHA_256))
    }

    @Test
    fun `compare returns Match for identical hashes ignoring case and whitespace`() {
        val computed = "a".repeat(64)
        val expectedInput = "  " + "A".repeat(64) + "  "
        val result = HashUtils.compare(computed, expectedInput, HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Match)
    }

    @Test
    fun `compare returns Mismatch for different hashes`() {
        val computed = "a".repeat(64)
        val expected = "b".repeat(64)
        val result = HashUtils.compare(computed, expected, HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Mismatch)
    }

    @Test
    fun `compare returns Invalid for empty expected hash`() {
        val computed = "a".repeat(64)
        val result = HashUtils.compare(computed, "", HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Invalid)
    }

    @Test
    fun `compare returns Invalid for wrong-length expected hash`() {
        val computed = "a".repeat(64)
        val result = HashUtils.compare(computed, "abc123", HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Invalid)
    }

    @Test
    fun `compare returns Invalid for non-hex expected hash`() {
        val computed = "a".repeat(64)
        val result = HashUtils.compare(computed, "z".repeat(64), HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Invalid)
    }
}
