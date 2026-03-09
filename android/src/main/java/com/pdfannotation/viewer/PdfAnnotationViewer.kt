package com.pdfannotation.viewer

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.pdfannotation.model.PdfAnnotationViewModel

@Composable
fun PdfAnnotationViewer(viewModel: PdfAnnotationViewModel) {
    val canvasMode by viewModel.canvasMode.collectAsState()
    val thumbnail by viewModel.thumbnailMode.collectAsState()

    if (canvasMode) {
        CanvasAnnotationView(viewModel)
    } else if (thumbnail) {
        PdfThumbnail(viewModel)
    } else {
        PdfHorizontalPager(viewModel)
    }
}
