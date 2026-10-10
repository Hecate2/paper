package io.github.hecate2.paper;

import android.app.Activity;
import android.os.Bundle;
import android.os.Environment;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ImageButton;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

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
 * Directories always sort before files, then alphabetically.
 */
public class BrowserActivity extends Activity {

    public static final String EXTRA_MODE = "mode";
    public static final String EXTRA_START_DIR = "startDir";
    public static final String MODE_OPEN = "open";
    public static final String MODE_PICK_DIR = "pickDir";

    public static final String EXTRA_PATH = "path";

    private File currentDir;
    private boolean pickDirMode;
    private final List<String> names = new ArrayList<>();
    private final List<File> entries = new ArrayList<>();
    private ArrayAdapter<String> adapter;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_browser);

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
        Button pick = findViewById(R.id.btnPickDir);

        adapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1, names);
        list.setAdapter(adapter);

        if (pickDirMode) {
            pick.setVisibility(View.VISIBLE);
            pick.setOnClickListener(v -> {
                getIntent().putExtra(EXTRA_PATH, currentDir.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            });
        }

        up.setOnClickListener(v -> {
            if (currentDir.getParentFile() != null) {
                currentDir = currentDir.getParentFile();
                refresh();
            }
        });

        list.setOnItemClickListener((parent, view, position, id) -> {
            File f = entries.get(position);
            if (f.isDirectory()) {
                currentDir = f;
                refresh();
            } else {
                getIntent().putExtra(EXTRA_PATH, f.getAbsolutePath());
                setResult(RESULT_OK, getIntent());
                finish();
            }
        });

        refresh();
    }

    private TextView pathView;

    private void refresh() {
        pathView.setText(currentDir.getAbsolutePath());
        names.clear();
        entries.clear();

        File[] fs = currentDir.listFiles();
        if (fs != null) {
            List<File> dirs = new ArrayList<>();
            List<File> files = new ArrayList<>();
            for (File f : fs) {
                if (f.isDirectory()) {
                    dirs.add(f);
                } else {
                    files.add(f);
                }
            }
            Comparator<File> byName = (a, b) ->
                    a.getName().compareToIgnoreCase(b.getName());
            Collections.sort(dirs, byName);
            Collections.sort(files, byName);
            for (File d : dirs) {
                entries.add(d);
                names.add("📁 " + d.getName());
            }
            for (File f : files) {
                entries.add(f);
                names.add(f.getName());
            }
        }
        if (names.isEmpty()) {
            names.add(getString(R.string.browser_empty));
        }
        adapter.notifyDataSetChanged();
    }
}
