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

    sealed class ComparisonResult {
        object Match : ComparisonResult()
        object Mismatch : ComparisonResult()
        data class Invalid(val reason: String) : ComparisonResult()
    }

    /**
     * Compares a computed hash against a user-supplied expected hash. Whitespace is trimmed and
     * comparison is case-insensitive. Returns [ComparisonResult.Invalid] if the expected hash is
     * empty or has an obviously wrong length/format for [algorithm].
     */
    fun compare(computedHash: String, expectedHashRaw: String, algorithm: HashAlgorithm): ComparisonResult {
        val expected = normalize(expectedHashRaw)
        if (expected.isEmpty()) {
            return ComparisonResult.Invalid("Enter an expected hash to compare.")
        }
        if (!isValidHexHash(expected, algorithm)) {
            return ComparisonResult.Invalid(
                "Expected a ${algorithm.hexLength}-character hexadecimal ${algorithm.label} hash."
            )
        }
        val computed = normalize(computedHash)
        return if (expected == computed) ComparisonResult.Match else ComparisonResult.Mismatch
    }
}
