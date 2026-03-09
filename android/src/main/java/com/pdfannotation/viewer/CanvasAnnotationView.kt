package com.pdfannotation.viewer

import android.graphics.Matrix
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.viewinterop.AndroidView
import androidx.ink.authoring.InProgressStrokesView
import com.pdfannotation.canvas.InkCanvas
import com.pdfannotation.canvas.StrokeAuthoringState
import com.pdfannotation.canvas.rememberInProgressStrokesView
import com.pdfannotation.canvas.rememberStrokeAuthoringState
import com.pdfannotation.canvas.rememberStrokeAuthoringTouchListener
import com.pdfannotation.model.PdfAnnotationViewModel

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun CanvasAnnotationView(viewModel: PdfAnnotationViewModel) {
    val brushSettings by viewModel.brushSettings.collectAsState()
    val strokes by viewModel.strokes.collectAsState()
    val backgroundColor by viewModel.backgroundColor.collectAsState()
    val inProgressStrokesView: InProgressStrokesView = rememberInProgressStrokesView()
    val transformMatrix = remember {
        Matrix().apply {
            preScale(1f, 1f)
        }
    }
    var size by remember { mutableStateOf(IntSize.Zero) }

    val strokeAuthoringState: StrokeAuthoringState = rememberStrokeAuthoringState(
        inProgressStrokesView,
        transformMatrix,
        brushSettings,
        strokesFinishedListener = { newStrokes ->
            strokes.setStrokesPerPage(0, newStrokes, Size(size.width.toFloat(), size.height.toFloat()))
        }
    )
    val strokeAuthoringTouchListener = rememberStrokeAuthoringTouchListener(
        strokeAuthoringState = strokeAuthoringState,
        brushSettings = brushSettings,
        transformMatrix = transformMatrix,
    )

    LaunchedEffect(strokes, size.width, size.height) {
        strokeAuthoringState.finishedStrokes.value = strokes.getStrokes(
            0,
            Size(size.width.toFloat(), size.height.toFloat())
        )
    }

    LaunchedEffect(Unit) {
        viewModel.setPage(0)
        viewModel.setPageCount(1)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(backgroundColor ?: 0x00000000))
            .onSizeChanged { size = it }
    ) {
        InkCanvas(
            modifier = Modifier
                .fillMaxSize()
                .pointerInteropFilter { event ->
                    strokeAuthoringTouchListener?.onTouch(inProgressStrokesView, event) ?: false
                },
            strokeAuthoringState = strokeAuthoringState,
        )
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = {
                inProgressStrokesView.apply {
                    layoutParams = FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    )
                    motionEventToViewTransform = transformMatrix
                }
            },
            update = { canvasView ->
                canvasView.motionEventToViewTransform = transformMatrix
                canvasView.invalidate()
            }
        )
    }
}
