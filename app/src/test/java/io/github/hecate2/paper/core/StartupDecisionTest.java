package io.github.hecate2.paper.core;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.IOException;

import static org.junit.Assert.assertEquals;

public class StartupDecisionTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private String existingFile() throws IOException {
        File f = tmp.newFile("note.txt");
        return f.getAbsolutePath();
    }

    private String existingDir() throws IOException {
        return tmp.newFolder("notes").getAbsolutePath();
    }

    // ---- NEW_EMPTY ----

    @Test
    public void newEmptyAlwaysStartsScratch() {
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_NEW_EMPTY, "/any/file.txt", false, "/any"));
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_NEW_EMPTY, "", true, ""));
    }

    // ---- LAST_FILE ----

    @Test
    public void lastFileOpensExistingFile() throws Exception {
        String path = existingFile();
        assertEquals(StartupDecision.Target.OPEN_FILE,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, path, false, tmp.getRoot().getPath()));
    }

    @Test
    public void lastFileScratchFallsBackToDirectory() throws Exception {
        String dir = existingDir();
        assertEquals(StartupDecision.Target.BROWSER,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, "", true, dir));
    }

    @Test
    public void lastFileScratchNeverOpensPreviousPath() throws Exception {
        // Requirement: if the last file was an unsaved new file, open an empty file.
        String path = existingFile();
        String dir = existingDir();
        assertEquals(StartupDecision.Target.BROWSER,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, path, true, dir));
    }

    @Test
    public void lastFileScratchWithoutDirectoryOpensScratch() {
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, "/gone.txt", true, ""));
    }

    @Test
    public void missingLastFileFallsBackToDirectory() throws Exception {
        String dir = existingDir();
        assertEquals(StartupDecision.Target.BROWSER,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE,
                        "/does/not/exist.txt", false, dir));
    }

    @Test
    public void missingEverythingOpensScratch() {
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE,
                        "/gone.txt", false, "/also-gone"));
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, null, false, null));
    }

    // ---- LAST_DIR ----

    @Test
    public void lastDirOpensBrowser() throws Exception {
        String dir = existingDir();
        assertEquals(StartupDecision.Target.BROWSER,
                StartupDecision.decide(StartupDecision.MODE_LAST_DIR, "/f.txt", false, dir));
    }

    @Test
    public void lastDirScratchAlsoOpensBrowser() throws Exception {
        String dir = existingDir();
        assertEquals(StartupDecision.Target.BROWSER,
                StartupDecision.decide(StartupDecision.MODE_LAST_DIR, "", true, dir));
    }

    @Test
    public void lastDirMissingOpensScratch() {
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_DIR, "", false, "/gone"));
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_DIR, "", false, ""));
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_DIR, "", false, null));
    }

    // ---- robustness ----

    @Test
    public void unknownModeFallsBackToScratch() {
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide("WHAT", "/f.txt", false, "/d"));
    }

    @Test
    public void filePathPointingToDirectoryIsNotOpened() throws Exception {
        String dir = existingDir();
        assertEquals(StartupDecision.Target.SCRATCH,
                StartupDecision.decide(StartupDecision.MODE_LAST_FILE, dir, false, "/gone"));
    }
}
