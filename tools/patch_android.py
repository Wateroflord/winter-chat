"""Настраивает Android-проект Winter Chat: разрешения для звонков и демонстрации экрана, http к серверу, название."""
import pathlib
import re

ROOT = pathlib.Path("android/app")
m = ROOT / "src/main/AndroidManifest.xml"
t = m.read_text(encoding="utf-8")

perms = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.CHANGE_NETWORK_STATE",
    "android.permission.CAMERA",
    "android.permission.RECORD_AUDIO",
    "android.permission.MODIFY_AUDIO_SETTINGS",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.WAKE_LOCK",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
]
for p in perms:
    if p not in t:
        t = re.sub(r"(<manifest[^>]*>)", rf'\1\n    <uses-permission android:name="{p}"/>', t, count=1)
for p in ["android.permission.BLUETOOTH", "android.permission.BLUETOOTH_ADMIN"]:
    if f'"{p}"' not in t:
        t = re.sub(r"(<manifest[^>]*>)", rf'\1\n    <uses-permission android:name="{p}" android:maxSdkVersion="30"/>', t, count=1)
if "android.hardware.camera" not in t:
    t = re.sub(r"(<manifest[^>]*>)", r'\1\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>', t, count=1)

t = re.sub(r'android:label="[^"]*"', 'android:label="Winter Chat"', t, count=1)

# Сервер друга работает по обычному http (без сертификата).
if "usesCleartextTraffic" not in t:
    t = t.replace("<application", '<application android:usesCleartextTraffic="true"', 1)

# Сервис для демонстрации экрана (flutter_background).
service = (
    '        <service\n'
    '            android:name="de.julianassmann.flutter_background.IsolateHolderService"\n'
    '            android:enabled="true"\n'
    '            android:exported="false"\n'
    '            android:foregroundServiceType="mediaProjection" />\n'
)
if "IsolateHolderService" not in t:
    t = t.replace("</application>", service + "    </application>", 1)

m.write_text(t, encoding="utf-8")

# Правила, чтобы оптимизатор не вырезал WebRTC.
(ROOT / "proguard-rules.pro").write_text(
    "-keep class org.webrtc.** { *; }\n"
    "-keep class com.cloudwebrtc.webrtc.** { *; }\n"
    "-keep class io.livekit.** { *; }\n"
    "-dontwarn org.webrtc.**\n",
    encoding="utf-8",
)
g = ROOT / "build.gradle.kts"
if g.exists():
    gs = g.read_text(encoding="utf-8")
    if "proguard-rules.pro" not in gs:
        gs = gs.replace(
            'signingConfig = signingConfigs.getByName("debug")',
            'signingConfig = signingConfigs.getByName("debug")\n'
            '            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")',
            1,
        )
    gs = re.sub(r"minSdk = flutter\.minSdkVersion", "minSdk = 24", gs)
    g.write_text(gs, encoding="utf-8")

print(t)
