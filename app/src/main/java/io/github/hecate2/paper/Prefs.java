package io.github.hecate2.paper;

import android.content.Context;
import android.content.SharedPreferences;

import io.github.hecate2.paper.core.EncodingDetector;
import io.github.hecate2.paper.core.StartupDecision;

/** Typed wrapper over SharedPreferences for all persisted state and settings. */
public final class Prefs {

    private static final String NAME = "paper_prefs";

    public static final String KEY_LAST_FILE = "lastFilePath";
    public static final String KEY_LAST_DIR = "lastDirectory";
    public static final String KEY_LAST_IS_SCRATCH = "lastIsScratch";
    public static final String KEY_STARTUP_MODE = "startupMode";
    public static final String KEY_AUTOSAVE_SEC = "autosaveIntervalSec";
    public static final String KEY_FONT_SIZE = "fontSizeSp";
    public static final String KEY_SHOW_LINE_NUMBERS = "showLineNumbers";
    public static final String KEY_WORD_WRAP = "wordWrap";
    public static final String KEY_DEFAULT_ENCODING = "defaultEncoding";
    public static final String KEY_BROWSER_SORT = "browserSort";
    public static final String KEY_BROWSER_SORT_DESC = "browserSortDesc";

    public static final int DEFAULT_FONT_SIZE = 16;

    private final SharedPreferences sp;

    public Prefs(Context context) {
        sp = context.getApplicationContext().getSharedPreferences(NAME, Context.MODE_PRIVATE);
    }

    // ---- last state ----

    public String lastFilePath() {
        return sp.getString(KEY_LAST_FILE, "");
    }

    public String lastDirectory() {
        return sp.getString(KEY_LAST_DIR, "");
    }

    public boolean lastIsScratch() {
        return sp.getBoolean(KEY_LAST_IS_SCRATCH, true);
    }

    /** Records which file/dir was just active (called after open/save). */
    public void recordOpened(String path, boolean isScratch) {
        String dir = "";
        if (path != null && !path.isEmpty()) {
            int i = path.lastIndexOf('/');
            if (i > 0) {
                dir = path.substring(0, i);
            }
        }
        sp.edit()
                .putString(KEY_LAST_FILE, path == null ? "" : path)
                .putBoolean(KEY_LAST_IS_SCRATCH, isScratch)
                .putString(KEY_LAST_DIR, dir.isEmpty() ? lastDirectory() : dir)
                .apply();
    }

    /** Records a directory the user browsed/picked (no file). */
    public void recordDirectory(String dir) {
        if (dir != null && !dir.isEmpty()) {
            sp.edit().putString(KEY_LAST_DIR, dir).apply();
        }
    }

    // ---- settings ----

    public String startupMode() {
        return sp.getString(KEY_STARTUP_MODE, StartupDecision.MODE_LAST_FILE);
    }

    public void setStartupMode(String mode) {
        sp.edit().putString(KEY_STARTUP_MODE, mode).apply();
    }

    /** 0 = off, otherwise seconds between autosaves. */
    public int autosaveIntervalSec() {
        return sp.getInt(KEY_AUTOSAVE_SEC, 10);
    }

    public void setAutosaveIntervalSec(int sec) {
        sp.edit().putInt(KEY_AUTOSAVE_SEC, sec).apply();
    }

    public int fontSizeSp() {
        return sp.getInt(KEY_FONT_SIZE, DEFAULT_FONT_SIZE);
    }

    public void setFontSizeSp(int size) {
        sp.edit().putInt(KEY_FONT_SIZE, Math.max(10, Math.min(32, size))).apply();
    }

    public boolean showLineNumbers() {
        return sp.getBoolean(KEY_SHOW_LINE_NUMBERS, true);
    }

    public void setShowLineNumbers(boolean show) {
        sp.edit().putBoolean(KEY_SHOW_LINE_NUMBERS, show).apply();
    }

    public boolean wordWrap() {
        return sp.getBoolean(KEY_WORD_WRAP, true);
    }

    public void setWordWrap(boolean wrap) {
        sp.edit().putBoolean(KEY_WORD_WRAP, wrap).apply();
    }

    /** One of EncodingDetector.USER_CHOICES; AUTO means detect per file. */
    public String defaultEncoding() {
        return sp.getString(KEY_DEFAULT_ENCODING, EncodingDetector.AUTO);
    }

    public void setDefaultEncoding(String charsetName) {
        sp.edit().putString(KEY_DEFAULT_ENCODING, charsetName).apply();
    }

    // ---- file browser ----

    /** One of "name" / "size" / "date" / "type". */
    public String browserSort() {
        return sp.getString(KEY_BROWSER_SORT, "name");
    }

    public void setBrowserSort(String field) {
        sp.edit().putString(KEY_BROWSER_SORT, field).apply();
    }

    public boolean browserSortDesc() {
        return sp.getBoolean(KEY_BROWSER_SORT_DESC, false);
    }

    public void setBrowserSortDesc(boolean desc) {
        sp.edit().putBoolean(KEY_BROWSER_SORT_DESC, desc).apply();
    }
}
