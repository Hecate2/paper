package io.github.hecate2.paper;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.text.TextPaint;
import android.util.AttributeSet;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewConfiguration;
import android.widget.OverScroller;

/**
 * Read-only, virtualized text viewer for large / binary files.
 * Only the visible lines are measured and drawn per frame, so opening a
 * 100MB file never blocks the UI thread. No word wrap in this mode (the
 * banner explains it); horizontal scrolling is supported.
 */
public class VirtualTextView extends View {

    /**
     * Upper bound on how much of a single line is ever measured or drawn. A file with
     * one multi-megabyte line would otherwise make every frame measure millions of
     * glyphs on the UI thread (an ANR); the tail of such a line is simply not shown.
     */
    private static final int MAX_LINE_SPAN = 20000;

    private String text = "";
    private int[] lineStarts = {0};
    private int lineCount = 1;

    private final TextPaint textPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final Paint gutterBgPaint = new Paint();
    private final Paint lineNumPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final Paint matchPaint = new Paint();

    private float lineHeight;
    private float baselineOffset;
    private long contentWidth = 0;
    private long contentHeight = 0;

    private boolean showLineNumbers = true;
    private int gutterWidth = 0;

    private int[] matches = new int[0];
    private int currentMatch = -1;

    private final OverScroller scroller;
    private final GestureDetector gesture;
    private VelocityTracker velocityTracker;

    public VirtualTextView(Context context) {
        this(context, null);
    }

