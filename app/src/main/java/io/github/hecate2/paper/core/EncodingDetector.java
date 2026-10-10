package io.github.hecate2.paper.core;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.IllegalCharsetNameException;
import java.nio.charset.UnsupportedCharsetException;

/**
 * Text encoding detection and lossless decode/encode.
 * AUTO policy: BOM -> strict UTF-8 validation -> GB18030 -> Latin-1 (never fails).
 */
public final class EncodingDetector {

    public static final String AUTO = "AUTO";
    public static final String UTF_8 = "UTF-8";
    public static final String GBK = "GBK";
    public static final String GB18030 = "GB18030";
    public static final String BIG5 = "Big5";
    public static final String UTF_16LE = "UTF-16LE";
    public static final String UTF_16BE = "UTF-16BE";
    public static final String LATIN_1 = "ISO-8859-1";

    /** Charset names offered in the UI, in order. */
    public static final String[] USER_CHOICES = {
            AUTO, UTF_8, GBK, GB18030, BIG5, "UTF-16", LATIN_1
    };

    private static final int SNIFF_BYTES = 8192;

    private EncodingDetector() {
    }

    /** True if the sniffed bytes look binary (contain NUL). */
    public static boolean looksBinary(byte[] head) {
        int n = Math.min(head.length, SNIFF_BYTES);
        for (int i = 0; i < n; i++) {
            if (head[i] == 0) {
                return true;
            }
        }
        return false;
    }

    /** Resolves AUTO (or a user choice) against actual bytes; always returns a decodable charset. */
    public static String resolveCharset(String preference, byte[] data) {
        if (!isAuto(preference) && isValidCharsetName(preference)) {
            return preference;
        }
        return detect(data);
    }

    /** Pure detection: BOM, then strict UTF-8, then GB18030, then Latin-1. */
    public static String detect(byte[] data) {
        if (hasBom(data, new byte[]{(byte) 0xEF, (byte) 0xBB, (byte) 0xBF})) {
            return UTF_8;
        }
        if (hasBom(data, new byte[]{(byte) 0xFF, (byte) 0xFE})) {
            return UTF_16LE;
        }
        if (hasBom(data, new byte[]{(byte) 0xFE, (byte) 0xFF})) {
            return UTF_16BE;
        }
        if (data.length == 0) {
            return UTF_8;
        }
        if (isValidUtf8(data)) {
            return UTF_8;
        }
        if (decodesAs(data, GB18030)) {
            return GB18030;
        }
        return LATIN_1;
    }

    /** Decodes with replacement characters instead of throwing. */
    public static String decode(byte[] data, String charsetName) {
        Charset cs = charset(charsetName);
        CharsetDecoder decoder = cs.newDecoder()
                .onMalformedInput(CodingErrorAction.REPLACE)
                .onUnmappableCharacter(CodingErrorAction.REPLACE);
        try {
            return decoder.decode(ByteBuffer.wrap(data)).toString();
        } catch (CharacterCodingException e) {
            return new String(data, cs);
        }
    }

    /** Encodes text back to bytes; never throws (replacement chars for unmappable input). */
    public static byte[] encode(String text, String charsetName) {
        Charset cs = charset(charsetName);
        try {
            java.nio.ByteBuffer bb = cs.newEncoder()
                    .onMalformedInput(CodingErrorAction.REPLACE)
                    .onUnmappableCharacter(CodingErrorAction.REPLACE)
                    .encode(java.nio.CharBuffer.wrap(text));
            byte[] out = new byte[bb.remaining()];
            bb.get(out);
            return out;
        } catch (CharacterCodingException e) {
            return text.getBytes(cs);
        }
    }

    /** Strips a BOM from decoded text so it is neither shown nor saved twice. */
    public static String stripBom(String text, String charsetName) {
        if (text.isEmpty() || text.charAt(0) != '\uFEFF') {
            return text;
        }
        if (UTF_8.equals(charsetName) || "UTF-16".equals(charsetName)
                || UTF_16LE.equals(charsetName) || UTF_16BE.equals(charsetName)) {
            return text.substring(1);
        }
        return text;
    }

    /** True if the charset name is legal and supported on this runtime. */
    public static boolean isValidCharsetName(String name) {
        if (name == null || name.isEmpty()) {
            return false;
        }
        try {
            return Charset.isSupported(name);
        } catch (IllegalCharsetNameException | UnsupportedCharsetException e) {
            return false;
        }
    }

    public static boolean isAuto(String preference) {
        return preference == null || preference.isEmpty() || AUTO.equals(preference);
    }

    /** Human-readable label for the settings spinner. */
    public static String labelOf(String charsetName) {
        if (AUTO.equals(charsetName)) {
            return "自动检测";
        }
        if (GB18030.equals(charsetName)) {
            return "GB18030（简体中文）";
        }
        if (GBK.equals(charsetName)) {
            return "GBK（简体中文）";
        }
        if (BIG5.equals(charsetName)) {
            return "Big5（繁体中文）";
        }
        if (UTF_8.equals(charsetName)) {
            return "UTF-8";
        }
        if ("UTF-16".equals(charsetName)) {
            return "UTF-16";
        }
        if (LATIN_1.equals(charsetName)) {
            return "Latin-1（ISO-8859-1）";
        }
        return charsetName;
    }

    private static Charset charset(String name) {
        if (isAuto(name)) {
            return Charset.forName(UTF_8);
        }
        try {
            return Charset.forName(name);
        } catch (Exception e) {
            return Charset.forName(UTF_8);
        }
    }

    private static boolean hasBom(byte[] data, byte[] bom) {
        if (data.length < bom.length) {
            return false;
        }
        for (int i = 0; i < bom.length; i++) {
            if (data[i] != bom[i]) {
                return false;
            }
        }
        return true;
    }

    private static boolean isValidUtf8(byte[] data) {
        CharsetDecoder decoder = Charset.forName(UTF_8).newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT);
        try {
            decoder.decode(ByteBuffer.wrap(data));
            return true;
        } catch (CharacterCodingException e) {
            return false;
        }
    }

    private static boolean decodesAs(byte[] data, String charsetName) {
        try {
            CharsetDecoder decoder = Charset.forName(charsetName).newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
            decoder.decode(ByteBuffer.wrap(data));
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
