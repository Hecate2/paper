package io.github.hecate2.paper.core;

import org.junit.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class SearchEngineTest {

    // ---- plain find ----

    @Test
    public void findsAllPlainMatches() {
        int[] r = SearchEngine.findAll("abc abc abc", "abc", true, false, null);
        assertArrayEquals(new int[]{0, 3, 4, 7, 8, 11}, r);
    }

    @Test
    public void emptyQueryYieldsNothing() {
        assertArrayEquals(new int[0], SearchEngine.findAll("abc", "", true, false, null));
        assertArrayEquals(new int[0], SearchEngine.findAll("abc", null, true, false, null));
        assertArrayEquals(new int[0], SearchEngine.findAll(null, "a", true, false, null));
    }

    @Test
    public void noMatchYieldsNothing() {
        assertArrayEquals(new int[0], SearchEngine.findAll("hello", "xyz", true, false, null));
    }

    @Test
    public void caseSensitiveSearch() {
        int[] r = SearchEngine.findAll("Abc aBc abC", "abc", true, false, null);
        assertEquals(0, r.length);
        r = SearchEngine.findAll("abc abc", "abc", true, false, null);
        assertEquals(2, r.length / 2);
    }

    @Test
    public void caseInsensitiveSearchFindsAll() {
        int[] r = SearchEngine.findAll("Abc aBc abC ABC", "abc", false, false, null);
        assertArrayEquals(new int[]{0, 3, 4, 7, 8, 11, 12, 15}, r);
    }

    @Test
    public void unicodeCaseInsensitiveSearch() {
        int[] r = SearchEngine.findAll("Äöü ÄÖÜ", "äöü", false, false, null);
        assertEquals(2, r.length / 2);
    }

    @Test
    public void overlappingQueryTakesNonOverlappingMatches() {
        // "aaa" contains "aa" at 0 and 1; non-overlapping means only 0
        int[] r = SearchEngine.findAll("aaa", "aa", true, false, null);
        assertArrayEquals(new int[]{0, 2}, r);
    }

    @Test
    public void matchesAreSortedAndContiguous() {
        int[] r = SearchEngine.findAll("xaxbxaxbxax", "x", true, false, null);
        assertEquals(6, r.length / 2);
        for (int i = 1; i < r.length; i++) {
            assertTrue(r[i] >= r[i - 1]);
        }
    }

    // ---- regex find ----

    @Test
    public void findsRegexMatches() {
        int[] r = SearchEngine.findAll("a1 b22 c333", "[0-9]+", true, true, null);
        assertArrayEquals(new int[]{1, 2, 4, 6, 8, 11}, r);
    }

    @Test
    public void invalidRegexYieldsNothingInsteadOfThrowing() {
        assertArrayEquals(new int[0], SearchEngine.findAll("abc", "[unclosed", true, true, null));
    }

    @Test
    public void zeroWidthRegexDoesNotLoopForever() {
        int[] r = SearchEngine.findAll("abc", "x*", true, true, null);
        assertEquals(0, r.length);
    }

    @Test
    public void regexCaseInsensitive() {
        int[] r = SearchEngine.findAll("Hello hello HELLO", "hello", false, true, null);
        assertEquals(3, r.length / 2);
    }

    @Test
    public void dotallRegexMatchesAcrossNewlines() {
        int[] r = SearchEngine.findAll("a\nb", "a.b", true, true, null);
        assertArrayEquals(new int[]{0, 3}, r);
    }

    // ---- replace ----

    @Test
    public void replaceAllLiteral() {
        String out = SearchEngine.replaceAllLiteral("one two one two",
                SearchEngine.findAll("one two one two", "one", true, false, null), "1");
        assertEquals("1 two 1 two", out);
    }

    @Test
    public void replaceAllLiteralWithEmptyMatchesReturnsOriginal() {
        assertEquals("abc", SearchEngine.replaceAllLiteral("abc", new int[0], "x"));
        assertEquals("abc", SearchEngine.replaceAllLiteral("abc", null, "x"));
    }

    @Test
    public void replaceAllLiteralLongerReplacement() {
        String text = "a a a";
        String out = SearchEngine.replaceAllLiteral(text,
                SearchEngine.findAll(text, "a", true, false, null), "###");
        assertEquals("### ### ###", out);
    }

    @Test
    public void replaceAllLiteralShorterReplacement() {
        String text = "xxx";
        String out = SearchEngine.replaceAllLiteral(text,
                SearchEngine.findAll(text, "x", true, false, null), "");
        assertEquals("", out);
    }

    @Test
    public void replaceAllRegexWithGroups() {
        String out = SearchEngine.replaceAllRegex("John Smith", "(\\w+) (\\w+)", "$2 $1", true, false);
        assertEquals("Smith John", out);
    }

    @Test
    public void replaceAllRegexKeepsUnmatchedText() {
        String out = SearchEngine.replaceAllRegex("a1b2c", "[0-9]", "#", true, false);
        assertEquals("a#b#c", out);
    }

    @Test
    public void replaceAllRegexInvalidPatternReturnsOriginal() {
        assertEquals("abc", SearchEngine.replaceAllRegex("abc", "[bad", "x", true, false));
    }

    @Test
    public void replaceRangeSingle() {
        assertEquals("heXXo", SearchEngine.replaceRange("hello", 2, 4, "XX"));
        assertEquals("heXllo", SearchEngine.replaceRange("hello", 2, 2, "X"));
    }

    @Test
    public void replaceCurrentRegexExpandsGroups() {
        String out = SearchEngine.replaceCurrentRegex("John Smith", "(\\w+) (\\w+)",
                0, 10, "$2 $1", true, false);
        assertEquals("Smith John", out);
    }

    @Test
    public void replaceCurrentRegexFallsBackToLiteralWhenRangeNotAMatch() {
        String out = SearchEngine.replaceCurrentRegex("hello world", "world",
                0, 3, "X", true, false);
        assertEquals("Xlo world", out);
    }

    // ---- performance smoke ----

    @Test(timeout = 2000)
    public void plainSearchIsFastOnLargeText() {
        StringBuilder sb = new StringBuilder(2_000_000);
        for (int i = 0; i < 100_000; i++) {
            sb.append("line ").append(i).append(" filler text\n");
        }
        String text = sb.toString();
        int[] r = SearchEngine.findAll(text, "line 99999", true, false, null);
        assertTrue(r.length >= 2);
        // should take well under a second; the timeout guards regressions
    }

    @Test(timeout = 2000)
    public void replaceAllIsFastOnLargeText() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 200_000; i++) {
            sb.append("foo bar ");
        }
        String text = sb.toString();
        int[] matches = SearchEngine.findAll(text, "foo", true, false, null);
        assertEquals(200_000, matches.length / 2);
        String out = SearchEngine.replaceAllLiteral(text, matches, "qux");
        assertEquals(0, countOccurrences(out, "foo"));
        assertEquals(200_000, countOccurrences(out, "qux"));
    }

    @Test
    public void respectsResultCap() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < SearchEngine.MAX_RESULTS + 100; i++) {
            sb.append('a');
        }
        int[] r = SearchEngine.findAll(sb.toString(), "a", true, false, null);
        assertEquals(SearchEngine.MAX_RESULTS, r.length / 2);
    }

    @Test
    public void cancelFlagStopsSearch() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 500_000; i++) {
            sb.append('a');
        }
        boolean[] cancel = {true}; // cancelled before start
        int[] r = SearchEngine.findAll(sb.toString(), "a", true, false, cancel);
        assertEquals(0, r.length);
    }

    private static int countOccurrences(String text, String needle) {
        int count = 0;
        int idx = text.indexOf(needle);
        while (idx >= 0) {
            count++;
            idx = text.indexOf(needle, idx + needle.length());
        }
        return count;
    }

    // ---- whole word ----

    @Test
    public void wholeWordSkipsEmbeddedMatches() {
        int[] r = SearchEngine.findAll("cat category cat", "cat", true, false, true, null);
        // only the standalone "cat" at 0 and 13
        assertEquals(4, r.length);
        assertEquals(0, r[0]);
        assertEquals(13, r[2]);
    }

    @Test
    public void wholeWordMatchesAtStringEdges() {
        int[] r = SearchEngine.findAll("cat", "cat", true, false, true, null);
        assertArrayEquals(new int[]{0, 3}, r);
    }

    @Test
    public void wholeWordTreatsUnderscoreAndDigitsAsWordChars() {
        assertEquals(0, SearchEngine.findAll("cat_x cat1", "cat", true, false, true, null).length);
        // without whole word both are found
        assertEquals(4, SearchEngine.findAll("cat_x cat1", "cat", true, false, false, null).length);
    }

    @Test
    public void wholeWordCaseInsensitive() {
        int[] r = SearchEngine.findAll("Cat cat CATS", "cat", false, false, true, null);
        assertEquals(4, r.length);
        assertEquals(0, r[0]);
        assertEquals(4, r[2]);
    }

    @Test
    public void wholeWordWorksForCjkText() {
        int[] r = SearchEngine.findAll("中文 中文测试 中文", "中文", true, false, true, null);
        assertEquals(4, r.length);
        assertEquals(0, r[0]);
        assertEquals(8, r[2]);
    }

    @Test
    public void wholeWordRegexUsesBoundariesButKeepsGroups() {
        int[] r = SearchEngine.findAll("abc abcd abc", "ab.", true, true, true, null);
        assertEquals(4, r.length);
        assertEquals(0, r[0]);
        assertEquals(9, r[2]);
        String out = SearchEngine.replaceAllRegex("abc abcd abc", "(ab.)", "<$1>", true, true);
        assertEquals("<abc> abcd <abc>", out);
    }

    @Test
    public void wholeWordRegexCaseInsensitive() {
        int[] r = SearchEngine.findAll("Foo foo FOOD", "foo", false, true, true, null);
        assertEquals(4, r.length);
        assertEquals(0, r[0]);
        assertEquals(4, r[2]);
    }

    @Test
    public void wholeWordReplaceAllLiteralOnlyTouchesWholeWords() {
        int[] m = SearchEngine.findAll("cat category cat", "cat", true, false, true, null);
        assertEquals("dog category dog",
                SearchEngine.replaceAllLiteral("cat category cat", m, "dog"));
    }

    @Test
    public void unicodeRegexClassesIncludeCjk() {
        // UNICODE_CHARACTER_CLASS makes \w cover CJK, so a regex search still works
        int[] r = SearchEngine.findAll("中文", "\\w+", true, true, false, null);
        assertArrayEquals(new int[]{0, 2}, r);
    }
}
