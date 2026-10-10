package io.github.hecate2.paper.core;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class SaveNamesTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    @Test
    public void defaultNameHasTxtExtensionAndTimestamp() {
        long t = 1700000000000L;
        String expected = "未命名_" + new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
                .format(new Date(t)) + ".txt";
        assertEquals(expected, SaveNames.defaultFileName(t));
        assertTrue(SaveNames.defaultFileName(t).endsWith(".txt"));
    }

    @Test
    public void sanitizeStripsPathSeparators() {
        // separators are removed, never interpreted as paths
        assertEquals("evil..evil.txt", SaveNames.sanitize("evil/../evil.txt"));
        assertEquals("ab.txt", SaveNames.sanitize("a/b.txt"));
        assertEquals("name.txt", SaveNames.sanitize("name.txt"));
        assertEquals("ab", SaveNames.sanitize("a\\b"));
        assertEquals("C:name.txt", SaveNames.sanitize("C:name.txt"));
    }

    @Test
    public void sanitizeRemovesControlChars() {
        assertEquals("ab", SaveNames.sanitize("a\u0000\u0001b"));
        assertEquals("ab", SaveNames.sanitize("a\nb"));
    }

    @Test
    public void sanitizeHandlesEdgeCases() {
        assertEquals("", SaveNames.sanitize(null));
        assertEquals("", SaveNames.sanitize("   "));
        assertEquals("", SaveNames.sanitize("."));
        assertEquals("", SaveNames.sanitize(".."));
        assertEquals("", SaveNames.sanitize("/"));
        assertEquals("...", SaveNames.sanitize("...")); // not a traversal
    }

    @Test
    public void isValidMirrorsSanitize() {
        assertTrue(SaveNames.isValid("ok.txt"));
        assertTrue(SaveNames.isValid("  ok  "));
        assertFalse(SaveNames.isValid(""));
        assertFalse(SaveNames.isValid(".."));
        assertFalse(SaveNames.isValid(null));
    }

    @Test
    public void ensureTxtExtensionAddsWhenMissing() {
        assertEquals("note.txt", SaveNames.ensureTxtExtension("note"));
        assertEquals("note.md", SaveNames.ensureTxtExtension("note.md"));
        assertEquals("archive.tar.gz", SaveNames.ensureTxtExtension("archive.tar.gz"));
        assertEquals(".hidden.txt", SaveNames.ensureTxtExtension(".hidden"));
        assertEquals("", SaveNames.ensureTxtExtension(""));
        assertEquals("", SaveNames.ensureTxtExtension(null));
    }

    @Test
    public void existsChecksDirectory() throws Exception {
        File dir = tmp.newFolder("docs");
        assertFalse(SaveNames.exists(dir, "a.txt"));
        File f = new File(dir, "a.txt");
        assertTrue(f.createNewFile());
        assertTrue(SaveNames.exists(dir, "a.txt"));
    }

    @Test
    public void writableChecks() throws Exception {
        File dir = tmp.newFolder();
        assertTrue(SaveNames.isWritable(dir));
        assertFalse(SaveNames.isWritable(null));
        assertFalse(SaveNames.isWritable(new File(dir, "missing")));
    }
}
