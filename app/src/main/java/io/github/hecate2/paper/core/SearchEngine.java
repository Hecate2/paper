package io.github.hecate2.paper.core;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * High-performance find/replace over a String. Results are flat int pairs
 * [start0, end0, start1, end1, ...] to avoid per-match object churn.
 * Scanning runs on a background thread; this class never touches the UI.
 */
public final class SearchEngine {

    /** Hard cap so a pathological query cannot allocate unbounded results. */
    public static final int MAX_RESULTS = 200_000;

    private SearchEngine() {
    }

    /**
     * Finds all non-overlapping matches of query in text.
     *
     * @param query         plain text or regex (when regex == true)
     * @param caseSensitive whether matching is case sensitive
     * @param cancel        optional cooperative cancel flag checked periodically
     * @return flat pairs [start0, end0, start1, end1, ...]
     */
    public static int[] findAll(String text, String query, boolean caseSensitive,
                                boolean regex, boolean[] cancel) {
        if (text == null || query == null || query.isEmpty()) {
            return new int[0];
        }
        if (regex) {
            return findAllRegex(text, query, caseSensitive, cancel);
        }
        return findAllPlain(text, query, caseSensitive, cancel);
    }

    private static int[] findAllPlain(String text, String query, boolean caseSensitive, boolean[] cancel) {
        int[] starts = new int[64];
        int count = 0;
        if (caseSensitive) {
            int idx = text.indexOf(query);
            while (idx >= 0) {
                if ((count & 1023) == 0 && isCancelled(cancel)) {
                    break;
                }
                if (count == starts.length) {
                    starts = grow(starts, starts.length * 2);
                }
                starts[count++] = idx;
                if (count >= MAX_RESULTS) {
                    break;
                }
                idx = text.indexOf(query, idx + query.length());
            }
        } else {
            // Case-insensitive: scan a lowercased copy, verify hits against the original.
            String lowerText = text.toLowerCase(Locale.ROOT);
            String lowerQuery = query.toLowerCase(Locale.ROOT);
            int idx = lowerText.indexOf(lowerQuery);
            while (idx >= 0) {
                if ((count & 1023) == 0 && isCancelled(cancel)) {
                    break;
                }
                if (text.regionMatches(true, idx, query, 0, query.length())) {
                    if (count == starts.length) {
                        starts = grow(starts, starts.length * 2);
                    }
                    starts[count++] = idx;
                }
                if (count >= MAX_RESULTS) {
                    break;
                }
                idx = lowerText.indexOf(lowerQuery, idx + Math.max(1, lowerQuery.length()));
            }
        }
        return toPairs(starts, count, query.length());
    }

    private static int[] findAllRegex(String text, String query, boolean caseSensitive, boolean[] cancel) {
        Pattern pattern = tryCompile(query, caseSensitive);
        if (pattern == null) {
            return new int[0];
        }
        Matcher m = pattern.matcher(text);
        int[] starts = new int[64];
        int[] ends = new int[64];
        int count = 0;
        int lastEnd = -1;
        while (m.find()) {
            if ((count & 1023) == 0 && isCancelled(cancel)) {
                break;
            }
            int s = m.start();
            int e = m.end();
            if (s == e) {
                // Zero-width match: advance manually to avoid an infinite loop.
                if (e >= text.length()) {
                    break;
                }
                m.region(e + 1, text.length());
                continue;
            }
            if (s < lastEnd) {
                continue;
            }
            if (count == starts.length) {
                starts = grow(starts, starts.length * 2);
                ends = grow(ends, ends.length * 2);
            }
            starts[count] = s;
            ends[count] = e;
            count++;
            lastEnd = e;
            if (count >= MAX_RESULTS) {
                break;
            }
        }
        int[] out = new int[count * 2];
        for (int i = 0; i < count; i++) {
            out[i * 2] = starts[i];
            out[i * 2 + 1] = ends[i];
        }
        return out;
    }

    /** Replaces every match from findAll with a literal replacement. */
    public static String replaceAllLiteral(String text, int[] matches, String replacement) {
        if (matches == null || matches.length == 0) {
            return text;
        }
        String rep = replacement == null ? "" : replacement;
        StringBuilder sb = new StringBuilder(text.length());
        int cursor = 0;
        for (int i = 0; i + 1 < matches.length; i += 2) {
            int s = matches[i];
            int e = matches[i + 1];
            if (s < cursor) {
                continue;
            }
            sb.append(text, cursor, s).append(rep);
            cursor = e;
        }
        sb.append(text, cursor, text.length());
        return sb.toString();
    }

    /** Replaces all regex matches honoring $1..$9 group references in replacement. */
    public static String replaceAllRegex(String text, String query, String replacement,
                                         boolean caseSensitive) {
        if (text == null || query == null || query.isEmpty()) {
            return text;
        }
        Pattern pattern = tryCompile(query, caseSensitive);
        if (pattern == null) {
            return text;
        }
        Matcher m = pattern.matcher(text);
        StringBuilder sb = new StringBuilder(text.length());
        int count = 0;
        int lastEnd = -1;
        while (count < MAX_RESULTS && m.find()) {
            int s = m.start();
            int e = m.end();
            if (s == e) {
                if (e >= text.length()) {
                    break;
                }
                m.region(e + 1, text.length());
                continue;
            }
            if (s < lastEnd) {
                continue;
            }
            m.appendReplacement(sb, replacement == null ? "" : replacement);
            count++;
            lastEnd = e;
        }
        m.appendTail(sb);
        return sb.toString();
    }

    /** Replaces a single match range literally (used by "replace current" for plain search). */
    public static String replaceRange(String text, int start, int end, String replacement) {
        return text.substring(0, start) + (replacement == null ? "" : replacement)
                + text.substring(end);
    }

    /**
     * Expands group references of the regex match at [start, end) and replaces just that range.
     * Falls back to a literal replacement when the range is not an exact regex match.
     */
    public static String replaceCurrentRegex(String text, String query, int start, int end,
                                             String replacement, boolean caseSensitive) {
        Pattern pattern = tryCompile(query, caseSensitive);
        if (pattern != null) {
            Matcher m = pattern.matcher(text);
            while (m.find()) {
                if (m.start() == start && m.end() == end) {
                    StringBuilder one = new StringBuilder();
                    m.appendReplacement(one, replacement == null ? "" : replacement);
                    // one now = text[0, start) + expanded replacement
                    String expanded = one.substring(start);
                    return text.substring(0, start) + expanded + text.substring(end);
                }
                if (m.start() > start) {
                    break;
                }
            }
        }
        return replaceRange(text, start, end, replacement);
    }

    private static Pattern tryCompile(String query, boolean caseSensitive) {
        try {
            int flags = Pattern.DOTALL
                    | (caseSensitive ? 0 : Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);
            return Pattern.compile(query, flags);
        } catch (Exception e) {
            return null;
        }
    }

    private static boolean isCancelled(boolean[] cancel) {
        return cancel != null && cancel.length > 0 && cancel[0];
    }

    private static int[] grow(int[] src, int cap) {
        int[] out = new int[cap];
        System.arraycopy(src, 0, out, 0, Math.min(src.length, cap));
        return out;
    }

    private static int[] toPairs(int[] starts, int count, int len) {
        int[] out = new int[count * 2];
        for (int i = 0; i < count; i++) {
            out[i * 2] = starts[i];
            out[i * 2 + 1] = starts[i] + len;
        }
        return out;
    }
}
