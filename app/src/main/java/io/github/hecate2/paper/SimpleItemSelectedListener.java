package io.github.hecate2.paper;

import android.view.View;
import android.widget.AdapterView;

/** Adapter that reports the selected position; ignores the initial layout pass. */
class SimpleItemSelectedListener implements AdapterView.OnItemSelectedListener {

    interface OnSelect {
        void onSelected(int position);
    }

    private final OnSelect onSelect;
    private boolean first = true;

    SimpleItemSelectedListener(OnSelect onSelect) {
        this.onSelect = onSelect;
    }

    @Override
    public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
        if (first) {
            first = false;
            return;
        }
        onSelect.onSelected(position);
    }

    @Override
    public void onNothingSelected(AdapterView<?> parent) {
    }
}
