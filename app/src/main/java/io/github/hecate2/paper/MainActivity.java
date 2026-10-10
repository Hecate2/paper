package io.github.hecate2.paper;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.ProgressDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.Editable;
import android.text.Layout;
import android.text.Spanned;
import android.text.TextWatcher;
import android.text.style.BackgroundColorSpan;
import android.view.Menu;
import android.view.MenuItem;
import android.view.SubMenu;
import android.view.View;
import android.widget.EditText;
import android.widget.TextView;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.github.hecate2.paper.core.AtomicFileWriter;
import io.github.hecate2.paper.core.EncodingDetector;
import io.github.hecate2.paper.core.FileSizePolicy;
import io.github.hecate2.paper.core.SaveNames;
import io.github.hecate2.paper.core.SearchEngine;
import io.github.hecate2.paper.core.StartupDecision;

/**
 * The editor. Handles startup routing, opening (path / share URIs), saving
 * (atomic + .bak), autosave, find/replace, encoding switching and settings.
 * All disk I/O runs on a single background executor; the UI thread never reads files.
 */
public class MainActivity extends Activity {

    private static final int REQ_OPEN = 1;
    private static final int REQ_PICK_DIR = 2;
    private static final int MENU_ENCODING_BASE = 1000;

    private enum Mode {SCRATCH, FILE, URI}

    // views
    private EditorEditText editor;
    private VirtualTextView viewer;
    private TextView banner;
    private View findBar;
    private EditText findInput;
    private EditText replaceInput;
    private TextView findCount;

    // state
    private Prefs prefs;
    private Mode mode = Mode.SCRATCH;
    private String filePath;
    private Uri contentUri;
    private String encoding = EncodingDetector.UTF_8;
    private boolean readOnly = false;
    private boolean previewTruncated = false;
    private boolean dirty = false;
    private boolean suppressDirty = false;

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private ProgressDialog progress;

    // find/replace
    private int[] matches = new int[0];
    private int matchIndex = -1;
    private final Runnable findDebounce = this::runFindNow;

