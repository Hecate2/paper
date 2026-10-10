package io.github.hecate2.paper.core;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Crash-safe file writing: write to a temp file, fsync, keep the previous
 * version as .bak, then atomically rename temp onto the target.
 * At any crash point the disk holds either the complete old file or the
 * complete new file, and .bak is a second copy of the previous version.
 */
public final class AtomicFileWriter {

    public static final String TMP_SUFFIX = ".tmp";
    public static final String BAK_SUFFIX = ".bak";

    private AtomicFileWriter() {
    }

    /** Writes data to target atomically, preserving the previous version as target.bak. */
    public static void write(File target, byte[] data) throws IOException {
        File dir = target.getParentFile();
        if (dir != null && !dir.isDirectory() && !dir.mkdirs()) {
            throw new IOException("Cannot create directory: " + dir);
        }
        File tmp = new File(target.getPath() + TMP_SUFFIX);
        try {
            FileOutputStream out = new FileOutputStream(tmp);
            try {
                out.write(data);
                out.flush();
                out.getFD().sync();
            } finally {
                out.close();
            }
            if (target.isFile()) {
                copyFile(target, new File(target.getPath() + BAK_SUFFIX));
            }
            if (!tmp.renameTo(target)) {
                // Fall back to a non-atomic replace; still leaves .bak in place.
                copyFile(tmp, target);
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        } catch (IOException | RuntimeException e) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw e;
        }
    }

    /** Restores target from target.bak (keeps the damaged/undesired file as .bak2-less swap). */
    public static boolean restoreFromBackup(File target) throws IOException {
        File bak = new File(target.getPath() + BAK_SUFFIX);
        if (!bak.isFile()) {
            return false;
        }
        copyFile(bak, target);
        return true;
    }

    public static boolean backupExists(File target) {
        return new File(target.getPath() + BAK_SUFFIX).isFile();
    }

    static void copyFile(File src, File dst) throws IOException {
        InputStream in = new FileInputStream(src);
        try {
            FileOutputStream out = new FileOutputStream(dst);
            try {
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                out.flush();
                out.getFD().sync();
            } finally {
                out.close();
            }
        } finally {
            in.close();
        }
    }

    /** Reads the whole file; refuses files larger than maxBytes (caller applies policy first). */
    public static byte[] readAtMost(File file, long maxBytes) throws IOException {
        long len = file.length();
        if (len > maxBytes) {
            throw new IOException("File too large: " + len + " > " + maxBytes);
        }
        byte[] data = new byte[(int) len];
        InputStream in = new FileInputStream(file);
        try {
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n < 0) {
                    break;
                }
                off += n;
            }
            if (off < data.length) {
                byte[] trimmed = new byte[off];
                System.arraycopy(data, 0, trimmed, 0, off);
                data = trimmed;
            }
            return data;
        } finally {
            in.close();
        }
    }

    /** Reads exactly the first maxBytes of the file (used for head previews and sniffing). */
    public static byte[] readHead(File file, long maxBytes) throws IOException {
        byte[] data = new byte[(int) Math.min(file.length(), maxBytes)];
        InputStream in = new FileInputStream(file);
        try {
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n < 0) {
                    break;
                }
                off += n;
            }
            if (off < data.length) {
                byte[] trimmed = new byte[off];
                System.arraycopy(data, 0, trimmed, 0, off);
                data = trimmed;
            }
            return data;
        } finally {
            in.close();
        }
    }

    static void writeFully(OutputStream out, byte[] data) throws IOException {
        out.write(data);
        out.flush();
    }
}
