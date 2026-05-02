#!/usr/bin/env python3
"""
Dock app: starts Flask in a background thread and shows the dashboard
in a native WKWebView window. Stays in the Dock; re-opens on icon click.
"""
import subprocess
import sys
import threading
import time
from pathlib import Path

import objc
from AppKit import (
    NSApplication, NSApp, NSObject, NSWindow,
    NSWindowStyleMaskTitled, NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable, NSWindowStyleMaskResizable,
    NSBackingStoreBuffered,
    NSApplicationActivationPolicyRegular,
    NSViewWidthSizable, NSViewHeightSizable,
    NSMenu, NSMenuItem,
)
from Foundation import NSURL, NSURLRequest, NSMakeRect
from WebKit import WKWebView, WKWebViewConfiguration

DIR = Path(__file__).parent
PORT = 5001


def _is_running(script: str) -> bool:
    return subprocess.run(["pgrep", "-f", script], capture_output=True).returncode == 0


def _flask_thread():
    sys.path.insert(0, str(DIR))
    from dashboard import app
    app.run(host="127.0.0.1", port=PORT, debug=False, use_reloader=False)


def _wait_flask(timeout=10.0) -> bool:
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://localhost:{PORT}/", timeout=0.5)
            return True
        except Exception:
            time.sleep(0.3)
    return False


class AppDelegate(NSObject):
    _window = None

    def applicationDidFinishLaunching_(self, _n):
        threading.Thread(target=_flask_thread, daemon=True).start()

        if not _is_running("tracker.py"):
            subprocess.Popen(
                [sys.executable, str(DIR / "tracker.py")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        from Foundation import NSTimer
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            2.0, self, "openWindow:", None, False
        )

    def openWindow_(self, _):
        if not _wait_flask():
            return
        if self._window is None:
            self._window = self._make_window()
        self._window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    @objc.python_method
    def _make_window(self):
        style = (
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        )
        win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 1020, 760), style, NSBackingStoreBuffered, False
        )
        win.setTitle_("活动记录")
        win.setMinSize_((700, 500))
        win.center()

        cfg = WKWebViewConfiguration.alloc().init()
        wv = WKWebView.alloc().initWithFrame_configuration_(
            win.contentView().bounds(), cfg
        )
        wv.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
        win.contentView().addSubview_(wv)
        wv.loadRequest_(NSURLRequest.requestWithURL_(
            NSURL.URLWithString_(f"http://localhost:{PORT}")
        ))
        return win

    def applicationShouldTerminateAfterLastWindowClosed_(self, _app):
        return False   # keep in Dock even when window is closed

    def applicationShouldHandleReopen_hasVisibleWindows_(self, _app, has_visible):
        if not has_visible:
            if self._window is None:
                self._window = self._make_window()
            self._window.makeKeyAndOrderFront_(None)
            NSApp.activateIgnoringOtherApps_(True)
        return True


def main():
    sys.path.insert(0, str(DIR))
    from db import init_db
    init_db()

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)

    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)

    # Minimal menu so Cmd+Q works
    mb = NSMenu.alloc().init()
    app_item = NSMenuItem.alloc().init()
    mb.addItem_(app_item)
    app.setMainMenu_(mb)
    app_menu = NSMenu.alloc().init()
    app_menu.addItem_(NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        "退出活动记录", "terminate:", "q"
    ))
    app_item.setSubmenu_(app_menu)

    app.run()


if __name__ == "__main__":
    main()
