package com.izhaanintellect.sotto

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream

/** A failure reported to Dart as a `PlatformException` with this [code]. */
class BridgeException(val code: String, message: String) : Exception(message)

/**
 * Received files leaving the app: opening a decrypted copy in another app,
 * and saving a file to Downloads.
 *
 * The MIME type is never taken from the caller: it comes from the sender's
 * file name, so it is derived here from the (sanitized) name's extension.
 * Types that would install, run or render active content are refused.
 *
 * Error codes (PlatformException.code on the Dart side):
 * - `not_found`: the file is missing, or not a decrypted open copy.
 * - `blocked_type`: the file type is not allowed to be opened (apk, html, ...).
 * - `no_app`: no installed app can open this type.
 * - `permission_required`: Android 9 or older, storage permission not granted
 *   yet; the system prompt has been shown when a window was available. Retry
 *   after the user answers.
 * - `failed`: anything else.
 */
object Files {
    /** Same folder as ReceivedFileStore._openFolder (in getTemporaryDirectory()). */
    private const val OPEN_FOLDER = "received_open"

    /** The random folder ReceivedFileStore.writeOpenCopy makes per copy. */
    private val OPEN_COPY_FOLDER = Regex("^[0-9a-f]{16}$")

    /** Open copies older than this are deleted the next time a file is opened. */
    private const val OPEN_COPY_MAX_AGE_MS = 60L * 60L * 1000L

    private const val FALLBACK_MIME = "application/octet-stream"

    private const val STORAGE_REQUEST = 2

    /** Installers, executables, scripts and web content. */
    private val BLOCKED_EXTENSIONS = setOf(
        // Android packages and code
        "apk", "apks", "apkm", "xapk", "aab", "dex", "jar",
        // Web content that runs script when rendered
        "html", "htm", "xhtml", "xht", "shtml", "mht", "mhtml", "svg", "svgz", "xml", "xsl",
        "hta", "swf",
        // Executables, installers and scripts
        "exe", "msi", "msix", "appx", "com", "scr", "pif", "cpl", "msc", "dll", "so", "elf",
        "bin", "run", "app", "dmg", "pkg", "deb", "rpm",
        "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "mjs", "cjs", "jse", "wsf", "wsh",
        "sh", "bash", "zsh", "csh", "ksh", "command", "php", "pl",
        "lnk", "url", "desktop", "reg", "jnlp", "inf",
    )

    private val BLOCKED_MIMES = setOf(
        "application/vnd.android.package-archive",
        "application/java-archive",
        "application/x-java-archive",
        "text/html",
        "application/xhtml+xml",
        "image/svg+xml",
        "text/xml",
        "application/xml",
        "text/javascript",
        "application/javascript",
        "application/ecmascript",
        "application/hta",
        "application/x-msdownload",
        "application/x-msdos-program",
        "application/x-msi",
        "application/vnd.microsoft.portable-executable",
    )

    private fun extensionOf(name: String): String =
        if (name.contains('.')) name.substringAfterLast('.').lowercase() else ""

