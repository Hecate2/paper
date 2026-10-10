package io.github.hecate2.paper.core;

/**
 * Size/binary tiering so opening any file can never freeze the UI (DESIGN.md §8).
 *  - EDITABLE:      loads into the EditText, fully editable
 *  - READONLY:      large but complete load into the virtualized viewer
 *  - HEAD_PREVIEW:  only the first HEAD_LIMIT bytes are shown, save disabled
 * Binary content forces READONLY regardless of size.
 */
public final class FileSizePolicy {

    public static final long EDIT_LIMIT = 5L * 1024 * 1024;       // 5 MB
    public static final long FULL_VIEW_LIMIT = 100L * 1024 * 1024; // 100 MB
    public static final long HEAD_LIMIT = 10L * 1024 * 1024;       // 10 MB

    public enum Tier {
        EDITABLE, READONLY, HEAD_PREVIEW
    }

    private FileSizePolicy() {
    }

    public static Tier tierFor(long sizeBytes, boolean binary) {
        if (binary) {
            return Tier.READONLY;
        }
        if (sizeBytes <= EDIT_LIMIT) {
            return Tier.EDITABLE;
        }
        if (sizeBytes <= FULL_VIEW_LIMIT) {
            return Tier.READONLY;
        }
        return Tier.HEAD_PREVIEW;
    }

    /** How many bytes may be read from a file of this tier. */
    public static long readLimit(Tier tier, long sizeBytes) {
        switch (tier) {
            case HEAD_PREVIEW:
                return Math.min(sizeBytes, HEAD_LIMIT);
            case READONLY:
                return Math.min(sizeBytes, FULL_VIEW_LIMIT);
            case EDITABLE:
            default:
                return sizeBytes;
        }
    }

    /** Whether saving back to the original file is allowed for this tier. */
    public static boolean allowsSave(Tier tier) {
        return tier == Tier.EDITABLE;
    }

    /** Short user-facing reason shown as a banner when save is disabled, or null. */
    public static String readOnlyReason(Tier tier, boolean binary) {
        if (binary) {
            return "检测到二进制内容：只读模式，保存已禁用";
        }
        switch (tier) {
            case HEAD_PREVIEW:
                return "超大文件：仅显示前 " + (HEAD_LIMIT / (1024 * 1024)) + " MB，只读，保存已禁用";
            case READONLY:
                return "大文件：只读模式，保存已禁用";
            default:
                return null;
        }
    }
}
