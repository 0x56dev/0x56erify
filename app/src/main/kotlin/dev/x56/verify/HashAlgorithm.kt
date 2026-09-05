package dev.x56.verify

/** Supported checksum algorithms, mapped to their [java.security.MessageDigest] names. */
enum class HashAlgorithm(val label: String, val algorithmName: String, val hexLength: Int) {
    SHA_256("SHA-256", "SHA-256", 64),
    SHA_512("SHA-512", "SHA-512", 128),
}
