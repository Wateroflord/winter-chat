"""Настраивает Linux-проект: заголовок и размер окна."""
import pathlib

p = pathlib.Path("linux/runner/my_application.cc")
if not p.exists():
    p = pathlib.Path("linux/my_application.cc")
t = p.read_text(encoding="utf-8")
t = t.replace('"winter_chat"', '"Winter Chat"')
t = t.replace("gtk_window_set_default_size(window, 1280, 720);", "gtk_window_set_default_size(window, 1200, 800);")
p.write_text(t, encoding="utf-8")
print("patched", p)
