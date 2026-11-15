"""Adjusts the Windows runner that `flutter create` generates (run by
.github/workflows/build_windows.yml after it):

- the window opens centred on the screen, as large as fits comfortably
  (up to 1360x860, at most 90% of the work area);
- it can't be made smaller than 820x560, below which the pages get cramped.

Usage: python patch_windows_runner.py <path to the windows/runner folder>
"""
import pathlib
import sys

runner = pathlib.Path(sys.argv[1])


def patch(name, old, new):
    path = runner / name
    text = path.read_text(encoding="utf-8")
    if old not in text:
        sys.exit(f"{name}: expected text not found:\n{old}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched {name}")


patch(
    "main.cpp",
    """  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);""",
    """  // Centred on the screen, as large as fits comfortably (in logical
  // pixels, like Create() expects).
  RECT work{};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  HDC screen = ::GetDC(nullptr);
  const double scale = ::GetDeviceCaps(screen, LOGPIXELSX) / 96.0;
  ::ReleaseDC(nullptr, screen);
  const int work_w = static_cast<int>((work.right - work.left) / scale);
  const int work_h = static_cast<int>((work.bottom - work.top) / scale);
  const int width = work_w * 9 / 10 < 1360 ? work_w * 9 / 10 : 1360;
  const int height = work_h * 9 / 10 < 860 ? work_h * 9 / 10 : 860;
  Win32Window::Point origin(static_cast<int>(work.left / scale) + (work_w - width) / 2,
                            static_cast<int>(work.top / scale) + (work_h - height) / 2);
  Win32Window::Size size(width, height);""",
)

patch("flutter_window.cpp", "#include <optional>\n", "#include <flutter_windows.h>\n\n#include <optional>\n")

patch(
    "flutter_window.cpp",
    """  switch (message) {
    case WM_FONTCHANGE:""",
    """  switch (message) {
    case WM_GETMINMAXINFO: {
      // Smallest window size, scaled to the screen's DPI.
      const double scale = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(820 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(560 * scale);
      return 0;
    }
    case WM_FONTCHANGE:""",
)
