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

    // --- extractExpectedHash: pasted-checksum parsing -------------------------------------

    @Test
    fun `extractExpectedHash accepts a bare valid hash`() {
        val hash = "a".repeat(64)
        assertEquals(hash, HashUtils.extractExpectedHash(hash, HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts an uppercase valid hash`() {
        val hash = "A".repeat(64)
        assertEquals("a".repeat(64), HashUtils.extractExpectedHash(hash, HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts leading and trailing whitespace`() {
        val hash = "a".repeat(64)
        assertEquals(hash, HashUtils.extractExpectedHash("   $hash   ", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts a trailing newline`() {
        val hash = "a".repeat(64)
        assertEquals(hash, HashUtils.extractExpectedHash("$hash\n", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts sha256sum-style output with two spaces before the filename`() {
        val hash = "a".repeat(64)
        assertEquals(hash, HashUtils.extractExpectedHash("$hash  file.iso", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts a tab between hash and filename`() {
        val hash = "a".repeat(64)
        assertEquals(hash, HashUtils.extractExpectedHash("$hash\tfile.iso", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects invalid hexadecimal characters`() {
        assertEquals(null, HashUtils.extractExpectedHash("g".repeat(64), HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects a too-short hash`() {
        assertEquals(null, HashUtils.extractExpectedHash("a".repeat(63), HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects a too-long hash`() {
        assertEquals(null, HashUtils.extractExpectedHash("a".repeat(65), HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects arbitrary text`() {
        assertEquals(null, HashUtils.extractExpectedHash("not a hash at all", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash does not silently accept a valid-length hash buried mid-text`() {
        val hash = "a".repeat(64)
        val buried = "here is the hash $hash and then more text"
        assertEquals(null, HashUtils.extractExpectedHash(buried, HashAlgorithm.SHA_256))
    }

    @Test
    fun `compare Matches when pasted expected hash is sha256sum-style output`() {
        val hash = "a".repeat(64)
        val result = HashUtils.compare(hash, "$hash  downloaded-file.iso", HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Match)
    }

    // --- extractExpectedHash: multi-line input ----------------------------------------------

    private val hashA = "a".repeat(64)
    private val hashB = "b".repeat(64)

    @Test
    fun `parseExpectedHash rejects two different checksum lines with the target hash second`() {
        val input = "$hashB  fileB.iso\n$hashA  fileA.iso"
        assertEquals(
            HashUtils.ExpectedHash.MultipleHashes,
            HashUtils.parseExpectedHash(input, HashAlgorithm.SHA_256),
        )
    }

    @Test
    fun `parseExpectedHash rejects two different checksum lines with the target hash first`() {
        val input = "$hashA  fileA.iso\n$hashB  fileB.iso"
        assertEquals(
            HashUtils.ExpectedHash.MultipleHashes,
            HashUtils.parseExpectedHash(input, HashAlgorithm.SHA_256),
        )
    }

    @Test
    fun `parseExpectedHash rejects two different bare hashes on separate lines`() {
        assertEquals(
            HashUtils.ExpectedHash.MultipleHashes,
            HashUtils.parseExpectedHash("$hashB\n$hashA", HashAlgorithm.SHA_256),
        )
    }

    @Test
    fun `compare returns Invalid rather than Mismatch or Match for several different hashes`() {
        val bThenA = HashUtils.compare(hashA, "$hashB  fileB.iso\n$hashA  fileA.iso", HashAlgorithm.SHA_256)
        val aThenB = HashUtils.compare(hashA, "$hashA  fileA.iso\n$hashB  fileB.iso", HashAlgorithm.SHA_256)
        assertTrue(bThenA is HashUtils.ComparisonResult.Invalid)
        assertTrue(aThenB is HashUtils.ComparisonResult.Invalid)
        assertTrue((bThenA as HashUtils.ComparisonResult.Invalid).reason.contains("Several different"))
    }

    @Test
    fun `extractExpectedHash accepts duplicate lines carrying the same hash`() {
        val input = "$hashA  file.iso\n${hashA.uppercase()}  file.iso\n"
        assertEquals(hashA, HashUtils.extractExpectedHash(input, HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash ignores blank lines around a single checksum line`() {
        assertEquals(hashA, HashUtils.extractExpectedHash("\n\n  $hashA  file.iso  \n\n", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects a checksum line followed by other text`() {
        val input = "$hashA  file.iso\nsigned by the release team"
        assertEquals(null, HashUtils.extractExpectedHash(input, HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash rejects a bare hash followed by other text`() {
        assertEquals(null, HashUtils.extractExpectedHash("$hashA\nsee release notes", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts a filename that is itself a hash-length hex string`() {
        assertEquals(hashA, HashUtils.extractExpectedHash("$hashA  $hashB", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts the binary-mode asterisk before the filename`() {
        assertEquals(hashA, HashUtils.extractExpectedHash("$hashA *file.iso", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts CRLF line endings`() {
        assertEquals(hashA, HashUtils.extractExpectedHash("$hashA  file.iso\r\n", HashAlgorithm.SHA_256))
        assertEquals(
            HashUtils.ExpectedHash.MultipleHashes,
            HashUtils.parseExpectedHash("$hashA  a.iso\r\n$hashB  b.iso\r\n", HashAlgorithm.SHA_256),
        )
    }

    @Test
    fun `extractExpectedHash rejects a line whose hash is for a different algorithm`() {
        val sha512Line = "c".repeat(128) + "  file.iso"
        assertEquals(null, HashUtils.extractExpectedHash("$hashA  file.iso\n$sha512Line", HashAlgorithm.SHA_256))
    }

    @Test
    fun `extractExpectedHash accepts a single sha512sum-style line`() {
        val hash = "c".repeat(128)
        assertEquals(hash, HashUtils.extractExpectedHash("$hash  file.iso", HashAlgorithm.SHA_512))
    }

    @Test
    fun `compare Matches a real digest pasted as sha256sum output among duplicate lines`() {
        val abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        val result = HashUtils.compare(abc, "$abc  abc.txt\n$abc  ./abc.txt", HashAlgorithm.SHA_256)
        assertTrue(result is HashUtils.ComparisonResult.Match)
    }
}
