# Modern Window Shading in KDE Plasma 6 (Wayland)

## 1. Context & Upstream Decisions

Window Shading (also known as *Window Roll-up* or *Fenster einrollen*) has been a core feature of X11-based window managers for decades (dating back to Mac OS System 7, FVWM, Window Maker, and classic KDE KWin). It allowed users to collapse a window upwards into its titlebar while retaining its geometry and screen position.

With the architectural transition to **Wayland** in KDE Plasma 6, Window Shading was officially removed from KWin.

### The Upstream Stance: KDE Bug #377162 & Duplicates
The removal triggered extensive community debate across the KDE bug tracker:
* **Primary Report:** [KDE Bug #377162 – *Feature request: Support window shading on Wayland*](https://bugs.kde.org/show_bug.cgi?id=377162) (Resolved as `INTENTIONAL` / `WONTFIX`).
* **Related Reports & Duplicates:** Bug #479860, Bug #468499, and related Plasma Wayland tracking tasks.

**Core Upstream Arguments Against Wayland Shading:**
* **Client-Side Decorations (CSD) vs. Server-Side Decorations (SSD):** Under Wayland, toolkits such as GTK4/libadwaita, Chromium, and Electron draw their own titlebars. A compositor cannot generically shrink an arbitrary client surface to a height of 0 or just its header height without breaking internal toolkit layout calculations or triggering crashes.
* **Buffer Protocol Contracts:** Wayland protocol rules require clients to commit surface buffers. If KWin forces a window surface smaller than the client's declared `min_size`, clients frequently misrender, freeze, or reject configure events.
* **Compositor Maintenance:** Maintaining dedicated geometry-shading hacks in KWin’s core scene graph for a legacy feature was deemed unsustainable by upstream maintainers.

**The Approach Taken Here:** Rather than trying to force client surfaces to shrink (which violates Wayland protocol contracts), we separate the lifecycle completely: **Minimize the target client and project a standalone, floating pseudo-titlebar (`shadeToggle`) onto its exact screen coordinates.**

---

## 2. Architecture & Execution Flow

The design consolidates the entire workflow into a single, self-contained executable (`shadeToggle`).

1. **Trigger:** The global shortcut (`Ctrl+I`) invokes `/home/stefan/bin/shadeToggle`.
2. **D-Bus Registration:** `shadeToggle` starts a PyQt6 application and registers an isolated D-Bus service endpoint (`org.kde.ShadeBar_<PID>`) on the session bus.
3. **KWin Script Injection:** It dynamically generates a temporary ECMAScript snippet and loads it into KWin via `org.kde.kwin.Scripting`.
4. **State Query & Self-Filtering:** The KWin script checks `workspace.activeWindow`. If the active window is already a `ShadeBar`, it filters it out and traverses `workspace.stackingOrder` backwards to target the uppermost valid application window.
5. **Geometry Extraction & Minimize:** It captures `internalId`, `caption`, and the geometry tuple $(x, y, w)$, triggers the D-Bus callback `show_bar(...)` to `shadeToggle`, and sets `win.minimized = true`.
6. **UI Rendering:** Upon receiving `show_bar(...)`, `shadeToggle` applies system theme colors, configures 70% opacity, rounded corners, drag handlers, and renders the bar.
7. **Repositioning & Unshade:** The user can freely drag the bar across the workspace. Clicking `▲` or double-clicking restores the client window at the bar's new coordinates. Clicking `✕` closes the underlying application window directly via KWin Scripting.

---

## 3. The Design Journey: Pitfalls & Discarded Approaches

During development across the KDE/Wayland stack, several technical challenges and platform restrictions were navigated:

### A. The `xdg_shell` Coordinate Sandbox (Wayland Protocol Limitation)
* **Attempt:** Running `shadeBar` as a native Wayland client (`QT_QPA_PLATFORM=wayland`) and calling `setGeometry(x, y, width, 48)`.
* **Failure:** In Wayland's `xdg_shell`, clients are sandboxed and forbidden from setting their own global $(x, y)$ screen coordinates. KWin ignored position arguments and placed instances according to compositor placement rules (*Centered* or *Cascading*).

### B. KWin Scripting Geometry Overrides (`frameGeometry = ...`)
* **Attempt:** Using KWin JavaScript to force `client.frameGeometry = {x, y, width, height}` after mapping native Wayland surfaces.
* **Failure:** Under Plasma 6 Wayland, `frameGeometry` is read-only for `xdg_toplevel` surfaces from the scripting interface to prevent clickjacking and unwanted overlays. Position writes were silently dropped.

### C. Temporary KWin Window Rules (`kwinrulesrc`)
* **Attempt:** Injecting dynamic rules via `kwriteconfig6` targeting the title/class with `positionrule=2` (Force) and executing `qdbus6 org.kde.KWin /KWin reconfigure`.
* **Failure:** KWin evaluates window placement rules asynchronously during initial surface commitment. Race conditions between Qt surface creation and KWin rule cache updates caused windows to fall back to cascading placement.

### D. Focus Loss during Shortcut Dispatch (`kglobalaccel`)
* **Attempt:** Querying `workspace.activeWindow` directly inside the injected KWin script.
* **Failure:** When `kglobalaccel` captures a global shortcut (`Ctrl+I`), keyboard focus is briefly released, causing `workspace.activeWindow` to return `null` for a single compositor frame.
* **Fix:** Implemented a fallback scanning `workspace.stackingOrder` in reverse to locate the uppermost valid, non-minimized window.

### E. "Always on Top" & Z-Order Conflicts
* **Attempt:** Using `Qt.WindowType.Tool` and `Qt.WindowType.WindowStaysOnTopHint`.
* **Failure:** ShadeBars remained permanently pinned above all windows, disrupting multitasking.
* **Fix:** Converted the widget to a standard frameless top-level window (`Qt.WindowType.Window | Qt.WindowType.FramelessWindowHint`), allowing normal stacking order interactions.

### F. Recursive Self-Shading
* **Attempt:** Triggering `shadeToggle` while a `ShadeBar` was currently focused.
* **Failure:** KWin treated the ShadeBar as the active target, minimizing the bar itself and creating nested dummy bars.
* **Fix:** Added `isShadeBar()` inspection inside the KWin ECMAScript to explicitly ignore existing shade bars and search down the stacking order for real client windows.

---

## 4. Key Architectural Decisions

* **Pragmatic Coordinate Positioning via XCB (`QT_QPA_PLATFORM=xcb`):** Instead of requiring complex C-bindings for unstable protocols like `zwlr_layer_shell_v1`, `shadeToggle` initializes Qt with the XCB platform plugin. Through **Xwayland**, KWin honours absolute positioning via standard `XMoveResizeWindow` semantics.
* **Native Theme Integration:** Header background and text colors are parsed directly from `~/.config/kdeglobals` (`[WM]`, `[Colors:Header]`) and `/usr/share/color-schemes/*.colors`, with accent colors applied to borders and hover states.
* **Translucent Rounded Aesthetics:** 70% opacity background fill (`rgba(...)` / alpha 178) with anti-aliased 10 px rounded rectangle rendering via `QPainterPath` on a translucent widget canvas (`WA_TranslucentBackground`).
* **Interactive Dragging & Repositioning:** Mouse press and move events allow dragging the bar anywhere on the screen. On unshade, the underlying window is dynamically relocated to the bar's new coordinates.
* **Integrated Window Lifecycle Controls:** Dedicated unshade (`▲`) and close (`✕`) buttons, with the close action cleanly forwarding `client.closeWindow()` to KWin.
* **Ephemeral Script Lifecycle:** Scripts are generated on-demand in temporary files with process-specific IDs, executed, and immediately unloaded via `.unloadScript` to eliminate persistent KWin state overhead.

---

## 5. Complete Implementation (`bin/shadeToggle`)

```python
#!/usr/bin/env python3
import sys
import os
import subprocess
import tempfile
from pathlib import Path

# Force XCB/Xwayland backend to allow explicit global (x, y) positioning
os.environ["QT_QPA_PLATFORM"] = "xcb"

from PyQt6.QtWidgets import QApplication, QWidget, QHBoxLayout, QLabel, QToolButton
from PyQt6.QtCore import Qt, pyqtSlot, QPoint
from PyQt6.QtGui import QPainter, QColor, QPainterPath, QPen, QPalette
from PyQt6.QtDBus import QDBusConnection

def parse_rgb(val_str):
    if not val_str:
        return None
    try:
        parts = [int(v.strip()) for v in val_str.split(",") if v.strip()]
        if len(parts) >= 3:
            return QColor(parts[0], parts[1], parts[2])
    except Exception:
        pass
    return None

def get_theme_colors(app):
    bg = QColor(49, 54, 59)
    fg = QColor(239, 240, 241)
    accent = QColor(61, 174, 233)

    kdeglobals = Path.home() / ".config" / "kdeglobals"
    active_scheme_file = None

    if kdeglobals.is_file():
        current_group = ""
        with open(kdeglobals, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    current_group = line[1:-1]
                    continue
                if "=" in line:
                    k, v = [x.strip() for x in line.split("=", 1)]
                    if current_group == "General":
                        if k == "ColorScheme":
                            active_scheme_file = v
                        elif k == "AccentColor":
                            c = parse_rgb(v)
                            if c: accent = c
                    elif current_group == "WM":
                        if k == "activeBackground":
                            c = parse_rgb(v)
                            if c: bg = c
                        elif k == "activeForeground":
                            c = parse_rgb(v)
                            if c: fg = c
                    elif current_group == "Colors:Header" and bg == QColor(49, 54, 59):
                        if k == "BackgroundNormal":
                            c = parse_rgb(v)
                            if c: bg = c
                        elif k == "ForegroundNormal":
                            c = parse_rgb(v)
                            if c: fg = c
                    elif current_group == "Colors:Window" and bg == QColor(49, 54, 59):
                        if k == "BackgroundNormal":
                            c = parse_rgb(v)
                            if c: bg = c
                        elif k == "ForegroundNormal":
                            c = parse_rgb(v)
                            if c: fg = c

    if active_scheme_file:
        scheme_paths = [
            Path.home() / ".local/share/color-schemes" / f"{active_scheme_file}.colors",
            Path(f"/usr/share/color-schemes/{active_scheme_file}.colors")
        ]
        for sp in scheme_paths:
            if sp.is_file():
                current_group = ""
                with open(sp, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith("[") and line.endswith("]"):
                            current_group = line[1:-1]
                            continue
                        if "=" in line:
                            k, v = [x.strip() for x in line.split("=", 1)]
                            if current_group == "WM":
                                if k == "activeBackground":
                                    c = parse_rgb(v)
                                    if c: bg = c
                                elif k == "activeForeground":
                                    c = parse_rgb(v)
                                    if c: fg = c
                            elif current_group == "Colors:Header" and (bg == QColor(49, 54, 59)):
                                if k == "BackgroundNormal":
                                    c = parse_rgb(v)
                                    if c: bg = c
                                elif k == "ForegroundNormal":
                                    c = parse_rgb(v)
                                    if c: fg = c

    if bg == QColor(49, 54, 59):
        pal = app.palette()
        bg = pal.color(QPalette.ColorRole.Window)
        fg = pal.color(QPalette.ColorRole.WindowText)
        accent = pal.color(QPalette.ColorRole.Highlight)

    if bg.value() > 128:
        btn_bg = bg.darker(110)
        btn_border = bg.darker(130)
    else:
        btn_bg = bg.lighter(125)
        btn_border = bg.lighter(150)

    return bg, fg, accent, btn_bg, btn_border

class ShadeBar(QWidget):
    def __init__(self, bg, fg, accent, btn_bg, btn_border):
        super().__init__()
        self.win_id = ""
        self.orig_x = 0
        self.orig_y = 0
        self._drag_pos = QPoint()

        self.setWindowTitle("KWinShadeBar")
        self.setObjectName("KWinShadeBar")

        # 70% opacity background
        self.bg_color = QColor(bg.red(), bg.green(), bg.blue(), 178)
        self.fg_color = fg
        self.accent_color = accent

        self.setWindowFlags(
            Qt.WindowType.Window |
            Qt.WindowType.FramelessWindowHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)

        btn_bg_rgba = f"rgba({btn_bg.red()}, {btn_bg.green()}, {btn_bg.blue()}, 0.75)"
        btn_border_rgba = f"rgba({btn_border.red()}, {btn_border.green()}, {btn_border.blue()}, 0.85)"

        self.setStyleSheet(f"""
            QLabel {{
                color: {self.fg_color.name()};
                font-weight: bold;
                font-size: 18px;
                border: none;
                padding-left: 10px;
                background: transparent;
            }}
            QToolButton {{
                background-color: {btn_bg_rgba};
                color: {self.fg_color.name()};
                border: 1px solid {btn_border_rgba};
                border-radius: 6px;
                font-weight: bold;
                font-size: 16px;
                min-width: 32px;
                min-height: 32px;
                margin-right: 4px;
            }}
            QToolButton:hover {{
                background-color: {self.accent_color.name()};
                color: #ffffff;
            }}
            QToolButton#btnClose:hover {{
                background-color: #da4453;
                border-color: #ed1515;
                color: #ffffff;
            }}
        """)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 6, 8, 6)
        layout.setSpacing(6)

        self.label = QLabel("Window")
        layout.addWidget(self.label, 1)

        self.btn_unshade = QToolButton()
        self.btn_unshade.setText("▲")
        self.btn_unshade.setToolTip("Unshade Window")
        self.btn_unshade.clicked.connect(self.unshade_and_exit)
        layout.addWidget(self.btn_unshade)

        self.btn_close = QToolButton()
        self.btn_close.setObjectName("btnClose")
        self.btn_close.setText("✕")
        self.btn_close.setToolTip("Close Window")
        self.btn_close.clicked.connect(self.close_window_and_exit)
        layout.addWidget(self.btn_close)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)

        rect = self.rect().adjusted(1, 1, -1, -1)
        path = QPainterPath()
        radius = 10.0
        path.addRoundedRect(float(rect.x()), float(rect.y()), float(rect.width()), float(rect.height()), radius, radius)

        painter.fillPath(path, self.bg_color)
        pen = QPen(self.accent_color, 1.5)
        painter.setPen(pen)
        painter.drawPath(path)

    @pyqtSlot(str, str, str, str, str)
    def show_bar(self, win_id, caption, x, y, width):
        self.win_id = win_id
        self.label.setText(caption or "Window")
        
        self.orig_x = int(float(x))
        self.orig_y = int(float(y))
        bar_width = max(int(float(width)), 260)
        self.setGeometry(self.orig_x, self.orig_y, bar_width, 48)
        self.show()

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self._drag_pos = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()

    def mouseMoveEvent(self, event):
        if event.buttons() & Qt.MouseButton.LeftButton:
            self.move(event.globalPosition().toPoint() - self._drag_pos)
            event.accept()

    def mouseDoubleClickEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.unshade_and_exit()

    def close_window_and_exit(self):
        js = f"""
        (function() {{
            var clients = workspace.windowList();
            for (var i = 0; i < clients.length; i++) {{
                if (clients[i].internalId.toString() === "{self.win_id}") {{
                    clients[i].closeWindow();
                    break;
                }}
            }}
        }})();
        """
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(js)
            tmp_path = f.name

        script_id = f"close_{os.getpid()}"
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", tmp_path, script_id], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start"], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", script_id], stdout=subprocess.DEVNULL)
        os.remove(tmp_path)

        QApplication.quit()

    def unshade_and_exit(self):
        current_x = self.x()
        current_y = self.y()
        dx = current_x - self.orig_x
        dy = current_y - self.orig_y

        js = f"""
        (function() {{
            var clients = workspace.windowList();
            for (var i = 0; i < clients.length; i++) {{
                if (clients[i].internalId.toString() === "{self.win_id}") {{
                    clients[i].minimized = false;
                    workspace.activeWindow = clients[i];
                    
                    if ({dx} !== 0 || {dy} !== 0) {{
                        var g = clients[i].frameGeometry;
                        g.x = {current_x};
                        g.y = {current_y};
                        clients[i].frameGeometry = g;
                    }}
                    break;
                }}
            }}
        }})();
        """
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(js)
            tmp_path = f.name

        script_id = f"unshade_{os.getpid()}"
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", tmp_path, script_id], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start"], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", script_id], stdout=subprocess.DEVNULL)
        os.remove(tmp_path)

        QApplication.quit()

def main():
    try:
        service_name = f"org.kde.ShadeBar_{os.getpid()}"
        app = QApplication(sys.argv)
        app.setApplicationName("KWinShadeBar")
        app.setQuitOnLastWindowClosed(False)

        bg, fg, accent, btn_bg, btn_border = get_theme_colors(app)
        bar = ShadeBar(bg, fg, accent, btn_bg, btn_border)
        bus = QDBusConnection.sessionBus()

        if not bus.registerService(service_name):
            sys.exit(1)
        if not bus.registerObject("/ShadeBar", bar, QDBusConnection.RegisterOption.ExportAllSlots):
            sys.exit(1)

        js_code = f"""
        (function() {{
            function isShadeBar(w) {{
                if (!w) return true;
                var resClass = String(w.resourceClass || "");
                var resName = String(w.resourceName || "");
                var cap = String(w.caption || "");
                return resClass.indexOf("ShadeBar") !== -1 ||
                       resName.indexOf("ShadeBar") !== -1 ||
                       resClass.indexOf("shadeToggle") !== -1 ||
                       resName.indexOf("shadeToggle") !== -1 ||
                       cap === "KWinShadeBar";
            }}

            var win = workspace.activeWindow;
            if (!win || !win.normalWindow || win.deleted || isShadeBar(win)) {{
                win = null;
                var list = workspace.stackingOrder;
                for (var i = list.length - 1; i >= 0; i--) {{
                    var candidate = list[i];
                    if (candidate.normalWindow && !candidate.minimized && !candidate.deleted && !isShadeBar(candidate)) {{
                        win = candidate;
                        break;
                    }}
                }}
            }}
            if (!win) return;

            var g = win.frameGeometry;
            var winId = win.internalId ? win.internalId.toString() : "";
            var caption = win.caption ? String(win.caption) : "Window";
            var x = String(Math.round(g.x));
            var y = String(Math.round(g.y));
            var w = String(Math.round(g.width));

            callDBus(
                "{service_name}",
                "/ShadeBar",
                "",
                "show_bar",
                winId,
                caption,
                x,
                y,
                w,
                function() {{}}
            );

            win.minimized = true;
        }})();
        """

        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
            f.write(js_code)
            js_path = f.name

        script_id = f"shade_{os.getpid()}"
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", js_path, script_id], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start"], stdout=subprocess.DEVNULL)
        subprocess.run(["qdbus6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", script_id], stdout=subprocess.DEVNULL)
        os.remove(js_path)

        sys.exit(app.exec())
    except Exception as e:
        with open("/tmp/shade_error.log", "a") as f:
            f.write(f"Error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
```
