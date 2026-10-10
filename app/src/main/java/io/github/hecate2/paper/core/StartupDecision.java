package io.github.hecate2.paper.core;

import java.io.File;

/**
 * Pure startup routing decision, extracted so it is unit-testable.
 * Rules (see DESIGN.md §3.2):
 *  - NEW_EMPTY  -> scratch editor
 *  - LAST_FILE  -> open lastFilePath unless it is an unsaved scratch or missing;
 *                  fall back to browser(lastDirectory) if that exists, else scratch
 *  - LAST_DIR   -> browser(lastDirectory) if it exists, else scratch
 *  A cold start with an unsaved scratch always yields a fresh empty editor.
 */
public final class StartupDecision {

    public enum Target {
        SCRATCH, OPEN_FILE, BROWSER
    }

    public static final String MODE_NEW_EMPTY = "NEW_EMPTY";
    public static final String MODE_LAST_FILE = "LAST_FILE";
    public static final String MODE_LAST_DIR = "LAST_DIR";

    private StartupDecision() {
    }

    public static Target decide(String startupMode,
                                String lastFilePath,
                                boolean lastIsScratch,
                                String lastDirectory) {
        if (MODE_LAST_FILE.equals(startupMode)) {
            if (!lastIsScratch && lastFilePath != null && !lastFilePath.isEmpty()
                    && new File(lastFilePath).isFile()) {
                return Target.OPEN_FILE;
            }
            if (lastDirectory != null && !lastDirectory.isEmpty()
                    && new File(lastDirectory).isDirectory()) {
                return Target.BROWSER;
            }
            return Target.SCRATCH;
        }
        if (MODE_LAST_DIR.equals(startupMode)) {
            if (lastDirectory != null && !lastDirectory.isEmpty()
                    && new File(lastDirectory).isDirectory()) {
                return Target.BROWSER;
            }
            return Target.SCRATCH;
        }
        // NEW_EMPTY and anything unknown
        return Target.SCRATCH;
    }
}
