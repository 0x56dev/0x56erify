package dev.x56.verify

import java.io.InputStream
import java.security.MessageDigest

/** Pure, platform-independent hashing and hash-comparison logic (unit-testable without Android). */
object HashUtils {

    private const val STREAM_BUFFER_SIZE = 8 * 1024

    /**
     * Computes the digest of [input] using [algorithm], reading in fixed-size chunks so the
     * full file is never loaded into memory. Caller is responsible for closing [input].
     */
    fun hashStream(input: InputStream, algorithm: HashAlgorithm): String {
        val digest = MessageDigest.getInstance(algorithm.algorithmName)
        val buffer = ByteArray(STREAM_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().toHexString()
    }

    private fun ByteArray.toHexString(): String {
        val chars = CharArray(size * 2)
        val hexDigits = "0123456789abcdef"
        for (i in indices) {
            val byte = this[i].toInt() and 0xFF
            chars[i * 2] = hexDigits[byte shr 4]
            chars[i * 2 + 1] = hexDigits[byte and 0x0F]
        }
        return String(chars)
    }

    /** Trims and lower-cases a user-pasted hash for comparison purposes. */
    fun normalize(rawHash: String): String = rawHash.trim().lowercase()

    /** Whether [normalized] looks like a syntactically valid hex digest for [algorithm]. */
    fun isValidHexHash(normalized: String, algorithm: HashAlgorithm): Boolean {
        if (normalized.length != algorithm.hexLength) return false
        return normalized.all { it in '0'..'9' || it in 'a'..'f' }
    }

    private val whitespaceRun = Regex("\\s+")

    /**
     * Extracts a digest of the expected length for [algorithm] from pasted input.
     *
     * Two shapes are accepted:
     * 1. A bare hash: the entire (trimmed) input is exactly [HashAlgorithm.hexLength] hex
     *    characters, case-insensitive.
     * 2. Standard `sha256sum`/`sha512sum`-style output: `<hash>  filename`, with the hash as
     *    the *first* whitespace-separated token (tabs or repeated spaces are fine).
     *
     * Anything else - including text that merely contains a hash-length hex run somewhere in
     * the middle - is rejected rather than guessed at, since silently extracting a substring
     * from arbitrary text could pick the wrong token and produce a false MATCH/MISMATCH.
     */
    fun extractExpectedHash(rawInput: String, algorithm: HashAlgorithm): String? {
        val trimmed = rawInput.trim()
        if (trimmed.isEmpty()) return null

        val lowered = trimmed.lowercase()
        if (isValidHexHash(lowered, algorithm)) return lowered

        val tokens = trimmed.split(whitespaceRun)
        if (tokens.size < 2) return null
        val firstToken = tokens[0].lowercase()
        return if (isValidHexHash(firstToken, algorithm)) firstToken else null
    }

    sealed class ComparisonResult {
        object Match : ComparisonResult()
        object Mismatch : ComparisonResult()
        data class Invalid(val reason: String) : ComparisonResult()
    }

    /**
     * Compares a computed hash against a user-supplied expected hash. The expected hash is
     * parsed with [extractExpectedHash] (bare hash or checksum-tool output), and comparison is
     * case-insensitive. Returns [ComparisonResult.Invalid] if the expected hash is empty or
     * cannot be unambiguously parsed into a digest of the correct length for [algorithm].
     */
    fun compare(computedHash: String, expectedHashRaw: String, algorithm: HashAlgorithm): ComparisonResult {
        if (expectedHashRaw.trim().isEmpty()) {
            return ComparisonResult.Invalid("Enter an expected hash to compare.")
        }
        val expected = extractExpectedHash(expectedHashRaw, algorithm)
            ?: return ComparisonResult.Invalid(
                "Expected a ${algorithm.hexLength}-character hexadecimal ${algorithm.label} hash."
            )
        val computed = normalize(computedHash)
        return if (expected == computed) ComparisonResult.Match else ComparisonResult.Mismatch
    }
}
