package io.github.hecate2.paper;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.text.Layout;
import android.util.AttributeSet;
import android.widget.EditText;

/**
 * EditText with:
 *  - current logical line highlighted (full width, redrawn on caret/text/scroll changes)
 *  - optional line-number gutter showing logical line numbers (wrapping-aware),
 *    with the current line's number emphasized
 * Gutter numbers are self-drawn so no second widget can drift out of sync.
 */
public class EditorEditText extends EditText {

    private final Paint lineBgPaint = new Paint();
    private final Paint gutterBgPaint = new Paint();
    private final Paint lineNumPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint currentNumPaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    private boolean showLineNumbers = true;
    private float gutterWidth = 0f;

    // Incremental newline-count cache: counting from scratch each frame is O(n).
    private int countedPos = 0;
    private int countedLogical = 0;

    public EditorEditText(Context context) {
        this(context, null);
    }

    public EditorEditText(Context context, AttributeSet attrs) {
        super(context, attrs);
        init(context);
    }

    private void init(Context context) {
        int highlight = context.getResources().getColor(R.color.current_line, null);
        int gutterBg = context.getResources().getColor(R.color.gutter_bg, null);
        int gutterText = context.getResources().getColor(R.color.gutter_text, null);
        int gutterTextCurrent = context.getResources().getColor(R.color.gutter_text_current, null);
        lineBgPaint.setColor(highlight);
        gutterBgPaint.setColor(gutterBg);
        lineNumPaint.setColor(gutterText);
        currentNumPaint.setColor(gutterTextCurrent);
        lineNumPaint.setTextAlign(Paint.Align.RIGHT);
        currentNumPaint.setTextAlign(Paint.Align.RIGHT);
        updateGutterWidth();
    }

    public void setShowLineNumbers(boolean show) {
        if (this.showLineNumbers != show) {
            this.showLineNumbers = show;
            updateGutterWidth();
            invalidate();
        }
    }

    /** Keeps the left padding in sync with the current gutter width. */
    private void applyGutterPadding() {
        int left = showLineNumbers ? (int) Math.ceil(gutterWidth) + dp(8) : dp(8);
        if (left != getPaddingLeft()) {
            setPaddingRelative(left, getPaddingTop(), getPaddingEnd(), getPaddingBottom());
        }
    }

