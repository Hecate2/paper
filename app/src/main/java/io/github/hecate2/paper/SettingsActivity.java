package io.github.hecate2.paper;

import android.app.Activity;
import android.os.Bundle;
import android.widget.ArrayAdapter;
import android.widget.CheckBox;
import android.widget.RadioGroup;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;

import io.github.hecate2.paper.core.EncodingDetector;
import io.github.hecate2.paper.core.StartupDecision;

/**
 * Settings screen. Every control writes straight to Prefs so the values are
 * remembered immediately; MainActivity re-applies them in onResume().
 */
public class SettingsActivity extends Activity {

    private Prefs prefs;

    private static final int[] AUTOSAVE_VALUES = {0, 5, 10, 30, 60, 300};
    private static final String[] AUTOSAVE_LABELS = {
            "关闭", "5 秒", "10 秒", "30 秒", "1 分钟", "5 分钟"
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_settings);
        prefs = new Prefs(this);

        // --- startup mode ---
        RadioGroup startup = findViewById(R.id.startupGroup);
        String mode = prefs.startupMode();
        if (StartupDecision.MODE_NEW_EMPTY.equals(mode)) {
            startup.check(R.id.startupNew);
        } else if (StartupDecision.MODE_LAST_DIR.equals(mode)) {
            startup.check(R.id.startupDir);
        } else {
            startup.check(R.id.startupFile);
        }
        startup.setOnCheckedChangeListener((group, checkedId) -> {
            if (checkedId == R.id.startupNew) {
                prefs.setStartupMode(StartupDecision.MODE_NEW_EMPTY);
            } else if (checkedId == R.id.startupDir) {
                prefs.setStartupMode(StartupDecision.MODE_LAST_DIR);
            } else {
                prefs.setStartupMode(StartupDecision.MODE_LAST_FILE);
            }
        });

        // --- autosave interval ---
        Spinner autosave = findViewById(R.id.autosaveSpinner);
        autosave.setAdapter(new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_dropdown_item, AUTOSAVE_LABELS));
        int interval = prefs.autosaveIntervalSec();
        int idx = 2; // default 10s
        for (int i = 0; i < AUTOSAVE_VALUES.length; i++) {
            if (AUTOSAVE_VALUES[i] == interval) {
                idx = i;
                break;
            }
        }
        autosave.setSelection(idx);
        autosave.setOnItemSelectedListener(new SimpleItemSelectedListener(i ->
                prefs.setAutosaveIntervalSec(AUTOSAVE_VALUES[i])));

        // --- font size ---
        SeekBar font = findViewById(R.id.fontSeek);
        TextView fontLabel = findViewById(R.id.fontLabel);
        int size = prefs.fontSizeSp();
        font.setMax(32 - 10);
        font.setProgress(size - 10);
        fontLabel.setText(getString(R.string.settings_font_size) + ": " + size + "sp");
        SeekBar.OnSeekBarChangeListener fontListener = new SeekBar.OnSeekBarChangeListener() {
            @Override
            public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                int sp = progress + 10;
                prefs.setFontSizeSp(sp);
                fontLabel.setText(getString(R.string.settings_font_size) + ": " + sp + "sp");
            }

            @Override
            public void onStartTrackingTouch(SeekBar seekBar) {
            }

            @Override
            public void onStopTrackingTouch(SeekBar seekBar) {
            }
        };
        font.setOnSeekBarChangeListener(fontListener);

        // --- line numbers ---
        CheckBox lineNumbers = findViewById(R.id.lineNumbersCheck);
        lineNumbers.setChecked(prefs.showLineNumbers());
        lineNumbers.setOnCheckedChangeListener((b, checked) -> prefs.setShowLineNumbers(checked));

        // --- word wrap ---
        CheckBox wordWrap = findViewById(R.id.wordWrapCheck);
        wordWrap.setChecked(prefs.wordWrap());
        wordWrap.setOnCheckedChangeListener((b, checked) -> prefs.setWordWrap(checked));

        // --- default encoding ---
        Spinner encoding = findViewById(R.id.encodingSpinner);
        String[] choices = EncodingDetector.USER_CHOICES;
        String[] labels = new String[choices.length];
        for (int i = 0; i < choices.length; i++) {
            labels[i] = EncodingDetector.labelOf(choices[i]);
        }
        encoding.setAdapter(new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_dropdown_item, labels));
        int encIdx = 0;
        for (int i = 0; i < choices.length; i++) {
            if (choices[i].equals(prefs.defaultEncoding())) {
                encIdx = i;
                break;
            }
        }
        encoding.setSelection(encIdx);
        encoding.setOnItemSelectedListener(new SimpleItemSelectedListener(i ->
                prefs.setDefaultEncoding(choices[i])));
    }
}
