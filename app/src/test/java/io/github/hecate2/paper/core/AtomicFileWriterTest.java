package io.github.hecate2.paper.core;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class AtomicFileWriterTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    private File target;

    @Before
    public void setUp() throws IOException {
        target = new File(tmp.getRoot(), "note.txt");
    }

    private static byte[] bytes(String s) {
        return s.getBytes(StandardCharsets.UTF_8);
    }

    private static String read(File f) throws IOException {
        return new String(AtomicFileWriter.readAtMost(f, Long.MAX_VALUE), StandardCharsets.UTF_8);
    }

    @Test
    public void writesNewFile() throws Exception {
        AtomicFileWriter.write(target, bytes("hello"));
        assertTrue(target.isFile());
        assertEquals("hello", read(target));
        // no temp file left behind
        assertFalse(new File(target.getPath() + AtomicFileWriter.TMP_SUFFIX).exists());
        // first write has no previous version, so no backup
        assertFalse(AtomicFileWriter.backupExists(target));
    }

    @Test
    public void secondWriteKeepsBackupOfPreviousVersion() throws Exception {
        AtomicFileWriter.write(target, bytes("v1"));
        AtomicFileWriter.write(target, bytes("v2"));
        assertEquals("v2", read(target));
        File bak = new File(target.getPath() + AtomicFileWriter.BAK_SUFFIX);
        assertTrue(bak.isFile());
        assertEquals("v1", read(bak));
    }

    @Test
    public void thirdWriteOverwritesBackup() throws Exception {
        AtomicFileWriter.write(target, bytes("v1"));
        AtomicFileWriter.write(target, bytes("v2"));
        AtomicFileWriter.write(target, bytes("v3"));
        assertEquals("v3", read(target));
        assertEquals("v2", read(new File(target.getPath() + AtomicFileWriter.BAK_SUFFIX)));
    }

    @Test
    public void restoresFromBackup() throws Exception {
        AtomicFileWriter.write(target, bytes("good"));
        AtomicFileWriter.write(target, bytes("bad"));
        assertTrue(AtomicFileWriter.restoreFromBackup(target));
        assertEquals("good", read(target));
    }

    @Test
    public void restoreWithoutBackupReturnsFalse() throws Exception {
        assertFalse(AtomicFileWriter.restoreFromBackup(target));
    }

    @Test
    public void failedWriteLeavesOriginalIntact() throws Exception {
        AtomicFileWriter.write(target, bytes("original"));
        // Sabotage: make the temp path an unwritable directory so writing tmp fails.
        File sabotage = new File(target.getPath() + AtomicFileWriter.TMP_SUFFIX);
        assertTrue(sabotage.mkdirs());
        try {
            AtomicFileWriter.write(target, bytes("new content"));
            org.junit.Assert.fail("expected IOException");
        } catch (IOException expected) {
            // ok
        }
        assertEquals("original", read(target));
        // the writer cleaned up the sabotage dir itself, or it is now empty
        assertFalse(sabotage.exists());
    }

    @Test
    public void writesIntoNestedNewDirectory() throws Exception {
        File nested = new File(tmp.getRoot(), "a/b/c/file.txt");
        AtomicFileWriter.write(nested, bytes("deep"));
        assertTrue(nested.isFile());
        assertEquals("deep", read(nested));
    }

    @Test
    public void readAtMostRefusesTooLargeFile() throws Exception {
        AtomicFileWriter.write(target, bytes("0123456789"));
        try {
            AtomicFileWriter.readAtMost(target, 5);
            org.junit.Assert.fail("expected IOException");
        } catch (IOException expected) {
            // ok
        }
    }

    @Test
    public void readHeadTruncates() throws Exception {
        AtomicFileWriter.write(target, bytes("0123456789"));
        byte[] head = AtomicFileWriter.readHead(target, 4);
        assertArrayEquals(bytes("0123"), head);
    }

    @Test
    public void readAtMostHandlesEmptyFile() throws Exception {
        assertTrue(target.createNewFile());
        byte[] data = AtomicFileWriter.readAtMost(target, 100);
        assertEquals(0, data.length);
    }

    @Test
    public void binaryContentSurvivesRoundTrip() throws Exception {
        byte[] data = new byte[]{0, 1, 2, 3, -1, -2, 0, 42};
        AtomicFileWriter.write(target, data);
        assertArrayEquals(data, AtomicFileWriter.readAtMost(target, Long.MAX_VALUE));
    }

    @Test
    public void sequentialWritesAlwaysExposeCompleteVersions() throws Exception {
        // Simulates "save crash" semantics: every observed read is one complete version.
        AtomicFileWriter.write(target, bytes("v0"));
        String[] versions = {"aaaa", "bbbbbb", "ccccccccc", "dddddddddd"};
        for (String v : versions) {
            AtomicFileWriter.write(target, bytes(v));
            assertEquals("observed a torn/partial write", v, read(target));
        }
    }

    @Test
    public void copyFileCopiesContent() throws Exception {
        File src = new File(tmp.getRoot(), "src.bin");
        File dst = new File(tmp.getRoot(), "dst.bin");
        try (FileOutputStream out = new FileOutputStream(src)) {
            out.write(bytes("copy me"));
        }
        AtomicFileWriter.copyFile(src, dst);
        assertEquals("copy me", read(dst));
    }
}
