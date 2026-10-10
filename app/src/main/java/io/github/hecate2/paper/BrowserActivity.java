package io.github.hecate2.paper;

import android.app.ActionBar;
import android.app.Activity;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.TextView;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Simple real-path file browser.
 * Modes:
 *  - MODE_OPEN:    click a file -> RESULT_OK with its path (any extension)
 *  - MODE_PICK_DIR: show "select current directory" button -> RESULT_OK with the dir path
 * Directories always sort before files; the sort field/direction applies within each group.
 * Typing in the search box filters the entries of the current directory only (no recursion).
 *
 * <p>Directory listing, stat-ing and sorting all run on a background thread and the results
 * are published as an immutable row list, so a folder with tens of thousands of entries
 * never blocks the UI thread. A generation counter drops results for superseded loads.
 */
public class BrowserActivity extends Activity {

    public static final String EXTRA_MODE = "mode";
    public static final String EXTRA_START_DIR = "startDir";
    public static final String MODE_OPEN = "open";
    public static final String MODE_PICK_DIR = "pickDir";

    public static final String EXTRA_PATH = "path";
    /** Result flag: the user asked for a brand-new empty file instead of an existing one. */
    public static final String EXTRA_NEW_FILE = "newFile";

    private static final int SORT_NAME = 0;
    private static final int SORT_SIZE = 1;
    private static final int SORT_DATE = 2;
    private static final int SORT_TYPE = 3;

    private static final int KIND_ENTRY = 0;
    private static final int KIND_EMPTY = 1;
    private static final int KIND_FOOTER = 2;

    /** One list row. Entries carry their stat results so scrolling never touches the disk. */
    private static final class Row {
        final int kind;
        final String name;
        final boolean dir;
        final long size;
        final long mtime;

        Row(int kind, String name, boolean dir, long size, long mtime) {
            this.kind = kind;
            this.name = name;
            this.dir = dir;
            this.size = size;
            this.mtime = mtime;
        }
    }

    private File currentDir;
    private boolean pickDirMode;

    private final List<Row> rows = new ArrayList<>();
    private RowAdapter adapter;

    private TextView pathView;
    private EditText searchInput;
    private ImageButton searchClear;
    private ImageButton sortDirBtn;
    private Button sortBtn;

    private int sortField = SORT_NAME;
    private boolean sortDesc = false;
    private String query = "";
    /** True while we replace the search box text ourselves, to skip the redundant refresh. */
    private boolean suppressSearch;

