package com.pdfannotation.viewer

import android.graphics.Matrix
import android.view.MotionEvent
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpSize
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
    val drawWithFinger by viewModel.drawWithFinger.collectAsState()
    val strokes by viewModel.strokes.collectAsState()
    val backgroundColor by viewModel.backgroundColor.collectAsState()
    // Recreate the live-stroke view on rotation: its front buffer is created
    // pre-rotated with the display transform hint captured at surface setup,
    // and a fixed-size view never gets the surface event that would refresh
    // it — after rotating, wet ink renders with the stale transform (appears
    // dead) until the device is rotated back. A fresh view attaches after the
    // configuration change and picks up the current hint.
    val configuration = LocalConfiguration.current
    val inProgressStrokesView: InProgressStrokesView = rememberInProgressStrokesView(configuration.orientation)
    val transformMatrix = remember {
        Matrix().apply {
            preScale(1f, 1f)
        }
    }
    var size by remember { mutableStateOf(IntSize.Zero) }

    // The canvas can be laid out far larger than the screen (a whole game table).
    // InProgressStrokesView allocates its low-latency front buffer proportional to
    // its size, and surfaces beyond the GPU's max surface area fall off the fast
    // path entirely — so the live-stroke view is capped at one screen and slid
    // under the pen at each stroke start instead of covering the whole canvas.
    // Finished strokes stay in canvas coordinates: motionEventToViewTransform only
    // affects wet-ink rendering, never the coordinates handed to onStrokesFinished.
    val displayMetrics = LocalContext.current.resources.displayMetrics
    val windowSize = remember(size, configuration) {
        IntSize(
            if (size.width > 0) minOf(size.width, displayMetrics.widthPixels) else displayMetrics.widthPixels,
            if (size.height > 0) minOf(size.height, displayMetrics.heightPixels) else displayMetrics.heightPixels,
        )
    }
    val windowTransform = remember { Matrix() }

    fun repositionInkWindow(x: Float, y: Float) {
        // Moving the window re-renders any wet ink still in the view with the new
        // transform, making it jump on screen — only slide while the view is idle
        // (no active stroke, nothing finished but not yet handed off to InkCanvas).
        if (inProgressStrokesView.hasUnfinishedStrokes() ||
            inProgressStrokesView.getFinishedStrokes().isNotEmpty()
        ) {
            return
        }
        val maxX = maxOf(0f, (size.width - windowSize.width).toFloat())
        val maxY = maxOf(0f, (size.height - windowSize.height).toFloat())
        val wx = (x - windowSize.width / 2f).coerceIn(0f, maxX)
        val wy = (y - windowSize.height / 2f).coerceIn(0f, maxY)
        inProgressStrokesView.translationX = wx
        inProgressStrokesView.translationY = wy
        windowTransform.setTranslate(-wx, -wy)
        inProgressStrokesView.motionEventToViewTransform = windowTransform
    }

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
        drawWithFinger = drawWithFinger,
    )

    // strokeAuthoringState is a key so a state recreated on rotation gets the
    // committed strokes reloaded into it instead of starting out empty.
    LaunchedEffect(strokeAuthoringState, strokes, size.width, size.height) {
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
                    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                        repositionInkWindow(event.x, event.y)
                    }
                    strokeAuthoringTouchListener?.onTouch(inProgressStrokesView, event) ?: false
                },
            strokeAuthoringState = strokeAuthoringState,
        )
        // key() forces the AndroidView to rebuild around the fresh view
        // instance after rotation — factory does not rerun on its own.
        key(inProgressStrokesView) {
            AndroidView(
                modifier = Modifier.size(
                    with(LocalDensity.current) {
                        DpSize(windowSize.width.toDp(), windowSize.height.toDp())
                    }
                ),
                factory = {
                    inProgressStrokesView.apply {
                        layoutParams = FrameLayout.LayoutParams(
                            windowSize.width,
                            windowSize.height,
                        )
                        motionEventToViewTransform = windowTransform
                    }
                },
                update = { canvasView ->
                    canvasView.motionEventToViewTransform = windowTransform
                    canvasView.invalidate()
                }
            )
        }
    }
}
