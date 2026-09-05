package dev.x56.verify

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

class MainActivity : ComponentActivity() {

    private val viewModel: VerifyViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            X56erifyTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    VerifyScreen(viewModel = viewModel)
                }
            }
        }
    }
}

private val DarkScheme = darkColorScheme(
    primary = Color(0xFF3FB950),
    onPrimary = Color(0xFF04140A),
    secondary = Color(0xFF2EA043),
    background = Color(0xFF0D1117),
    surface = Color(0xFF161B22),
    onBackground = Color(0xFFE6EDF3),
    onSurface = Color(0xFFE6EDF3),
    error = Color(0xFFF85149),
)

@Composable
fun X56erifyTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = DarkScheme, content = content)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VerifyScreen(viewModel: VerifyViewModel) {
    val state by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri -> viewModel.onFileSelected(uri) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Text(
            text = "0x56erify",
            style = MaterialTheme.typography.headlineMedium,
            fontFamily = FontFamily.Monospace,
        )
        Text(
            text = "Local checksum verification",
            style = MaterialTheme.typography.bodyMedium,
        )

        Spacer(Modifier.height(20.dp))

        Button(
            onClick = { filePicker.launch(arrayOf("*/*")) },
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "Select a file to hash" },
        ) {
            Text("Select file")
        }

        Spacer(Modifier.height(8.dp))

        Text(
            text = state.fileName ?: "No file selected",
            style = MaterialTheme.typography.bodyMedium,
        )

        Spacer(Modifier.height(16.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            HashAlgorithm.entries.forEach { algorithm ->
                FilterChip(
                    selected = state.algorithm == algorithm,
                    onClick = { viewModel.onAlgorithmSelected(algorithm) },
                    label = { Text(algorithm.label) },
                    modifier = Modifier.semantics {
                        contentDescription = "Use ${algorithm.label} algorithm"
                    },
                )
            }
        }

        Spacer(Modifier.height(20.dp))

        when {
            state.isHashing -> Row(
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                CircularProgressIndicator(modifier = Modifier.height(20.dp))
                Text("Computing ${state.algorithm.label}…")
            }

            state.errorMessage != null -> Text(
                text = state.errorMessage.orEmpty(),
                color = MaterialTheme.colorScheme.error,
            )

            state.computedHash != null -> Column {
                Text(
                    text = "${state.algorithm.label} hash",
                    style = MaterialTheme.typography.labelLarge,
                )
                SelectionContainer {
                    Text(
                        text = state.computedHash.orEmpty(),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 14.sp,
                        modifier = Modifier.semantics {
                            contentDescription = "Computed hash: ${state.computedHash}"
                        },
                    )
                }
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = {
                            clipboard.setText(AnnotatedString(state.computedHash.orEmpty()))
                        },
                        modifier = Modifier.semantics { contentDescription = "Copy computed hash" },
                    ) { Text("Copy") }

                    OutlinedButton(
                        onClick = {
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, state.computedHash)
                            }
                            context.startActivity(Intent.createChooser(sendIntent, "Share hash"))
                        },
                        modifier = Modifier.semantics { contentDescription = "Share computed hash" },
                    ) { Text("Share") }
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        OutlinedTextField(
            value = state.expectedHash,
            onValueChange = viewModel::onExpectedHashChanged,
            label = { Text("Expected hash") },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "Expected hash input" },
        )

        Spacer(Modifier.height(12.dp))

        Button(
            onClick = viewModel::onCompareClicked,
            enabled = state.computedHash != null,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "Compare expected and computed hashes" },
        ) {
            Text("Compare")
        }

        state.comparisonResult?.let { result ->
            Spacer(Modifier.height(12.dp))
            val (text, color) = when (result) {
                is HashUtils.ComparisonResult.Match ->
                    "MATCH" to MaterialTheme.colorScheme.primary
                is HashUtils.ComparisonResult.Mismatch ->
                    "MISMATCH" to MaterialTheme.colorScheme.error
                is HashUtils.ComparisonResult.Invalid ->
                    result.reason to MaterialTheme.colorScheme.error
            }
            Text(
                text = text,
                style = MaterialTheme.typography.titleLarge,
                color = color,
                modifier = Modifier.semantics { contentDescription = "Result: $text" },
            )
        }

        Spacer(Modifier.height(24.dp))

        TextButton(
            onClick = viewModel::onReset,
            modifier = Modifier.semantics { contentDescription = "Reset app state" },
        ) {
            Text("Reset")
        }
    }
}
