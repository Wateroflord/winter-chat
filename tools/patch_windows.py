"""Настраивает сгенерированный Windows-проект (совместимость плагинов с новым Visual Studio)."""
import pathlib
import re

p = pathlib.Path("windows/CMakeLists.txt")
t = p.read_text(encoding="utf-8")
if "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS" not in t:
    t = re.sub(r"(project\([^)]*\)\n)", r"\1add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)\n", t, count=1)
p.write_text(t, encoding="utf-8")

main = pathlib.Path("windows/runner/main.cpp")
m = main.read_text(encoding="utf-8")
m = m.replace('L"winter_chat"', 'L"Winter Chat"')
m = m.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1200, 800);")
main.write_text(m, encoding="utf-8")
print("patched windows")