    private int pathBgNormal;
    private int pathFgNormal;
    private int pathBgSearch;
    private int pathFgSearch;

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    /** Incremented per load; a result whose id is stale is discarded. */
    private int loadSeq;
    private final SimpleDateFormat dateFormat = new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browser);

        // Phones without a navigation bar need their own way back to the editor.
        ActionBar bar = getActionBar();
        if (bar != null) {
            bar.setDisplayHomeAsUpEnabled(true);
        }

        Prefs prefs = new Prefs(this);
        sortField = fieldFromKey(prefs.browserSort());
        sortDesc = prefs.browserSortDesc();

        pickDirMode = MODE_PICK_DIR.equals(getIntent().getStringExtra(EXTRA_MODE));
        String start = getIntent().getStringExtra(EXTRA_START_DIR);
        if (start == null || start.isEmpty()) {
            start = Environment.getExternalStorageDirectory().getAbsolutePath();
        }
        currentDir = new File(start);
        while (currentDir != null && !currentDir.isDirectory()) {
            currentDir = currentDir.getParentFile();
        }
        if (currentDir == null) {
            currentDir = new File("/");
        }

        pathView = findViewById(R.id.pathView);
        ListView list = findViewById(R.id.list);
        ImageButton up = findViewById(R.id.btnUp);
        ImageButton pick = findViewById(R.id.btnPickDir);
        sortBtn = findViewById(R.id.btnSort);
        sortDirBtn = findViewById(R.id.btnSortDir);
        searchInput = findViewById(R.id.searchInput);
        searchClear = findViewById(R.id.btnSearchClear);

        pathBgNormal = getColor(R.color.browser_path_bg);
        pathFgNormal = getColor(R.color.browser_path_text);
        pathBgSearch = getColor(R.color.browser_search_bg);
        pathFgSearch = getColor(R.color.browser_search_text);

        adapter = new RowAdapter();
        list.setAdapter(adapter);
        list.setOnItemClickListener((parent, view, position, id) -> {
            Row r = rows.get(position);
            if (r.kind != KIND_ENTRY) {
                return; // placeholder / footer row
            }
            File f = new File(currentDir, r.name);
            if (r.dir) {
                currentDir = f;
                clearSearch();
                refresh();
            } else {
                getIntent().putExtra(EXTRA_PATH, f.getAbsolutePath());
                prefs.recordDirectory(currentDir.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            }
        });

        if (pickDirMode) {
            pick.setVisibility(View.VISIBLE);
            pick.setOnClickListener(v -> {
                getIntent().putExtra(EXTRA_PATH, currentDir.getAbsolutePath());
                prefs.recordDirectory(currentDir.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            });
        }

        sortBtn.setOnClickListener(this::showSortMenu);
        sortDirBtn.setOnClickListener(v -> {
            sortDesc = !sortDesc;
            prefs.setBrowserSortDesc(sortDesc);
            updateSortDirIcon();
            refresh();
        });
        updateSortDirIcon();

        searchInput.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {
            }

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                if (suppressSearch) {
                    return;
                }
                query = s.toString().trim();
                searchClear.setVisibility(query.isEmpty() ? View.GONE : View.VISIBLE);
                refresh();
            }
        });

        searchClear.setOnClickListener(v -> {
            clearSearch();
            refresh();
        });

        up.setOnClickListener(v -> {
            if (currentDir.getParentFile() != null) {
                currentDir = currentDir.getParentFile();
                clearSearch();
                refresh();
            }
        });

        refresh();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        io.shutdownNow();
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.browser, menu);
        // Picking a directory has nothing to do with creating a file.
        menu.findItem(R.id.action_new_file).setVisible(!pickDirMode);
        return true;
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        int id = item.getItemId();
        if (id == android.R.id.home) {
            finish();
            return true;
        }
        if (id == R.id.action_new_file) {
            // Remember where the user was so a later 保存 lands in this directory.
            new Prefs(this).recordDirectory(currentDir.getAbsolutePath());
            getIntent().putExtra(EXTRA_NEW_FILE, true);
            setResult(RESULT_OK, getIntent());
            finish();
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    private void clearSearch() {
        if (query.isEmpty() && searchInput.getText().length() == 0) {
            return;
        }
        query = "";
        suppressSearch = true;
        searchInput.setText("");
        suppressSearch = false;
        searchClear.setVisibility(View.GONE);
    }

    private void showSortMenu(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(Menu.NONE, SORT_NAME, SORT_NAME, R.string.browser_sort_name);
        menu.getMenu().add(Menu.NONE, SORT_SIZE, SORT_SIZE, R.string.browser_sort_size);
        menu.getMenu().add(Menu.NONE, SORT_DATE, SORT_DATE, R.string.browser_sort_date);
        menu.getMenu().add(Menu.NONE, SORT_TYPE, SORT_TYPE, R.string.browser_sort_type);
        menu.setOnMenuItemClickListener(item -> {
            sortField = item.getItemId();
            new Prefs(this).setBrowserSort(fieldKey(sortField));
            refresh();
            return true;
        });
        menu.show();
    }

    private void updateSortDirIcon() {
        // Ascending = chevron up, descending = chevron down.
        sortDirBtn.setImageResource(sortDesc ? R.drawable.ic_chevron_down : R.drawable.ic_chevron_up);
        sortDirBtn.setContentDescription(
                getString(sortDesc ? R.string.browser_sort_desc : R.string.browser_sort_asc));
    }

    private static String fieldKey(int field) {
        switch (field) {
            case SORT_SIZE: return "size";
            case SORT_DATE: return "date";
            case SORT_TYPE: return "type";
            default: return "name";
        }
    }

    private static int fieldFromKey(String key) {
        if ("size".equals(key)) {
            return SORT_SIZE;
        }
        if ("date".equals(key)) {
            return SORT_DATE;
        }
        if ("type".equals(key)) {
            return SORT_TYPE;
        }
        return SORT_NAME;
    }

    private static String extensionOf(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 && dot < name.length() - 1 ? name.substring(dot + 1).toLowerCase(Locale.US) : "";
    }

    private static int nameOrder(Row a, Row b) {
        return a.name.compareToIgnoreCase(b.name);
    }

    /** Sorts already-stat-ed rows, so no comparator call touches the disk. */
    private Comparator<Row> rowComparator() {
        Comparator<Row> c;
        switch (sortField) {
            case SORT_SIZE:
                c = (a, b) -> {
                    int r = Long.compare(a.size, b.size);
                    return r != 0 ? r : nameOrder(a, b);
                };
                break;
            case SORT_DATE:
                c = (a, b) -> {
                    int r = Long.compare(a.mtime, b.mtime);
                    return r != 0 ? r : nameOrder(a, b);
                };
                break;
            case SORT_TYPE:
                c = (a, b) -> {
                    int r = extensionOf(a.name).compareTo(extensionOf(b.name));
                    return r != 0 ? r : nameOrder(a, b);
                };
                break;
            default:
                c = BrowserActivity::nameOrder;
        }
        return sortDesc ? c.reversed() : c;
    }

    private void refresh() {
        updateSortLabel();

        final File dir = currentDir;
        final String q = query;
        final boolean searching = !q.isEmpty();

        pathView.setText(searching
                ? getString(R.string.browser_search_prefix, q) + " · " + dir.getAbsolutePath()
                : dir.getAbsolutePath());
        pathView.setBackgroundColor(searching ? pathBgSearch : pathBgNormal);
        pathView.setTextColor(searching ? pathFgSearch : pathFgNormal);

        if (!dir.isDirectory()) {
            loadSeq++;
            rows.clear();
            rows.add(new Row(KIND_EMPTY, getString(R.string.browser_empty), false, 0, 0));
            adapter.notifyDataSetChanged();
            return;
        }

        // Only the very first load (or an empty result) gets a placeholder, so typing in
        // the search box never flashes the list away.
        if (rows.isEmpty()) {
            rows.add(new Row(KIND_EMPTY, getString(searching ? R.string.browser_search_none
                    : R.string.browser_loading, q), false, 0, 0));
            adapter.notifyDataSetChanged();
        }

        final int seq = ++loadSeq;
        final Comparator<Row> cmp = rowComparator();
        final String needle = q.toLowerCase(Locale.US);
        io.execute(() -> {
            List<Row> out = new ArrayList<>();
            File[] fs = dir.listFiles();
            if (fs != null) {
                List<Row> dirs = new ArrayList<>();
                List<Row> files = new ArrayList<>();
                for (File f : fs) {
                    String name = f.getName();
                    if (searching && !name.toLowerCase(Locale.US).contains(needle)) {
                        continue;
                    }
                    // Stat once here rather than on every scroll or comparison.
                    boolean isDir = f.isDirectory();
                    (isDir ? dirs : files).add(
                            new Row(KIND_ENTRY, name, isDir, isDir ? 0 : f.length(), f.lastModified()));
                }
                Collections.sort(dirs, cmp);
                Collections.sort(files, cmp);
                out.addAll(dirs);
                out.addAll(files);
            }
            if (out.isEmpty()) {
                out.add(new Row(KIND_EMPTY, getString(
                        searching ? R.string.browser_search_none : R.string.browser_empty, q),
                        false, 0, 0));
            } else if (searching) {
                // Under the last hit, so the active filter stays obvious when scrolled down.
                out.add(new Row(KIND_FOOTER, getString(R.string.browser_search_footer, q),
                        false, 0, 0));
            }
            final List<Row> result = out;
            main.post(() -> {
                if (seq != loadSeq) {
                    return; // superseded by a newer directory/search/sort
                }
                rows.clear();
                rows.addAll(result);
                adapter.notifyDataSetChanged();
            });
        });
    }

    /** Human-readable size; folders have none, so they show their type instead. */
    private static String formatSize(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double kb = bytes / 1024.0;
        if (kb < 1024) {
            return String.format(Locale.US, "%.1f KB", kb);
        }
        double mb = kb / 1024.0;
        if (mb < 1024) {
            return String.format(Locale.US, "%.1f MB", mb);
        }
        return String.format(Locale.US, "%.1f GB", mb / 1024.0);
    }

    private final class RowAdapter extends BaseAdapter {

        @Override
        public int getCount() {
            return rows.size();
        }

        @Override
        public Row getItem(int position) {
            return rows.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public boolean isEnabled(int position) {
            return getItem(position).kind == KIND_ENTRY;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            View v = convertView;
            if (v == null) {
                v = getLayoutInflater().inflate(R.layout.browser_row, parent, false);
            }
            TextView name = v.findViewById(R.id.rowName);
            TextView meta = v.findViewById(R.id.rowMeta);
            Row r = getItem(position);
            if (r.kind == KIND_ENTRY) {
                name.setText(r.dir ? "📁 " + r.name : r.name);
                name.setSingleLine(true);
                meta.setVisibility(View.VISIBLE);
                String when = dateFormat.format(new Date(r.mtime));
                meta.setText(r.dir
                        ? getString(R.string.browser_folder) + " · " + when
                        : formatSize(r.size) + " · " + when);
            } else {
                name.setText(r.name);
                name.setSingleLine(r.kind == KIND_FOOTER);
                meta.setVisibility(View.GONE);
            }
            return v;
        }
    }

    private void updateSortLabel() {
        int res;
        switch (sortField) {
            case SORT_SIZE: res = R.string.browser_sort_size; break;
            case SORT_DATE: res = R.string.browser_sort_date; break;
            case SORT_TYPE: res = R.string.browser_sort_type; break;
            default: res = R.string.browser_sort_name;
        }
        sortBtn.setText(res);
    }
}
