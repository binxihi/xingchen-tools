#!/bin/bash
# Runs on GitHub Actions macos-14 (M1, native arm64) runner
set -euxo pipefail
cd "$GITHUB_WORKSPACE"
mkdir -p out
export ANDROID_HOME="$HOME/android-sdk"
mkdir -p "$ANDROID_HOME"
# 1) cmdline-tools
curl -sSLo ct.zip https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip
unzip -q ct.zip
mkdir -p "$ANDROID_HOME/cmdline-tools"
mv cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKM" --licenses >/dev/null 2>&1 || true
"$SDKM" "emulator" "platform-tools" "system-images;android-33;google_apis;x86_64" >/dev/null
# 2) frida server + python libs
curl -sSLo fs.xz https://github.com/frida/frida/releases/download/16.7.19/frida-server-16.7.19-android-x86_64.xz
xz -d fs.xz && chmod +x fs
python3 -m pip install --quiet frida==16.7.19 frida-tools==12.4.0
git clone --depth 1 https://github.com/hluwa/FRIDA-DEXDump.git
# 3) AVD + boot (M1 native arm64, Hypervisor accelerated)
AVDM="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
echo no | "$AVDM" create avd -n tga -k "system-images;android-33;google_apis;x86_64" --force
export PATH="$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator"
nohup emulator -avd tga -no-window -no-snapshot -gpu swiftshader_indirect -no-audio -no-boot-anim > emu.log 2>&1 &
adb wait-for-device
for i in $(seq 1 150); do
  BC=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [ "$BC" = "1" ]; then echo "BOOT_OK after $((i*10))s"; break; fi
  sleep 10
done
adb devices -l
adb root || true
sleep 3
# 4) frida-server up
adb push fs /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server
adb shell "nohup /data/local/tmp/frida-server -D >/dev/null 2>&1 &" || true
sleep 3
# 5) install + cold-launch TeleAgent (packer decrypts dex on Application attach)
adb install -r -t TeleAgent-official.apk
adb shell monkey -p com.teleai.teleagentmobile -c android.intent.category.LAUNCHER 1 || true
sleep 30
adb shell ps -A | grep -i teleagent || echo "PROC NOT FOUND"
# 6) dump dex from memory
cd FRIDA-DEXDump
python3 main.py -n com.teleai.teleagentmobile || python3 main.py -p "$(adb shell pidof com.teleai.teleagentmobile | tr -d '\r')" || true
# 7) harvest all fresh dex into out/
find "$HOME" "$GITHUB_WORKSPACE" -name '*.dex' -mmin -20 -size +10k 2>/dev/null | while read f; do cp "$f" out/ 2>/dev/null; done
ls -la ../out
echo "=== DUMP DONE ==="
