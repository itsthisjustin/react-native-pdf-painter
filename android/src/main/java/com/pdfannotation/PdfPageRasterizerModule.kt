package com.pdfannotation

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Android counterpart of the iOS PdfPageRasterizer: renders every page of a
 * PDF to a PNG in outputDir, scaled so the longest side is maxDimension
 * pixels, and resolves with the ordered list of file:// URIs.
 */
class PdfPageRasterizerModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getName() = "PdfPageRasterizer"

    @ReactMethod
    fun renderPdfToImages(pdfPath: String, outputDir: String, maxDimension: Double, promise: Promise) {
        executor.execute {
            var fd: ParcelFileDescriptor? = null
            var renderer: PdfRenderer? = null
            try {
                val pdfFile = File(stripFileScheme(pdfPath))
                if (!pdfFile.exists()) {
                    promise.reject("pdf_load_failed", "Could not open PDF at ${pdfFile.path}")
                    return@execute
                }
                val outDir = File(stripFileScheme(outputDir))
                if (!outDir.exists() && !outDir.mkdirs()) {
                    promise.reject("pdf_output_dir_failed", "Could not create ${outDir.path}")
                    return@execute
                }

                fd = ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(fd)
                val maxDim = if (maxDimension > 0) maxDimension else 2048.0
                val uris = Arguments.createArray()

                for (i in 0 until renderer.pageCount) {
                    renderer.openPage(i).use { page ->
                        if (page.width <= 0 || page.height <= 0) {
                            throw IllegalStateException("Page $i has invalid bounds")
                        }
                        val scale = maxDim / maxOf(page.width, page.height)
                        val width = Math.round(page.width * scale).toInt()
                        val height = Math.round(page.height * scale).toInt()
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        // PdfRenderer leaves unpainted areas transparent; PDF
                        // pages assume a white backdrop (matches iOS PDFKit).
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                        val outFile = File(outDir, "pdfpage_$i.png")
                        FileOutputStream(outFile).use { stream ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        }
                        bitmap.recycle()
                        uris.pushString("file://${outFile.absolutePath}")
                    }
                }
                promise.resolve(uris)
            } catch (e: Exception) {
                promise.reject("pdf_render_failed", e.message, e)
            } finally {
                try {
                    renderer?.close()
                    fd?.close()
                } catch (_: Exception) {}
            }
        }
    }

    private fun stripFileScheme(path: String): String =
        if (path.startsWith("file://")) Uri.decode(path.removePrefix("file://")) else path

    companion object {
        private val executor = Executors.newSingleThreadExecutor()
    }
}
