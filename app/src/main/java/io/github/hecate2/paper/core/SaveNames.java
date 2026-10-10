package io.github.hecate2.paper.core;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** Default filename generation and validation for the save dialog. */
public final class SaveNames {

    public static final String DEFAULT_EXT = ".txt";

    private SaveNames() {
    }

    /** Default name: 未命名_yyyyMMdd_HHmmss.txt */
    public static String defaultFileName(long epochMillis) {
        SimpleDateFormat fmt = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US);
        return "未命名_" + fmt.format(new Date(epochMillis)) + DEFAULT_EXT;
    }

    /**
     * Sanitizes a user-typed file name: strips path separators and control chars.
     * Returns "" when nothing usable remains.
     */
    public static String sanitize(String name) {
        if (name == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder(name.length());
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (c == '/' || c == '\\' || c == '\0' || c < 0x20) {
                continue;
            }
            sb.append(c);
        }
        String out = sb.toString().trim();
        if (out.equals(".") || out.equals("..")) {
            return "";
        }
        return out;
    }

    /** True if the name is valid for saving. */
    public static boolean isValid(String name) {
        return !sanitize(name).isEmpty();
    }

    /** True if the target file already exists. */
    public static boolean exists(File dir, String name) {
        return new File(dir, sanitize(name)).isFile();
    }

    /** Appends .txt when the user did not provide any extension. */
    public static String ensureTxtExtension(String name) {
        String s = sanitize(name);
        if (s.isEmpty()) {
            return "";
        }
        int dot = s.lastIndexOf('.');
        // No dot, or dot is the first char (hidden file without extension)
        if (dot <= 0) {
            return s + DEFAULT_EXT;
        }
        return s;
    }

    /** Directory writability probe used before showing the save dialog. */
    public static boolean isWritable(File dir) {
        return dir != null && dir.isDirectory() && dir.canWrite();
    }
}