    public void applyStyle(int fontSizeSp, boolean wrap) {
        setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, fontSizeSp);
        // setHorizontallyScrolling() already discards the layout and re-requests it, so
        // there is no need to re-set the text here (doing so would fire the TextWatcher
        // and wrongly mark the document as modified).
        setHorizontallyScrolling(!wrap);
        updateGutterWidth();
        setShowLineNumbers(showLineNumbers);
        invalidate();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void updateGutterWidth() {
        if (!showLineNumbers) {
            gutterWidth = 0;
            applyGutterPadding();
            return;
        }
        // Keep the gutter painted at the editor's own text size.
        float size = getTextSize();
        if (size > 0) {
            lineNumPaint.setTextSize(size);
            currentNumPaint.setTextSize(size);
        }
        Layout layout = getLayout();
        int lines = layout != null ? layout.getLineCount() : 1;
        int digits = String.valueOf(Math.max(1, lines)).length();
        // Width of `digits` digits. (measureText(text, 0, digits) would throw once
        // digits exceeds the length of the measured string.)
        float w = lineNumPaint.measureText("0") * digits + dp(6);
        gutterWidth = Math.max(dp(18), w);
        applyGutterPadding();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        Layout layout = getLayout();
        if (layout == null || layout.getLineCount() == 0) {
            super.onDraw(canvas);
            return;
        }

        int scrollY = getScrollY();
        int padTop = getCompoundPaddingTop();
        int padLeft = getCompoundPaddingLeft();

        // --- current logical line background (behind text) ---
        int sel = getSelectionStart();
        if (sel < 0) {
            sel = 0;
        }
        if (sel > getText().length()) {
            sel = getText().length();
        }
        int cursorVis = layout.getLineForOffset(sel);
        int firstVis = cursorVis;
        while (firstVis > 0 && !lineEndsWithNewline(layout, firstVis - 1)) {
            firstVis--;
        }
        int lastVis = cursorVis;
        while (lastVis + 1 < layout.getLineCount() && !lineEndsWithNewline(layout, lastVis)) {
            lastVis++;
        }
        float top = padTop + layout.getLineTop(firstVis) - scrollY;
        float bottom = padTop + layout.getLineBottom(lastVis) - scrollY;
        canvas.drawRect(0, top, getWidth(), bottom, lineBgPaint);

        if (showLineNumbers && gutterWidth > 0) {
            canvas.drawRect(0, 0, gutterWidth, getHeight(), gutterBgPaint);
        }

        super.onDraw(canvas);

        // --- gutter numbers (in front) ---
        if (!showLineNumbers || gutterWidth <= 0) {
            return;
        }
        int firstDrawn = layout.getLineForVertical(scrollY - padTop);
        int lastDrawn = layout.getLineForVertical(scrollY - padTop + (getHeight() - padTop));
        lastDrawn = Math.min(lastDrawn, layout.getLineCount() - 1);

        // Start the incremental newline count from the first visible logical line.
        int pos = layout.getLineStart(firstDrawn);
        if (pos < countedPos) {
            countedPos = 0;
            countedLogical = 0;
        }
        advanceCount(pos);

        int prevLogical = -1;
        float textH = lineNumPaint.getTextSize();
        for (int v = firstDrawn; v <= lastDrawn; v++) {
            int lineStart = layout.getLineStart(v);
            if (lineStart < countedPos) {
                countedPos = 0;
                countedLogical = 0;
            }
            advanceCount(lineStart);
            int logical = countedLogical;
            if (logical == prevLogical) {
                continue; // wrapped continuation of the same logical line
            }
            prevLogical = logical;
            float y = padTop + layout.getLineTop(v) - scrollY;
            if (y + textH < 0 || y > getHeight()) {
                continue;
            }
            String num = String.valueOf(logical + 1);
            boolean current = v >= firstVis && v <= lastVis;
            Paint p = current ? currentNumPaint : lineNumPaint;
            p.setTextSize(lineNumPaint.getTextSize());
            canvas.drawText(num, gutterWidth - dp(4), y + textH * 0.8f, p);
        }
    }

    private boolean lineEndsWithNewline(Layout layout, int visLine) {
        int end = layout.getLineEnd(visLine);
        int start = layout.getLineStart(visLine);
        if (end <= start) {
            return false;
        }
        CharSequence t = layout.getText();
        return t.charAt(end - 1) == '\n';
    }

    /** Advances (countedPos, countedLogical) so countedLogical = number of '\n' before pos. */
    private void advanceCount(int pos) {
        if (pos < countedPos) {
            countedPos = 0;
            countedLogical = 0;
        }
        CharSequence t = getText();
        int limit = Math.min(pos, t.length());
        for (int i = countedPos; i < limit; i++) {
            if (t.charAt(i) == '\n') {
                countedLogical++;
            }
        }
        countedPos = limit;
    }

    @Override
    protected void onSelectionChanged(int selStart, int selEnd) {
        super.onSelectionChanged(selStart, selEnd);
        invalidate();
    }

    @Override
    protected void onTextChanged(CharSequence text, int start, int lengthBefore, int lengthAfter) {
        super.onTextChanged(text, start, lengthBefore, lengthAfter);
        if (lengthBefore != lengthAfter) {
            updateGutterWidth();
        }
        invalidate();
    }

    @Override
    protected void onScrollChanged(int horig, int vert, int oldh, int oldv) {
        super.onScrollChanged(horig, vert, oldh, oldv);
        invalidate();
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        updateGutterWidth();
    }
}
