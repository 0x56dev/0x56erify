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

    /** Outcome of parsing a user-pasted expected hash; see [parseExpectedHash]. */
    sealed class ExpectedHash {
        data class Parsed(val hash: String) : ExpectedHash()
        object Malformed : ExpectedHash()
        object MultipleHashes : ExpectedHash()
    }

    /**
     * Parses pasted input into a single expected digest for [algorithm].
     *
     * The input is read line by line (blank lines ignored), and every line must be either:
     * 1. A bare hash: exactly [HashAlgorithm.hexLength] hex characters, case-insensitive.
     * 2. Standard `sha256sum`/`sha512sum`-style output: `<hash>  filename` (or `<hash> *filename`
     *    in binary mode), with the hash as the *first* whitespace-separated token on the line.
     *
     * If any line is something else - including text that merely contains a hash-length hex run
     * somewhere in the middle - the input is [ExpectedHash.Malformed]. If the lines carry more
     * than one distinct hash (e.g. a whole `SHA256SUMS` file), the input is
     * [ExpectedHash.MultipleHashes]. Either way it is rejected rather than guessed at, since
     * picking one hash out of several could produce a false MATCH/MISMATCH. Only the first token
     * of each line is treated as a hash, so a filename that is itself hex is not mistaken for one.
     */
    fun parseExpectedHash(rawInput: String, algorithm: HashAlgorithm): ExpectedHash {
        val hashes = mutableSetOf<String>()
        for (line in rawInput.lines()) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            val hash = trimmed.split(whitespaceRun, limit = 2)[0].lowercase()
            if (!isValidHexHash(hash, algorithm)) return ExpectedHash.Malformed
            hashes += hash
        }
        return when (hashes.size) {
            0 -> ExpectedHash.Malformed
            1 -> ExpectedHash.Parsed(hashes.single())
            else -> ExpectedHash.MultipleHashes
        }
    }

    /** The single digest [parseExpectedHash] finds in [rawInput], or null if it rejects the input. */
    fun extractExpectedHash(rawInput: String, algorithm: HashAlgorithm): String? =
        (parseExpectedHash(rawInput, algorithm) as? ExpectedHash.Parsed)?.hash

    sealed class ComparisonResult {
        object Match : ComparisonResult()
        object Mismatch : ComparisonResult()
        data class Invalid(val reason: String) : ComparisonResult()
    }

    /**
     * Compares a computed hash against a user-supplied expected hash. The expected hash is
     * parsed with [parseExpectedHash] (bare hash or checksum-tool output), and comparison is
     * case-insensitive. Returns [ComparisonResult.Invalid] if the expected hash is empty or
     * cannot be unambiguously parsed into a single digest of the correct length for [algorithm].
     */
    fun compare(computedHash: String, expectedHashRaw: String, algorithm: HashAlgorithm): ComparisonResult {
        if (expectedHashRaw.trim().isEmpty()) {
            return ComparisonResult.Invalid("Enter an expected hash to compare.")
        }
        val expected = when (val parsed = parseExpectedHash(expectedHashRaw, algorithm)) {
            is ExpectedHash.Parsed -> parsed.hash
            ExpectedHash.Malformed -> return ComparisonResult.Invalid(
                "Expected a ${algorithm.hexLength}-character hexadecimal ${algorithm.label} hash."
            )
            ExpectedHash.MultipleHashes -> return ComparisonResult.Invalid(
                "Several different ${algorithm.label} hashes were pasted. Paste only the line for this file."
            )
        }
        val computed = normalize(computedHash)
        return if (expected == computed) ComparisonResult.Match else ComparisonResult.Mismatch
    }
}