    /** The type for [name], from its extension only. */
    fun mimeFor(name: String): String {
        val ext = extensionOf(name)
        if (ext.isEmpty()) return FALLBACK_MIME
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)?.lowercase()
            ?: FALLBACK_MIME
    }

    private fun isBlocked(name: String, mime: String): Boolean {
        if (extensionOf(name) in BLOCKED_EXTENSIONS) return true
        if (mime in BLOCKED_MIMES) return true
        // application/x-executable, x-sharedlib, x-sh, x-shellscript, x-javascript, ...
        if (mime.startsWith("application/x-") &&
            (mime.contains("executable") || mime.contains("sharedlib") ||
                mime.contains("javascript") || mime.contains("ecmascript") ||
                mime == "application/x-sh" || mime.contains("shellscript") ||
                mime.contains("csh") || mime.contains("msdownload") ||
                mime.contains("msdos") || mime.contains("msi") ||
                mime.contains("shockwave"))) return true
        return false
    }

    /**
     * A display name safe for Downloads: no path separators or control
     * characters, not hidden, not empty, and not too long.
     */
    fun sanitizeName(raw: String?): String {
        var name = (raw ?: "").substringAfterLast('/').substringAfterLast('\\')
        name = name.replace(Regex("[\\u0000-\\u001f\\u007f/\\\\:*?\"<>|]"), "_").trim()
        name = name.trimStart('.').trim()
        if (name.isEmpty()) name = "file"
        if (name.length > 120) {
            val ext = extensionOf(name)
            name = if (ext.isNotEmpty() && ext.length < 16) {
                name.substring(0, 120 - ext.length - 1) + "." + ext
            } else {
                name.substring(0, 120)
            }
        }
        return name
    }

    /** Opens a decrypted copy made by ReceivedFileStore.writeOpenCopy. */
    fun open(app: Context, path: String, start: (Intent) -> Unit): Boolean {
        val openRoot = File(app.cacheDir, OPEN_FOLDER).canonicalFile
        val file = File(path).canonicalFile
        // Only <cacheDir>/received_open/<16 hex>/<name>: never a recording or
        // anything else the provider could reach.
        val folder = file.parentFile
        if (folder == null || folder.parentFile != openRoot ||
            !OPEN_COPY_FOLDER.matches(folder.name) || !file.isFile) {
            throw BridgeException("not_found", "not an open copy")
        }
        deleteOldOpenCopies(openRoot, keep = folder)

        val mime = mimeFor(file.name)
        if (isBlocked(file.name, mime)) {
            throw BridgeException("blocked_type", "this file type cannot be opened")
        }
        val uri = FileProvider.getUriForFile(app, "${app.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            // The grant lasts only as long as the receiving activity: no
            // grantUriPermission(), which would persist until revoked.
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            start(intent)
        } catch (e: ActivityNotFoundException) {
            throw BridgeException("no_app", "no app can open this file")
        }
        return true
    }

    /** Removes open copies left from earlier opens (older than an hour). */
    private fun deleteOldOpenCopies(openRoot: File, keep: File) {
        val cutoff = System.currentTimeMillis() - OPEN_COPY_MAX_AGE_MS
        openRoot.listFiles()?.forEach { dir ->
            if (dir.isDirectory && dir != keep && OPEN_COPY_FOLDER.matches(dir.name) &&
                dir.lastModified() < cutoff) {
                try {
                    dir.deleteRecursively()
                } catch (_: Exception) {
                }
            }
        }
    }

    /**
     * Saves [bytes] (or the file at [path]) to Downloads as [rawName].
     * Returns the name it was saved under (Android 10+) or its path.
     */
    fun saveToDownloads(
        app: Context,
        activity: Activity?,
        bytes: ByteArray?,
        path: String?,
        rawName: String?,
    ): String {
        if (bytes == null && path == null) throw BridgeException("failed", "nothing to save")
        val name = sanitizeName(rawName?.takeIf { it.isNotBlank() } ?: path?.let { File(it).name })
        // Derived from the name, so MediaProvider keeps the name's extension
        // instead of appending one for a different, sender-chosen type.
        val mime = mimeFor(name)
        val openInput: () -> InputStream = {
            when {
                bytes != null -> ByteArrayInputStream(bytes)
                path != null && File(path).isFile -> File(path).inputStream()
                else -> throw BridgeException("not_found", "file not found")
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = app.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw BridgeException("failed", "could not create the download")
            try {
                val out = resolver.openOutputStream(uri)
                    ?: throw BridgeException("failed", "could not write the download")
                out.use { o -> openInput().use { it.copyTo(o) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
                if (e is BridgeException) throw e
                throw BridgeException("failed", e.message ?: "could not save")
            }
            // MediaProvider renames on a collision ("name (1).ext").
            var saved = name
            try {
                resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)
                    ?.use { c -> if (c.moveToFirst()) c.getString(0)?.let { saved = it } }
            } catch (_: Exception) {
            }
            return saved
        }

        // Android 9 and older: the public Downloads folder needs the
        // (maxSdkVersion 28) WRITE_EXTERNAL_STORAGE permission.
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED) {
            if (activity != null) {
                ActivityCompat.requestPermissions(activity,
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_REQUEST)
            }
            throw BridgeException("permission_required", "storage permission needed")
        }
        try {
            @Suppress("DEPRECATION")
            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (!downloadDir.exists()) downloadDir.mkdirs()
            val base = if (name.contains('.')) name.substringBeforeLast('.') else name
            val ext = if (name.contains('.')) ".${name.substringAfterLast('.')}" else ""
            var dest = File(downloadDir, name)
            var count = 1
            while (dest.exists()) {
                dest = File(downloadDir, "$base ($count)$ext")
                count++
            }
            dest.outputStream().use { o -> openInput().use { it.copyTo(o) } }
            MediaScannerConnection.scanFile(app, arrayOf(dest.absolutePath), arrayOf(mime), null)
            return dest.absolutePath
        } catch (e: BridgeException) {
            throw e
        } catch (e: Exception) {
            throw BridgeException("failed", e.message ?: "could not save")
        }
    }
}
