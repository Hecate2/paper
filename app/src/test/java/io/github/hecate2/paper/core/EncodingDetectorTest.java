package io.github.hecate2.paper.core;

import org.junit.Test;

import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class EncodingDetectorTest {

    private static byte[] b(String s, String charset) {
        return s.getBytes(Charset.forName(charset));
    }

    // ---- detection ----

    @Test
    public void detectsUtf8Bom() {
        byte[] data = new byte[]{(byte) 0xEF, (byte) 0xBB, (byte) 0xBF, 'h', 'i'};
        assertEquals(EncodingDetector.UTF_8, EncodingDetector.detect(data));
    }

    @Test
    public void detectsUtf16Bom() {
        byte[] le = new byte[]{(byte) 0xFF, (byte) 0xFE, 'a', 0};
        byte[] be = new byte[]{(byte) 0xFE, (byte) 0xFF, 0, 'a'};
        assertEquals(EncodingDetector.UTF_16LE, EncodingDetector.detect(le));
        assertEquals(EncodingDetector.UTF_16BE, EncodingDetector.detect(be));
    }

    @Test
    public void detectsPlainUtf8() {
        assertEquals(EncodingDetector.UTF_8,
                EncodingDetector.detect(b("你好，world", "UTF-8")));
    }

    @Test
    public void detectsGb18030ForChineseGbkBytes() {
        byte[] data = b("你好世界", "GB18030");
        assertEquals(EncodingDetector.GB18030, EncodingDetector.detect(data));
    }

    @Test
    public void asciiFallsBackToUtf8() {
        assertEquals(EncodingDetector.UTF_8,
                EncodingDetector.detect("plain ascii text".getBytes(StandardCharsets.US_ASCII)));
    }

    @Test
    public void emptyFileIsUtf8() {
        assertEquals(EncodingDetector.UTF_8, EncodingDetector.detect(new byte[0]));
    }

    @Test
    public void resolveCharsetHonorsUserChoice() {
        assertEquals(EncodingDetector.GBK,
                EncodingDetector.resolveCharset(EncodingDetector.GBK, b("x", "UTF-8")));
    }

    @Test
    public void resolveCharsetAutoDetects() {
        assertEquals(EncodingDetector.GB18030,
                EncodingDetector.resolveCharset(EncodingDetector.AUTO, b("中文", "GB18030")));
    }

    @Test
    public void invalidUserChoiceFallsBackToDetection() {
        // not a real charset name
        assertEquals(EncodingDetector.UTF_8,
                EncodingDetector.resolveCharset("NOT-A-CHARSET", "abc".getBytes(StandardCharsets.UTF_8)));
    }

    // ---- binary sniffing ----

    @Test
    public void detectsNulAsBinary() {
        assertTrue(EncodingDetector.looksBinary(new byte[]{'a', 0, 'b'}));
        assertFalse(EncodingDetector.looksBinary(new byte[]{'a', 'b', 'c'}));
        assertFalse(EncodingDetector.looksBinary(new byte[0]));
    }

    @Test
    public void sniffIsLimitedToFirst8k() {
        byte[] head = new byte[9000];
        java.util.Arrays.fill(head, (byte) 'x');
        head[8500] = 0; // NUL beyond the sniff window
        assertFalse(EncodingDetector.looksBinary(head));
        head[100] = 0;
        assertTrue(EncodingDetector.looksBinary(head));
    }

    // ---- decode / encode round trips ----

    @Test
    public void utf8RoundTrip() {
        String s = "白纸 White Paper — 中文\n第二行\t制表符";
        byte[] enc = EncodingDetector.encode(s, EncodingDetector.UTF_8);
        assertEquals(s, EncodingDetector.decode(enc, EncodingDetector.UTF_8));
    }

    @Test
    public void gb18030RoundTrip() {
        String s = "简体中文测试";
        byte[] enc = EncodingDetector.encode(s, EncodingDetector.GB18030);
        assertEquals(s, EncodingDetector.decode(enc, EncodingDetector.GB18030));
    }

    @Test
    public void gbkRoundTrip() {
        String s = "GBK 编码内容";
        byte[] enc = EncodingDetector.encode(s, EncodingDetector.GBK);
        assertEquals(s, EncodingDetector.decode(enc, EncodingDetector.GBK));
    }

    @Test
    public void crlfIsPreservedThroughDecode() {
        byte[] data = "line1\r\nline2\r\n".getBytes(StandardCharsets.UTF_8);
        String text = EncodingDetector.decode(data, EncodingDetector.UTF_8);
        assertEquals("line1\r\nline2\r\n", text);
        // and saving again keeps CRLF because we never touch line endings
        byte[] out = EncodingDetector.encode(text, EncodingDetector.UTF_8);
        assertArrayEquals(data, out);
    }

    @Test
    public void utf8BomIsStrippedOnDecode() {
        byte[] data = new byte[]{(byte) 0xEF, (byte) 0xBB, (byte) 0xBF, 'a', 'b'};
        String text = EncodingDetector.decode(data, EncodingDetector.UTF_8);
        assertEquals("ab", EncodingDetector.stripBom(text, EncodingDetector.UTF_8));
    }

    @Test
    public void malformedBytesDecodeWithReplacementInsteadOfThrowing() {
        byte[] bad = new byte[]{(byte) 0xFF, (byte) 0xFE, 0x41, (byte) 0xFF, 0x00};
        String text = EncodingDetector.decode(bad, EncodingDetector.UTF_8);
        assertFalse(text.isEmpty());
    }

    @Test
    public void unmappableCharactersEncodeWithReplacementNotThrow() {
        // 中文 cannot be represented in Latin-1
        byte[] enc = EncodingDetector.encode("中文", EncodingDetector.LATIN_1);
        assertTrue(enc.length > 0);
        // decoded back, characters became '?'
        assertEquals("??", EncodingDetector.decode(enc, EncodingDetector.LATIN_1));
    }

    @Test
    public void encodeWithAutoUsesUtf8() {
        byte[] enc = EncodingDetector.encode("abc", EncodingDetector.AUTO);
        assertArrayEquals(new byte[]{'a', 'b', 'c'}, enc);
    }

    // ---- helpers ----

    @Test
    public void charsetValidation() {
        assertTrue(EncodingDetector.isValidCharsetName("UTF-8"));
        assertTrue(EncodingDetector.isValidCharsetName("GB18030"));
        assertFalse(EncodingDetector.isValidCharsetName("nonsense-charset"));
        assertFalse(EncodingDetector.isValidCharsetName(null));
        assertFalse(EncodingDetector.isValidCharsetName(""));
    }

    @Test
    public void isAuto() {
        assertTrue(EncodingDetector.isAuto(null));
        assertTrue(EncodingDetector.isAuto(""));
        assertTrue(EncodingDetector.isAuto(EncodingDetector.AUTO));
        assertFalse(EncodingDetector.isAuto(EncodingDetector.UTF_8));
    }

    @Test
    public void labelsAreHumanReadable() {
        assertEquals("自动检测", EncodingDetector.labelOf(EncodingDetector.AUTO));
        assertEquals("UTF-8", EncodingDetector.labelOf(EncodingDetector.UTF_8));
        assertTrue(EncodingDetector.labelOf(EncodingDetector.GB18030).contains("GB18030"));
    }

    @Test
    public void userChoicesCoverCommonEncodings() {
        String joined = String.join(",", EncodingDetector.USER_CHOICES);
        assertTrue(joined.contains("UTF-8"));
        assertTrue(joined.contains("GBK"));
        assertTrue(joined.contains("GB18030"));
        assertTrue(joined.contains("Big5"));
        assertTrue(joined.contains("UTF-16"));
        assertTrue(joined.contains("ISO-8859-1"));
    }
}