    // autosave
    private long lastSaveAt = 0;
    private final Runnable autosaveTick = new Runnable() {
        @Override
        public void run() {
            main.removeCallbacks(this);
            main.postDelayed(this, 1000);
            maybeAutosave();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        prefs = new Prefs(this);
        editor = findViewById(R.id.editor);
        viewer = findViewById(R.id.viewer);
        banner = findViewById(R.id.banner);
        findBar = findViewById(R.id.findBar);
        findInput = findViewById(R.id.findInput);
        replaceInput = findViewById(R.id.replaceInput);
        findCount = findViewById(R.id.findCount);

        editor.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {
            }

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                if (!suppressDirty && mode != Mode.SCRATCH) {
                    dirty = true;
                } else if (!suppressDirty) {
                    dirty = true;
                }
                main.removeCallbacks(findDebounce);
                main.postDelayed(findDebounce, 150);
            }
        });

        applyEditorSettings();
        ensurePermission();
        routeStartup(getIntent());
        main.post(autosaveTick);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (!handleShareIntent(intent)) {
            routeStartup(intent);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        applyEditorSettings();
    }

    // ---------------------------------------------------------------- startup

    private void routeStartup(Intent intent) {
        if (handleShareIntent(intent)) {
            return;
        }
        StartupDecision.Target target = StartupDecision.decide(
                prefs.startupMode(), prefs.lastFilePath(), prefs.lastIsScratch(), prefs.lastDirectory());
        switch (target) {
            case OPEN_FILE:
                openPath(prefs.lastFilePath());
                break;
            case BROWSER:
                startBrowser(prefs.lastDirectory(), false);
                break;
            case SCRATCH:
            default:
                resetToScratch(null);
                break;
        }
    }

    /** Returns true when the intent carried content (VIEW/SEND) that was handled. */
    private boolean handleShareIntent(Intent intent) {
        if (intent == null) {
            return false;
        }
        String action = intent.getAction();
        if (Intent.ACTION_SEND.equals(action)) {
            String text = intent.getStringExtra(Intent.EXTRA_TEXT);
            if (text != null) {
                resetToScratch(text);
                Toast.makeText(this, "已粘贴分享的文本（未保存）", Toast.LENGTH_SHORT).show();
                return true;
            }
            Uri stream = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (stream != null) {
                openUri(stream);
                return true;
            }
            return false;
        }
        if (Intent.ACTION_VIEW.equals(action) && intent.getData() != null) {
            openUri(intent.getData());
            return true;
        }
        return false;
    }

    private void resetToScratch(String initialText) {
        mode = Mode.SCRATCH;
        filePath = null;
        contentUri = null;
        readOnly = false;
        previewTruncated = false;
        dirty = false;
        encoding = EncodingDetector.UTF_8;
        showEditor();
        suppressDirty = true;
        editor.setText(initialText == null ? "" : initialText);
        suppressDirty = false;
        editor.setSelection(editor.getText().length());
        banner.setVisibility(View.GONE);
        updateTitle();
    }

    // ---------------------------------------------------------------- opening

    private void openPath(String path) {
        if (path == null || path.isEmpty()) {
            resetToScratch(null);
            return;
        }
        File f = new File(path);
        if (!f.isFile()) {
            // Fall back per design: missing file -> browser or scratch
            Toast.makeText(this, getString(R.string.load_failed, "文件不存在"), Toast.LENGTH_SHORT).show();
            if (new File(prefs.lastDirectory()).isDirectory()) {
                startBrowser(prefs.lastDirectory(), false);
            } else {
                resetToScratch(null);
            }
            return;
        }
        showProgress(getString(R.string.loading), true);
        io.execute(() -> {
            try {
                long size = f.length();
                byte[] head = AtomicFileWriter.readHead(f, 8192);
                boolean binary = EncodingDetector.looksBinary(head);
                FileSizePolicy.Tier tier = FileSizePolicy.tierFor(size, binary);
                long limit = FileSizePolicy.readLimit(tier, size);
                byte[] data = size <= limit
                        ? AtomicFileWriter.readAtMost(f, limit)
                        : AtomicFileWriter.readHead(f, limit);
                boolean truncated = data.length < size;
                String charset = EncodingDetector.resolveCharset(prefs.defaultEncoding(), data);
                String text = EncodingDetector.stripBom(EncodingDetector.decode(data, charset), charset);
                int[] lineStarts = buildLineStarts(text);
                main.post(() -> {
                    hideProgress();
                    applyLoadedText(text, lineStarts, path, null, charset, tier, binary, truncated);
                    prefs.recordOpened(path, false);
                    prefs.recordDirectory(path.substring(0, path.lastIndexOf('/')));
                });
            } catch (Exception e) {
                main.post(() -> {
                    hideProgress();
                    Toast.makeText(this, getString(R.string.load_failed, String.valueOf(e.getMessage())),
                            Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void openUri(Uri uri) {
        showProgress(getString(R.string.loading), true);
        io.execute(() -> {
            try {
                long size = querySize(uri);
                boolean headOnly = size < 0 || size > FileSizePolicy.FULL_VIEW_LIMIT;
                byte[] data = readUri(uri, headOnly
                        ? FileSizePolicy.HEAD_LIMIT : FileSizePolicy.FULL_VIEW_LIMIT);
                boolean binary = EncodingDetector.looksBinary(data);
                boolean truncated = size >= 0 && data.length < size;
                FileSizePolicy.Tier tier = FileSizePolicy.tierFor(
                        size >= 0 ? size : data.length, binary);
                String charset = EncodingDetector.resolveCharset(prefs.defaultEncoding(), data);
                String text = EncodingDetector.stripBom(EncodingDetector.decode(data, charset), charset);
                int[] lineStarts = buildLineStarts(text);
                main.post(() -> {
                    hideProgress();
                    applyLoadedText(text, lineStarts, null, uri, charset, tier, binary, truncated);
                    // URI mode always forces "save as" to a real path.
                    if (FileSizePolicy.allowsSave(tier)) {
                        Toast.makeText(this, "分享的内容：保存时需另存为真实文件",
                                Toast.LENGTH_SHORT).show();
                    }
                });
            } catch (Exception e) {
                main.post(() -> {
                    hideProgress();
                    Toast.makeText(this, getString(R.string.load_failed, String.valueOf(e.getMessage())),
                            Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void applyLoadedText(String text, int[] lineStarts, String path, Uri uri,
                                 String charset, FileSizePolicy.Tier tier, boolean binary,
                                 boolean truncated) {
        this.encoding = charset;
        this.previewTruncated = truncated;
        this.readOnly = !FileSizePolicy.allowsSave(tier) || binary;
        this.dirty = false;
        this.filePath = path;
        this.contentUri = uri;
        this.mode = path != null ? Mode.FILE : (uri != null ? Mode.URI : Mode.SCRATCH);

        boolean useEditor = FileSizePolicy.allowsSave(tier) && !binary;
        if (useEditor) {
            showEditor();
            suppressDirty = true;
            editor.setText(text);
            editor.setSelection(0);
            suppressDirty = false;
        } else {
            showViewer(text, lineStarts);
        }
        String bannerText = FileSizePolicy.readOnlyReason(tier, binary);
        if (bannerText == null && truncated) {
            bannerText = "文件过大：仅显示部分内容，保存已禁用";
        }
        if (bannerText != null) {
            banner.setText(bannerText);
            banner.setVisibility(View.VISIBLE);
        } else {
            banner.setVisibility(View.GONE);
        }
        clearMatches();
        updateTitle();
    }

    private void showEditor() {
        editor.setVisibility(View.VISIBLE);
        viewer.setVisibility(View.GONE);
    }

    private void showViewer(String text, int[] lineStarts) {
        editor.setVisibility(View.GONE);
        viewer.setVisibility(View.VISIBLE);
        viewer.setContent(text, lineStarts, prefs.showLineNumbers());
        viewer.setFontSizeSp(prefs.fontSizeSp());
    }

    private static int[] buildLineStarts(String text) {
        int lines = 1;
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '\n') {
                lines++;
            }
        }
        int[] starts = new int[lines + 1];
        starts[0] = 0;
        int idx = 1;
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '\n') {
                starts[idx++] = i + 1;
            }
        }
        starts[idx] = text.length();
        return starts;
    }

    // ---------------------------------------------------------------- saving

    private void actionSave() {
        if (mode == Mode.FILE && !readOnly) {
            doSaveTo(new File(filePath));
        } else if (mode == Mode.URI && !readOnly) {
            showSaveDialog(prefs.lastDirectory(), SaveNames.defaultFileName(System.currentTimeMillis()));
        } else if (mode == Mode.SCRATCH) {
            showSaveDialog(prefs.lastDirectory(), SaveNames.defaultFileName(System.currentTimeMillis()));
        } else {
            Toast.makeText(this, "只读模式，无法保存", Toast.LENGTH_SHORT).show();
        }
    }

    private void actionSaveAs() {
        if (readOnly && mode != Mode.SCRATCH) {
            // Saving a read-only/previewed file is forbidden for the original;
            // "save as" of a truncated preview would silently lose data.
            if (previewTruncated) {
                Toast.makeText(this, "预览内容不完整，另存为已禁用", Toast.LENGTH_SHORT).show();
                return;
            }
        }
        String name = mode == Mode.FILE && filePath != null
                ? new File(filePath).getName()
                : SaveNames.defaultFileName(System.currentTimeMillis());
        showSaveDialog(prefs.lastDirectory(), name);
    }

    private String pendingDir;
    private String pendingName;

    private void showSaveDialog(String dir, String name) {
        pendingDir = dir == null ? "" : dir;
        pendingName = name;
        if (pendingDir.isEmpty()) {
            // "New file must choose a directory": no history yet -> force browser first.
            Toast.makeText(this, R.string.save_no_dir, Toast.LENGTH_SHORT).show();
            startBrowser(null, true);
            return;
        }
        renderSaveDialog();
    }

    private void renderSaveDialog() {
        View v = getLayoutInflater().inflate(R.layout.dialog_save, null, false);
        EditText nameInput = v.findViewById(R.id.filenameInput);
        TextView dirView = v.findViewById(R.id.dirView);
        nameInput.setText(pendingName);
        dirView.setText(pendingDir);

        AlertDialog dlg = new AlertDialog.Builder(this)
                .setTitle(R.string.save_dialog_title)
                .setView(v)
                .setPositiveButton(R.string.save_ok, null)
                .setNegativeButton(R.string.save_cancel, null)
                .create();
        dlg.setOnShowListener(d -> dlg.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(b -> {
            String name = SaveNames.sanitize(nameInput.getText().toString());
            if (name.isEmpty()) {
                Toast.makeText(this, R.string.save_empty_name, Toast.LENGTH_SHORT).show();
                return;
            }
            if (name.lastIndexOf('.') <= 0) {
                name = SaveNames.ensureTxtExtension(name);
            }
            File dir = new File(pendingDir);
            if (!SaveNames.isWritable(dir)) {
                Toast.makeText(this, R.string.save_no_write, Toast.LENGTH_SHORT).show();
                return;
            }
            File target = new File(dir, name);
            if (target.exists()) {
                new AlertDialog.Builder(this)
                        .setMessage(R.string.save_overwrite)
                        .setPositiveButton(R.string.save_ok,
                                (d2, w) -> { dlg.dismiss(); commitSave(target); })
                        .setNegativeButton(R.string.save_cancel, null)
                        .show();
                return;
            }
            dlg.dismiss();
            commitSave(target);
        }));
        v.findViewById(R.id.btnBrowse).setOnClickListener(b -> {
            pendingName = nameInput.getText().toString();
            dlg.dismiss();
            startBrowser(pendingDir, true);
        });
        dlg.show();
    }

    private void commitSave(File target) {
        String content = editor.getText().toString();
        String charset = encoding;
        showProgress(getString(R.string.loading_saving), false);
        io.execute(() -> {
            try {
                AtomicFileWriter.write(target, EncodingDetector.encode(content, charset));
                main.post(() -> {
                    hideProgress();
                    mode = Mode.FILE;
                    filePath = target.getAbsolutePath();
                    contentUri = null;
                    dirty = false;
                    readOnly = false;
                    banner.setVisibility(View.GONE);
                    prefs.recordOpened(filePath, false);
                    prefs.recordDirectory(target.getParent());
                    Toast.makeText(this, R.string.saved, Toast.LENGTH_SHORT).show();
                    updateTitle();
                });
            } catch (Exception e) {
                main.post(() -> {
                    hideProgress();
                    Toast.makeText(this, getString(R.string.save_failed, String.valueOf(e.getMessage())),
                            Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void maybeAutosave() {
        int interval = prefs.autosaveIntervalSec();
        if (interval <= 0 || readOnly || mode != Mode.FILE || !dirty) {
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastSaveAt < interval * 1000L) {
            return;
        }
        lastSaveAt = now;
        doSaveTo(new File(filePath));
    }

    private void doSaveTo(File target) {
        String content = editor.getText().toString();
        String charset = encoding;
        io.execute(() -> {
            try {
                AtomicFileWriter.write(target, EncodingDetector.encode(content, charset));
                main.post(() -> {
                    dirty = false;
                    prefs.recordOpened(target.getAbsolutePath(), false);
                    updateTitle();
                });
            } catch (Exception e) {
                main.post(() -> Toast.makeText(this,
                        getString(R.string.save_failed, String.valueOf(e.getMessage())),
                        Toast.LENGTH_LONG).show());
            }
        });
    }

    private void restoreBackup() {
        if (mode != Mode.FILE || filePath == null) {
            Toast.makeText(this, "只有已保存的文件才有备份", Toast.LENGTH_SHORT).show();
            return;
        }
        File target = new File(filePath);
        if (!AtomicFileWriter.backupExists(target)) {
            Toast.makeText(this, "没有找到备份文件", Toast.LENGTH_SHORT).show();
            return;
        }
        new AlertDialog.Builder(this)
                .setMessage("用 .bak 备份覆盖当前文件？")
                .setPositiveButton(R.string.save_ok, (d, w) -> {
                    io.execute(() -> {
                        try {
                            AtomicFileWriter.restoreFromBackup(target);
                            main.post(() -> openPath(target.getAbsolutePath()));
                        } catch (Exception e) {
                            main.post(() -> Toast.makeText(this,
                                    getString(R.string.save_failed, String.valueOf(e.getMessage())),
                                    Toast.LENGTH_LONG).show());
                        }
                    });
                })
                .setNegativeButton(R.string.save_cancel, null)
                .show();
    }

    // ---------------------------------------------------------------- find/replace

    private void toggleFindBar() {
        boolean show = findBar.getVisibility() != View.VISIBLE;
        findBar.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show) {
            findInput.requestFocus();
            if (!findInput.getText().toString().isEmpty()) {
                runFindNow();
            }
        } else {
            clearMatches();
        }
    }

    private void runFindNow() {
        if (findBar.getVisibility() != View.VISIBLE) {
            return;
        }
        String query = findInput.getText().toString();
        if (query.isEmpty()) {
            matches = new int[0];
            matchIndex = -1;
            findCount.setText("");
            clearMatchVisuals();
            return;
        }
        boolean caseSensitive = ((android.widget.CheckBox) findViewById(R.id.findCase)).isChecked();
        boolean regex = ((android.widget.CheckBox) findViewById(R.id.findRegex)).isChecked();
        String text = currentText();
        // Stale results are dropped by the query equality check in the callback.
        io.execute(() -> {
            int[] result = SearchEngine.findAll(text, query, caseSensitive, regex, null);
            main.post(() -> {
                if (!query.equals(findInput.getText().toString())) {
                    return; // stale result
                }
                matches = result;
                matchIndex = matches.length > 0 ? 0 : -1;
                findCount.setText(matches.length > 0
                        ? (matchIndex + 1) + "/" + matches.length
                        : "0/" + matches.length);
                showMatchVisuals();
                if (matchIndex >= 0) {
                    gotoMatch(matchIndex);
                }
            });
        });
    }

    private String currentText() {
        if (editor.getVisibility() == View.VISIBLE) {
            return editor.getText().toString();
        }
        return viewer.getTextContent();
    }

    private void clearMatches() {
        matches = new int[0];
        matchIndex = -1;
        if (findCount != null) {
            findCount.setText("");
        }
        clearMatchVisuals();
    }

    private void clearMatchVisuals() {
        if (editor.getVisibility() == View.VISIBLE) {
            Editable e = editor.getText();
            BackgroundColorSpan[] spans = e.getSpans(0, e.length(), BackgroundColorSpan.class);
            for (BackgroundColorSpan s : spans) {
                if (s instanceof MatchSpan) {
                    e.removeSpan(s);
                }
            }
        } else {
            viewer.setMatches(new int[0], -1);
        }
    }

    private void showMatchVisuals() {
        if (editor.getVisibility() == View.VISIBLE) {
            Editable e = editor.getText();
            BackgroundColorSpan[] old = e.getSpans(0, e.length(), BackgroundColorSpan.class);
            for (BackgroundColorSpan s : old) {
                if (s instanceof MatchSpan) {
                    e.removeSpan(s);
                }
            }
            int cap = Math.min(matches.length / 2, 2000);
            int normal = getResources().getColor(R.color.find_highlight, null);
            int cur = getResources().getColor(R.color.find_current, null);
            for (int i = 0; i < cap; i++) {
                int s = matches[i * 2];
                int en = matches[i * 2 + 1];
                if (en > e.length()) {
                    continue;
                }
                e.setSpan(new MatchSpan(i == matchIndex ? cur : normal), s, en,
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        } else {
            viewer.setMatches(matches, matchIndex);
        }
    }

    private void gotoMatch(int index) {
        if (matches.length == 0) {
            return;
        }
        matchIndex = (index + matches.length) % matches.length;
        findCount.setText((matchIndex + 1) + "/" + matches.length);
        int start = matches[matchIndex * 2];
        int end = matches[matchIndex * 2 + 1];
        showMatchVisuals();
        if (editor.getVisibility() == View.VISIBLE) {
            editor.requestFocus();
            Layout layout = editor.getLayout();
            if (layout != null) {
                int line = layout.getLineForOffset(start);
                Rect r = new Rect(0, layout.getLineTop(line),
                        editor.getWidth(), layout.getLineBottom(line));
                editor.requestRectangleOnScreen(r, true);
            }
            editor.setSelection(end, start);
        } else {
            viewer.scrollToOffset(start);
        }
    }

    private void replaceCurrent() {
        if (editor.getVisibility() != View.VISIBLE) {
            Toast.makeText(this, "只读模式，无法替换", Toast.LENGTH_SHORT).show();
            return;
        }
        if (matchIndex < 0 || matchIndex * 2 + 1 >= matches.length) {
            return;
        }
        String query = findInput.getText().toString();
        String repl = replaceInput.getText().toString();
        boolean regex = ((android.widget.CheckBox) findViewById(R.id.findRegex)).isChecked();
        boolean caseSensitive = ((android.widget.CheckBox) findViewById(R.id.findCase)).isChecked();
        String text = editor.getText().toString();
        int start = matches[matchIndex * 2];
        int end = matches[matchIndex * 2 + 1];
        String newText = regex
                ? SearchEngine.replaceCurrentRegex(text, query, start, end, repl, caseSensitive)
                : SearchEngine.replaceRange(text, start, end, repl);
        setEditorTextPreservingCaret(newText, Math.min(start + repl.length(), newText.length()));
        runFindNow();
    }

    private void replaceAll() {
        if (editor.getVisibility() != View.VISIBLE) {
            Toast.makeText(this, "只读模式，无法替换", Toast.LENGTH_SHORT).show();
            return;
        }
        String query = findInput.getText().toString();
        String repl = replaceInput.getText().toString();
        boolean regex = ((android.widget.CheckBox) findViewById(R.id.findRegex)).isChecked();
        boolean caseSensitive = ((android.widget.CheckBox) findViewById(R.id.findCase)).isChecked();
        String text = editor.getText().toString();
        String newText = regex
                ? SearchEngine.replaceAllRegex(text, query, repl, caseSensitive)
                : SearchEngine.replaceAllLiteral(text, matches, repl);
        if (newText.equals(text)) {
            return;
        }
        int total = matches.length / 2;
        setEditorTextPreservingCaret(newText, 0);
        Toast.makeText(this, "已替换 " + total + " 处", Toast.LENGTH_SHORT).show();
        runFindNow();
    }

    private void setEditorTextPreservingCaret(String text, int caret) {
        suppressDirty = true;
        editor.setText(text);
        editor.setSelection(Math.min(caret, text.length()));
        suppressDirty = false;
        dirty = true;
    }

    private static final class MatchSpan extends BackgroundColorSpan {
        MatchSpan(int color) {
            super(color);
        }
    }

    // ---------------------------------------------------------------- browser / settings / menu

    private void startBrowser(String dir, boolean pickDir) {
        Intent i = new Intent(this, BrowserActivity.class);
        i.putExtra(BrowserActivity.EXTRA_MODE,
                pickDir ? BrowserActivity.MODE_PICK_DIR : BrowserActivity.MODE_OPEN);
        if (dir != null && !dir.isEmpty()) {
            i.putExtra(BrowserActivity.EXTRA_START_DIR, dir);
        }
        startActivityForResult(i, pickDir ? REQ_PICK_DIR : REQ_OPEN);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (resultCode != RESULT_OK || data == null) {
            return;
        }
        String path = data.getStringExtra(BrowserActivity.EXTRA_PATH);
        if (path == null) {
            return;
        }
        if (requestCode == REQ_OPEN) {
            prefs.recordDirectory(path.substring(0, path.lastIndexOf('/') + 1).replaceAll("/$", ""));
            openPath(path);
        } else if (requestCode == REQ_PICK_DIR) {
            prefs.recordDirectory(path);
            pendingDir = path;
            renderSaveDialog();
        }
    }

    private void openSettings() {
        startActivity(new Intent(this, SettingsActivity.class));
    }

    private void applyEditorSettings() {
        editor.applyStyle(prefs.fontSizeSp(), prefs.wordWrap());
        editor.setShowLineNumbers(prefs.showLineNumbers());
        if (viewer.getVisibility() == View.VISIBLE) {
            viewer.setFontSizeSp(prefs.fontSizeSp());
            viewer.setShowLineNumbers(prefs.showLineNumbers());
        }
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.main, menu);
        return true;
    }

    @Override
    public boolean onPrepareOptionsMenu(Menu menu) {
        SubMenu encodingMenu = menu.findItem(R.id.action_encoding).getSubMenu();
        encodingMenu.clear();
        String[] choices = EncodingDetector.USER_CHOICES;
        for (int i = 0; i < choices.length; i++) {
            MenuItem it = encodingMenu.add(1, MENU_ENCODING_BASE + i, i,
                    EncodingDetector.labelOf(choices[i]));
            it.setCheckable(true);
            it.setChecked(choices[i].equals(encoding) ||
                    (EncodingDetector.isAuto(choices[i]) && isAutoEncoding()));
        }
        MenuItem save = menu.findItem(R.id.action_save);
        MenuItem saveAs = menu.findItem(R.id.action_save_as);
        boolean canEdit = !readOnly || mode == Mode.SCRATCH;
        save.setEnabled(canEdit);
        saveAs.setEnabled(mode != Mode.SCRATCH || !readOnly);
        menu.findItem(R.id.action_restore_backup).setEnabled(mode == Mode.FILE);
        return super.onPrepareOptionsMenu(menu);
    }

    private boolean isAutoEncoding() {
        return EncodingDetector.isAuto(prefs.defaultEncoding());
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        int id = item.getItemId();
        if (id == R.id.action_new) {
            resetToScratch(null);
            return true;
        }
        if (id == R.id.action_open) {
            startBrowser(prefs.lastDirectory(), false);
            return true;
        }
        if (id == R.id.action_save) {
            actionSave();
            return true;
        }
        if (id == R.id.action_save_as) {
            actionSaveAs();
            return true;
        }
        if (id == R.id.action_find) {
            toggleFindBar();
            return true;
        }
        if (id == R.id.action_restore_backup) {
            restoreBackup();
            return true;
        }
        if (id == R.id.action_settings) {
            openSettings();
            return true;
        }
        if (id >= MENU_ENCODING_BASE && id < MENU_ENCODING_BASE + EncodingDetector.USER_CHOICES.length) {
            String chosen = EncodingDetector.USER_CHOICES[id - MENU_ENCODING_BASE];
            onEncodingChosen(chosen);
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    private void onEncodingChosen(String chosen) {
        if (mode == Mode.SCRATCH) {
            encoding = EncodingDetector.isAuto(chosen) ? EncodingDetector.UTF_8 : chosen;
            updateTitle();
            return;
        }
        // Re-decode from source with the chosen charset.
        String finalChosen = chosen;
        showProgress("重新解码…", true);
        io.execute(() -> {
            try {
                byte[] data;
                if (mode == Mode.FILE && filePath != null) {
                    File f = new File(filePath);
                    long size = f.length();
                    FileSizePolicy.Tier tier = FileSizePolicy.tierFor(size, false);
                    long limit = FileSizePolicy.readLimit(tier, size);
                    data = size <= limit ? AtomicFileWriter.readAtMost(f, limit)
                            : AtomicFileWriter.readHead(f, limit);
                } else if (contentUri != null) {
                    long size = querySize(contentUri);
                    data = readUri(contentUri, size > FileSizePolicy.FULL_VIEW_LIMIT
                            ? FileSizePolicy.HEAD_LIMIT : FileSizePolicy.FULL_VIEW_LIMIT);
                } else {
                    data = new byte[0];
                }
                String charset = EncodingDetector.isAuto(finalChosen)
                        ? EncodingDetector.detect(data) : finalChosen;
                String text = EncodingDetector.stripBom(EncodingDetector.decode(data, charset), charset);
                int[] lineStarts = buildLineStarts(text);
                main.post(() -> {
                    hideProgress();
                    encoding = charset;
                    boolean useEditor = !readOnly;
                    if (useEditor) {
                        suppressDirty = true;
                        editor.setText(text);
                        editor.setSelection(0);
                        suppressDirty = false;
                    } else {
                        viewer.setContent(text, lineStarts, prefs.showLineNumbers());
                    }
                    clearMatches();
                    updateTitle();
                });
            } catch (Exception e) {
                main.post(() -> {
                    hideProgress();
                    Toast.makeText(this, getString(R.string.load_failed, String.valueOf(e.getMessage())),
                            Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void updateTitle() {
        String name;
        if (mode == Mode.FILE && filePath != null) {
            name = new File(filePath).getName();
        } else if (mode == Mode.URI) {
            name = "分享的内容";
        } else {
            name = "未保存草稿";
        }
        String suffix = readOnly ? " · 只读" : (dirty ? " •" : "");
        setTitle(name + suffix + " · " + encoding);
    }

    // ---------------------------------------------------------------- find bar wiring

    @Override
    protected void onPostCreate(Bundle savedInstanceState) {
        super.onPostCreate(savedInstanceState);
        findViewById(R.id.findNext).setOnClickListener(v -> {
            if (matches.length > 0) {
                gotoMatch(matchIndex + 1);
            } else {
                runFindNow();
            }
        });
        findViewById(R.id.findPrev).setOnClickListener(v -> {
            if (matches.length > 0) {
                gotoMatch(matchIndex - 1);
            }
        });
        findViewById(R.id.findClose).setOnClickListener(v -> toggleFindBar());
        findViewById(R.id.replaceOne).setOnClickListener(v -> replaceCurrent());
        findViewById(R.id.replaceAll).setOnClickListener(v -> replaceAll());
        ((android.widget.CheckBox) findViewById(R.id.findCase))
                .setOnCheckedChangeListener((b, c) -> runFindNow());
        ((android.widget.CheckBox) findViewById(R.id.findRegex))
                .setOnCheckedChangeListener((b, c) -> runFindNow());
        findInput.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {
            }

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                main.removeCallbacks(findDebounce);
                main.postDelayed(findDebounce, 150);
            }
        });
        findInput.setOnEditorActionListener((v, actionId, event) -> {
            if (matches.length > 0) {
                gotoMatch(matchIndex + 1);
            }
            return true;
        });
    }

    // ---------------------------------------------------------------- permission / progress

    private boolean askedPermission = false;

    private void ensurePermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE}, 1);
            }
            return;
        }
        if (Environment.isExternalStorageManager()) {
            return;
        }
        if (askedPermission) {
            return;
        }
        askedPermission = true;
        new AlertDialog.Builder(this)
                .setTitle(R.string.permission_title)
                .setMessage(R.string.permission_message)
                .setPositiveButton(R.string.permission_grant, (d, w) -> {
                    try {
                        Intent i = new Intent(SettingsActionManage());
                        i.setData(Uri.parse("package:" + getPackageName()));
                        startActivity(i);
                    } catch (Exception e) {
                        Toast.makeText(this, R.string.permission_denied, Toast.LENGTH_LONG).show();
                    }
                })
                .setNegativeButton(R.string.save_cancel, null)
                .show();
    }

    private static String SettingsActionManage() {
        return "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION";
    }

    private void showProgress(String message, boolean cancelable) {
        hideProgress();
        progress = new ProgressDialog(this);
        progress.setMessage(message);
        progress.setCancelable(cancelable);
        if (cancelable) {
            progress.setButton(ProgressDialog.BUTTON_NEGATIVE, "取消",
                    (d, w) -> hideProgress());
        }
        progress.show();
    }

    private void hideProgress() {
        if (progress != null) {
            try {
                progress.dismiss();
            } catch (Exception ignored) {
            }
            progress = null;
        }
    }

    // ---------------------------------------------------------------- uri helpers

    private long querySize(Uri uri) {
        try (Cursor c = getContentResolver().query(uri,
                new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) {
                return c.getLong(0);
            }
        } catch (Exception ignored) {
        }
        return -1;
    }

    private byte[] readUri(Uri uri, long limit) throws Exception {
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) {
                throw new java.io.IOException("无法打开内容");
            }
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[64 * 1024];
            long total = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > limit) {
                    out.write(buf, 0, (int) (limit - (total - n)));
                    break;
                }
                out.write(buf, 0, n);
            }
            return out.toByteArray();
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        main.removeCallbacksAndMessages(null);
        io.shutdownNow();
    }
}
