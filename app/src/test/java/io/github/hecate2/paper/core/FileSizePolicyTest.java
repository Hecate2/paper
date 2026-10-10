package io.github.hecate2.paper.core;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class FileSizePolicyTest {

    @Test
    public void smallFileIsEditable() {
        assertEquals(FileSizePolicy.Tier.EDITABLE, FileSizePolicy.tierFor(0, false));
        assertEquals(FileSizePolicy.Tier.EDITABLE,
                FileSizePolicy.tierFor(FileSizePolicy.EDIT_LIMIT, false));
        assertEquals(FileSizePolicy.Tier.EDITABLE,
                FileSizePolicy.tierFor(FileSizePolicy.EDIT_LIMIT - 1, false));
    }

    @Test
    public void mediumFileIsReadonly() {
        assertEquals(FileSizePolicy.Tier.READONLY,
                FileSizePolicy.tierFor(FileSizePolicy.EDIT_LIMIT + 1, false));
        assertEquals(FileSizePolicy.Tier.READONLY,
                FileSizePolicy.tierFor(FileSizePolicy.FULL_VIEW_LIMIT, false));
    }

    @Test
    public void hugeFileGetsHeadPreview() {
        assertEquals(FileSizePolicy.Tier.HEAD_PREVIEW,
                FileSizePolicy.tierFor(FileSizePolicy.FULL_VIEW_LIMIT + 1, false));
        assertEquals(FileSizePolicy.Tier.HEAD_PREVIEW,
                FileSizePolicy.tierFor(Long.MAX_VALUE, false));
    }

    @Test
    public void binaryAlwaysReadonly() {
        assertEquals(FileSizePolicy.Tier.READONLY, FileSizePolicy.tierFor(100, true));
        assertEquals(FileSizePolicy.Tier.READONLY,
                FileSizePolicy.tierFor(FileSizePolicy.FULL_VIEW_LIMIT + 1, true));
    }

    @Test
    public void readLimits() {
        assertEquals(123, FileSizePolicy.readLimit(FileSizePolicy.Tier.EDITABLE, 123));
        assertEquals(FileSizePolicy.FULL_VIEW_LIMIT,
                FileSizePolicy.readLimit(FileSizePolicy.Tier.READONLY,
                        FileSizePolicy.FULL_VIEW_LIMIT * 2));
        assertEquals(FileSizePolicy.HEAD_LIMIT,
                FileSizePolicy.readLimit(FileSizePolicy.Tier.HEAD_PREVIEW,
                        FileSizePolicy.FULL_VIEW_LIMIT * 10));
        // preview limit never exceeds actual file size
        assertEquals(5, FileSizePolicy.readLimit(FileSizePolicy.Tier.HEAD_PREVIEW, 5));
    }

    @Test
    public void onlyEditableAllowsSave() {
        assertTrue(FileSizePolicy.allowsSave(FileSizePolicy.Tier.EDITABLE));
        assertFalse(FileSizePolicy.allowsSave(FileSizePolicy.Tier.READONLY));
        assertFalse(FileSizePolicy.allowsSave(FileSizePolicy.Tier.HEAD_PREVIEW));
    }

    @Test
    public void readOnlyReasons() {
        assertNull(FileSizePolicy.readOnlyReason(FileSizePolicy.Tier.EDITABLE, false));
        assertTrue(FileSizePolicy.readOnlyReason(FileSizePolicy.Tier.READONLY, false).contains("只读"));
        assertTrue(FileSizePolicy.readOnlyReason(FileSizePolicy.Tier.READONLY, true).contains("二进制"));
        assertTrue(FileSizePolicy.readOnlyReason(FileSizePolicy.Tier.HEAD_PREVIEW, false).contains("MB"));
        // binary takes precedence in messaging even for editable-sized files
        assertTrue(FileSizePolicy.readOnlyReason(FileSizePolicy.Tier.READONLY, true).contains("二进制"));
    }
}
