package io.github.hecate2.paper;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Environment;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Menu;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ListView;
import android.widget.PopupMenu;
import android.widget.TextView;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Simple real-path file browser.
 * Modes:
 *  - MODE_OPEN:    click a file -> RESULT_OK with its path (any extension)
 *  - MODE_PICK_DIR: show "select current directory" button -> RESULT_OK with the dir path
 * Directories always sort before files; the sort field/direction applies within each group.
 * Typing in the search box filters the entries of the current directory only (no recursion).
 */
public class BrowserActivity extends Activity {

    public static final String EXTRA_MODE = "mode";
    public static final String EXTRA_START_DIR = "startDir";
    public static final String MODE_OPEN = "open";
    public static final String MODE_PICK_DIR = "pickDir";

    public static final String EXTRA_PATH = "path";

    private static final int SORT_NAME = 0;
    private static final int SORT_SIZE = 1;
    private static final int SORT_DATE = 2;
    private static final int SORT_TYPE = 3;

    private File currentDir;
    private boolean pickDirMode;
    private final List<String> names = new ArrayList<>();
    private final List<File> entries = new ArrayList<>();
    private ArrayAdapter<String> adapter;

    private TextView pathView;
    private EditText searchInput;
    private ImageButton searchClear;
    private ImageButton sortDirBtn;
    private android.widget.Button sortBtn;

    private int sortField = SORT_NAME;
    private boolean sortDesc = false;
    private String query = "";
    /** True while we replace the search box text ourselves, to skip the redundant refresh. */
    private boolean suppressSearch;
    /** Row index of the trailing "searching…" hint, or -1 when there is none. */
    private int footerPos = -1;

    private int pathBgNormal;
    private int pathFgNormal;
    private int pathBgSearch;
    private int pathFgSearch;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browser);

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

        adapter = new ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, names) {
            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                TextView tv = (TextView) super.getView(position, convertView, parent);
                if (position == footerPos) {
                    tv.setBackgroundColor(pathBgSearch);
                    tv.setTextColor(pathFgSearch);
                    tv.setTypeface(null, Typeface.BOLD);
                } else {
                    tv.setBackgroundColor(Color.TRANSPARENT);
                    tv.setTextColor(pathFgNormal);
                    tv.setTypeface(null, Typeface.NORMAL);
                }
                return tv;
            }

            @Override
            public boolean isEnabled(int position) {
                // The trailing hint and the "empty"/"no match" placeholders are not clickable.
                return !names.isEmpty() && position < entries.size();
            }
        };
        list.setAdapter(adapter);

        if (pickDirMode) {
            pick.setVisibility(View.VISIBLE);
            pick.setOnClickListener(v -> {
                getIntent().putExtra(EXTRA_PATH, currentDir.getAbsolutePath());
                new Prefs(this).recordDirectory(currentDir.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            });
        }

        sortBtn.setOnClickListener(this::showSortMenu);
        sortDirBtn.setOnClickListener(v -> {
            sortDesc = !sortDesc;
            new Prefs(this).setBrowserSortDesc(sortDesc);
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

        list.setOnItemClickListener((parent, view, position, id) -> {
            if (position >= entries.size()) {
                return; // placeholder / footer row
            }
            File f = entries.get(position);
            if (f.isDirectory()) {
                currentDir = f;
                clearSearch();
                refresh();
            } else {
                getIntent().putExtra(EXTRA_PATH, f.getAbsolutePath());
                new Prefs(this).recordDirectory(currentDir.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            }
        });

        refresh();
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
            updateSortLabel();
            refresh();
            return true;
        });
        menu.show();
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

    private void updateSortDirIcon() {
        // Ascending = chevron up, descending = chevron down (both mean "smallest first").
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

    private static String extensionOf(File f) {
        String n = f.getName();
        int dot = n.lastIndexOf('.');
        return dot > 0 && dot < n.length() - 1 ? n.substring(dot + 1).toLowerCase() : "";
    }

    private Comparator<File> comparator() {
        Comparator<File> c;
        switch (sortField) {
            case SORT_SIZE:
                c = (a, b) -> {
                    int r = Long.compare(a.length(), b.length());
                    return r != 0 ? r : a.getName().compareToIgnoreCase(b.getName());
                };
                break;
            case SORT_DATE:
                c = (a, b) -> {
                    int r = Long.compare(a.lastModified(), b.lastModified());
                    return r != 0 ? r : a.getName().compareToIgnoreCase(b.getName());
                };
                break;
            case SORT_TYPE:
                c = (a, b) -> {
                    int r = extensionOf(a).compareTo(extensionOf(b));
                    return r != 0 ? r : a.getName().compareToIgnoreCase(b.getName());
                };
                break;
            default:
                c = (a, b) -> a.getName().compareToIgnoreCase(b.getName());
        }
        return sortDesc ? c.reversed() : c;
    }

    private void refresh() {
        updateSortLabel();
        names.clear();
        entries.clear();
        footerPos = -1;

        boolean searching = !query.isEmpty();
        pathView.setText(searching
                ? getString(R.string.browser_search_prefix, query) + " · " + currentDir.getAbsolutePath()
                : currentDir.getAbsolutePath());
        pathView.setBackgroundColor(searching ? pathBgSearch : pathBgNormal);
        pathView.setTextColor(searching ? pathFgSearch : pathFgNormal);

        List<File> dirs = new ArrayList<>();
        List<File> files = new ArrayList<>();
        File[] fs = currentDir.listFiles();
        if (fs != null) {
            for (File f : fs) {
                if (searching && !matches(f)) {
                    continue;
                }
                if (f.isDirectory()) {
                    dirs.add(f);
                } else {
                    files.add(f);
                }
            }
        }
        Comparator<File> c = comparator();
        Collections.sort(dirs, c);
        Collections.sort(files, c);

        for (File d : dirs) {
            entries.add(d);
            names.add("📁 " + d.getName());
        }
        for (File f : files) {
            entries.add(f);
            names.add(f.getName());
        }

        if (entries.isEmpty()) {
            names.add(getString(searching ? R.string.browser_search_none : R.string.browser_empty,
                    query));
        } else if (searching) {
            // Appended under the last hit so the active filter stays obvious even when the
            // user scrolls to the bottom of a long list.
            names.add(getString(R.string.browser_search_footer, query));
            footerPos = names.size() - 1;
        }
        adapter.notifyDataSetChanged();
    }

    private boolean matches(File f) {
        return f.getName().toLowerCase().contains(query.toLowerCase());
    }
}