    public VirtualTextView(Context context, AttributeSet attrs) {
        super(context, attrs);
        scroller = new OverScroller(context);
        float density = context.getResources().getDisplayMetrics().density;
        textPaint.setTextSize(16 * context.getResources().getDisplayMetrics().scaledDensity);
        textPaint.setColor(Color.BLACK);
        lineNumPaint.setTextSize(12 * context.getResources().getDisplayMetrics().scaledDensity);
        lineNumPaint.setColor(context.getResources().getColor(R.color.gutter_text, null));
        lineNumPaint.setTextAlign(Paint.Align.RIGHT);
        gutterBgPaint.setColor(context.getResources().getColor(R.color.gutter_bg, null));
        matchPaint.setColor(context.getResources().getColor(R.color.find_highlight, null));

        final int minFling = ViewConfiguration.get(context).getMinimumFlingVelocity();
        final int maxFling = ViewConfiguration.get(context).getMaximumFlingVelocity();
        gesture = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override
            public boolean onDown(MotionEvent e) {
                scroller.forceFinished(true);
                return true;
            }

            @Override
            public boolean onScroll(MotionEvent e1, MotionEvent e2, float dx, float dy) {
                scrollByInternal((int) dx, (int) dy);
                return true;
            }

            @Override
            public boolean onFling(MotionEvent e1, MotionEvent e2, float vx, float vy) {
                scroller.fling(getScrollX(), getScrollY(),
                        (int) -vx, (int) -vy,
                        0, (int) Math.min(contentWidth, Integer.MAX_VALUE),
                        0, (int) Math.min(contentHeight, Integer.MAX_VALUE));
                postInvalidateOnAnimation();
                return true;
            }
        });
        updateMetrics();
    }

    /** Installs content. lineStarts must be sorted, start at 0, and cover the whole text. */
    public void setContent(String text, int[] lineStarts, boolean showLineNumbers) {
        this.text = text == null ? "" : text;
        this.lineStarts = lineStarts == null || lineStarts.length == 0 ? new int[]{0} : lineStarts;
        this.lineCount = Math.max(1, this.lineStarts.length - 1);
        this.showLineNumbers = showLineNumbers;
        updateMetrics();
        scrollTo(0, 0);
        invalidate();
    }

    public void setShowLineNumbers(boolean show) {
        this.showLineNumbers = show;
        updateGutter();
        invalidate();
    }

    public void setFontSizeSp(int sp) {
        textPaint.setTextSize(sp * getResources().getDisplayMetrics().scaledDensity);
        updateMetrics();
        invalidate();
    }

    public void setMatches(int[] flatPairs, int currentIndex) {
        this.matches = flatPairs == null ? new int[0] : flatPairs;
        this.currentMatch = currentIndex;
        invalidate();
    }

    public String getTextContent() {
        return text;
    }

    /** Scrolls to the char offset (used by find/next). */
    public void scrollToOffset(int offset) {
        int line = findLine(offset);
        int y = (int) Math.min(line * lineHeight, Math.max(0, contentHeight - getHeight()));
        int x = getScrollX();
        if (showLineNumbers) {
            // keep x; only vertical jump
        }
        scrollTo(x, y);
        invalidate();
    }

    private int findLine(int offset) {
        int lo = 0, hi = lineCount - 1;
        while (lo < hi) {
            int mid = (lo + hi + 1) >>> 1;
            if (lineStarts[mid] <= offset) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    private void updateMetrics() {
        Paint.FontMetrics fm = textPaint.getFontMetrics();
        lineHeight = fm.bottom - fm.top;
        baselineOffset = -fm.top;
        updateGutter();
        // Exact max line width is expensive; approximate from the longest line in chars.
        int maxChars = 1;
        for (int i = 0; i < lineCount && i < 20000; i++) {
            int len = lineEnd(i) - lineStart(i);
            if (len > maxChars) {
                maxChars = len;
            }
        }
        if (lineCount > 20000) {
            // For huge files sample-based width is a lower bound; drawing clips safely.
            maxChars = Math.max(maxChars, 200);
        }
        maxChars = Math.min(maxChars, MAX_LINE_SPAN);
        contentWidth = (long) (maxChars * textPaint.measureText("W")) + gutterWidth + 32;
        contentHeight = (long) (lineCount * lineHeight);
        if (contentHeight < getHeight()) {
            contentHeight = getHeight();
        }
    }

    private void updateGutter() {
        if (!showLineNumbers) {
            gutterWidth = 0;
            return;
        }
        int digits = String.valueOf(Math.max(1, lineCount)).length();
        // Width of `digits` digits. (measureText(text, 0, digits) would throw once
        // digits exceeds the length of the measured string.)
        float w = lineNumPaint.measureText("0") * digits + 12;
        gutterWidth = Math.max(Math.round(18 * getResources().getDisplayMetrics().density), Math.round(w));
    }

    private int lineStart(int line) {
        if (line < 0) {
            return 0;
        }
        if (line >= lineStarts.length) {
            return text.length();
        }
        return lineStarts[line];
    }

    /** Exclusive end of the line's text (trailing '\n' removed). */
    private int lineEnd(int line) {
        int start = lineStart(line);
        int next = lineStart(line + 1);
        if (next > start && next <= text.length() && text.charAt(next - 1) == '\n') {
            next--;
        }
        if (next > start && next <= text.length() && text.charAt(next - 1) == '\r') {
            next--;
        }
        return Math.max(start, next);
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        super.onMeasure(widthMeasureSpec, heightMeasureSpec);
        if (contentHeight < getMeasuredHeight()) {
            contentHeight = getMeasuredHeight();
        }
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        if (text.isEmpty()) {
            return;
        }
        int viewW = getWidth();
        int viewH = getHeight();
        int scrollX = getScrollX();
        int scrollY = getScrollY();

        int firstLine = Math.max(0, (int) (scrollY / lineHeight));
        int lastLine = Math.min(lineCount - 1, (int) ((scrollY + viewH) / lineHeight) + 1);

        if (showLineNumbers && gutterWidth > 0) {
            canvas.drawRect(0, 0, gutterWidth, viewH, gutterBgPaint);
        }

        for (int line = firstLine; line <= lastLine; line++) {
            float y = line * lineHeight - scrollY;
            drawLine(canvas, line, y, scrollX, viewW);
            if (showLineNumbers) {
                canvas.drawText(String.valueOf(line + 1),
                        gutterWidth - 4, y + baselineOffset, lineNumPaint);
            }
        }
    }

    private void drawLine(Canvas canvas, int line, float y, int scrollX, int viewW) {
        int s = lineStart(line);
        int e = Math.min(lineEnd(line), s + MAX_LINE_SPAN);
        if (e <= s) {
            return;
        }
        int left = gutterWidth;
        int avail = viewW - left;
        if (avail <= 0) {
            return;
        }
        float totalPx = textPaint.measureText(text, s, e);
        float baseX = left - scrollX;

        if (totalPx <= avail) {
            if (baseX + totalPx < left || baseX > viewW) {
                return;
            }
            drawMatchHighlights(canvas, line, s, e, baseX, y);
            canvas.drawText(text, s, e, baseX, y + baselineOffset, textPaint);
            return;
        }

        // Long line: skip the horizontally off-screen prefix in chunks.
        int startChar = s;
        float x = baseX;
        // Advance in 64-char chunks until x >= left.
        while (startChar < e && x + textPaint.measureText(text, startChar, Math.min(e, startChar + 64)) < left) {
            int next = Math.min(e, startChar + 64);
            x += textPaint.measureText(text, startChar, next);
            startChar = next;
        }
        if (startChar > s) {
            // re-sync exact position: adjust by measuring from s to startChar
            x = baseX + textPaint.measureText(text, s, startChar);
        }
        if (x > viewW) {
            return;
        }
        int endChar = textPaint.breakText(text, startChar, e, true, avail - (x - left) + 64, null);
        endChar = Math.max(startChar + 1, endChar);
        // ensure we draw at least up to the right edge plus a buffer
        while (endChar < e && x + textPaint.measureText(text, startChar, endChar) < avail) {
            int next = Math.min(e, endChar + 64);
            if (textPaint.measureText(text, startChar, next) + x > avail + 128) {
                break;
            }
            endChar = next;
        }
        drawMatchHighlights(canvas, line, startChar, endChar, x, y);
        canvas.drawText(text, startChar, endChar, x, y + baselineOffset, textPaint);
    }

    /** Draws background rects for find matches intersecting the drawn range. */
    private void drawMatchHighlights(Canvas canvas, int line, int s, int e, float baseX, float y) {
        if (matches.length == 0) {
            return;
        }
        // Matches are sorted; binary search for the first candidate.
        int lo = 0, hi = matches.length / 2 - 1, idx = matches.length / 2;
        while (lo <= hi) {
            int mid = (lo + hi) >>> 1;
            if (matches[mid * 2 + 1] > s) {
                idx = mid;
                hi = mid - 1;
            } else {
                lo = mid + 1;
            }
        }
        for (int i = idx; i < matches.length / 2; i++) {
            int ms = matches[i * 2];
            int me = matches[i * 2 + 1];
            if (ms >= e) {
                break;
            }
            int rs = Math.max(ms, s);
            int re = Math.min(me, e);
            if (rs >= re) {
                continue;
            }
            float x0 = baseX + textPaint.measureText(text, s, rs);
            float x1 = baseX + textPaint.measureText(text, s, re);
            Paint p = (i == currentMatch)
                    ? highlightSolid() : matchPaint;
            canvas.drawRect(x0, y, x1, y + lineHeight, p);
        }
    }

    private Paint solidCache;

    private Paint highlightSolid() {
        if (solidCache == null) {
            solidCache = new Paint();
            solidCache.setColor(0x554CAF50);
        }
        return solidCache;
    }

    // ---- scrolling ----

    private void scrollByInternal(int dx, int dy) {
        int nx = clamp((int) (getScrollX() + dx), 0, (int) Math.max(0, contentWidth - getWidth()));
        int ny = clamp((int) (getScrollY() + dy), 0, (int) Math.max(0, contentHeight - getHeight()));
        if (nx != getScrollX() || ny != getScrollY()) {
            scrollTo(nx, ny);
            postInvalidateOnAnimation();
        }
    }

    private static int clamp(int v, int min, int max) {
        return Math.max(min, Math.min(max, v));
    }

    @Override
    public void computeScroll() {
        if (scroller.computeScrollOffset()) {
            int ox = getScrollX(), oy = getScrollY();
            scrollTo(scroller.getCurrX(), scroller.getCurrY());
            if (scroller.getCurrX() != ox || scroller.getCurrY() != oy) {
                postInvalidateOnAnimation();
            }
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (velocityTracker == null) {
            velocityTracker = VelocityTracker.obtain();
        }
        velocityTracker.addMovement(event);
        boolean handled = gesture.onTouchEvent(event);
        if (event.getActionMasked() == MotionEvent.ACTION_UP
                || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            if (velocityTracker != null) {
                velocityTracker.recycle();
                velocityTracker = null;
            }
            if (!handled) {
                return super.onTouchEvent(event);
            }
        }
        return handled || super.onTouchEvent(event);
    }
}
