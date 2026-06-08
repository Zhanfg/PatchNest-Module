#!/bin/sh

MODDIR=${0%/*}
# Load environment detection (available for future use)
. "$MODDIR/detect_env.sh" 2>/dev/null || true

# Try KSUWebUIStandalone first (works with all managers)
if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
    echo "- Launching WebUI in KSUWebUIStandalone..."
    am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "PatchNest"
    echo "- WebUI launched successfully."
    exit 0
fi

# KernelSU / ReSukiSU / SukiSU native WebUI
if pm path me.weishu.kernelsu >/dev/null 2>&1; then
    echo "- Launching via KernelSU..."
    am start -n "me.weishu.kernelsu/.ui.WebUIActivity" -e id "PatchNest"
    echo "- WebUI launched successfully."
    exit 0
fi

# APatch WebUI
if pm path me.bmax.apatch >/dev/null 2>&1; then
    echo "- Launching via APatch..."
    am start -n "me.bmax.apatch/.ui.WebUIActivity" -e id "PatchNest"
    echo "- WebUI launched successfully."
    exit 0
fi

# No WebUI app found — guide user to install
echo "! No WebUI app found"
echo ""
echo "  Install one of the following:"
echo "  1. KSUWebUIStandalone (recommended, works with all managers)"
echo "     https://github.com/KOWX712/KsuWebUIStandalone/releases"
echo ""
echo "  Or use via ADB shell:"
echo "  adb shell kpatch hello"
echo "  adb shell kpatch kpm list"
echo ""

# Try to open download page
sleep 2
am start -a android.intent.action.VIEW -d "https://github.com/KOWX712/KsuWebUIStandalone/releases" 2>/dev/null
