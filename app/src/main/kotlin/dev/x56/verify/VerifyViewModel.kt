package dev.x56.verify

import android.app.Application
import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class VerifyUiState(
    val fileName: String? = null,
    val fileUri: Uri? = null,
    val algorithm: HashAlgorithm = HashAlgorithm.SHA_256,
    val isHashing: Boolean = false,
    val computedHash: String? = null,
    val expectedHash: String = "",
    val comparisonResult: HashUtils.ComparisonResult? = null,
    val errorMessage: String? = null,
)

class VerifyViewModel(application: Application) : AndroidViewModel(application) {

    private val _uiState = MutableStateFlow(VerifyUiState())
    val uiState: StateFlow<VerifyUiState> = _uiState

    private var hashingJob: Job? = null

    fun onFileSelected(uri: Uri?) {
        if (uri == null) return // user cancelled the picker; keep prior state
        val resolver = getApplication<Application>().contentResolver
        val displayName = queryDisplayName(resolver, uri)
        _uiState.update {
            it.copy(
                fileName = displayName,
                fileUri = uri,
                computedHash = null,
                comparisonResult = null,
                errorMessage = null,
            )
        }
        startHashing(uri, _uiState.value.algorithm)
    }

    fun onAlgorithmSelected(algorithm: HashAlgorithm) {
        _uiState.update { it.copy(algorithm = algorithm, computedHash = null, comparisonResult = null) }
        _uiState.value.fileUri?.let { startHashing(it, algorithm) }
    }

    fun onExpectedHashChanged(value: String) {
        _uiState.update { it.copy(expectedHash = value, comparisonResult = null) }
    }

    fun onCompareClicked() {
        val state = _uiState.value
        val computed = state.computedHash ?: return
        val result = HashUtils.compare(computed, state.expectedHash, state.algorithm)
        _uiState.update { it.copy(comparisonResult = result) }
    }

    fun onReset() {
        hashingJob?.cancel()
        _uiState.value = VerifyUiState()
    }

    private fun startHashing(uri: Uri, algorithm: HashAlgorithm) {
        hashingJob?.cancel()
        hashingJob = viewModelScope.launch {
            _uiState.update { it.copy(isHashing = true, errorMessage = null, comparisonResult = null) }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val resolver = getApplication<Application>().contentResolver
                    resolver.openInputStream(uri)?.use { stream ->
                        HashUtils.hashStream(stream, algorithm)
                    } ?: throw java.io.IOException("Unable to open the selected file.")
                }
            }
            result.fold(
                onSuccess = { hash ->
                    _uiState.update { it.copy(isHashing = false, computedHash = hash) }
                },
                onFailure = { error ->
                    _uiState.update {
                        it.copy(
                            isHashing = false,
                            computedHash = null,
                            errorMessage = error.message ?: "Failed to read the selected file.",
                        )
                    }
                },
            )
        }
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String {
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && cursor.moveToFirst()) {
                    return cursor.getString(nameIndex) ?: uri.lastPathSegment ?: "Selected file"
                }
            }
        }
        return uri.lastPathSegment ?: "Selected file"
    }
}
