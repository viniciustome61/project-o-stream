"""
Unity Capture registration test.
Run this script directly — it will self-elevate via UAC if needed.
Results are written to test_ucap.log next to this script.
"""
import os, sys, subprocess, winreg, ctypes, time

base = os.path.dirname(os.path.abspath(__file__))
log_path = os.path.join(base, "test_ucap.log")
dll64 = os.path.join(base, "releases", "server-win", "UC", "Install", "UnityCaptureFilter64.dll")
dll32 = os.path.join(base, "releases", "server-win", "UC", "Install", "UnityCaptureFilter32.dll")
sys_root = os.environ.get("SystemRoot", r"C:\Windows")
reg64 = os.path.join(sys_root, "System32", "regsvr32.exe")
reg32 = os.path.join(sys_root, "SysWOW64", "regsvr32.exe")
count = 4


def log(msg):
    print(msg)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(msg + "\n")


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except:
        return False


def run_reg(exe, dll, extra_args):
    cmd = [exe, "/s"] + extra_args + [dll]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        proc.wait(timeout=15)
        return proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait()
        return -999


def count_unity_devices():
    found = []
    for hive_name, hive in [("HKLM", winreg.HKEY_LOCAL_MACHINE), ("HKCU", winreg.HKEY_CURRENT_USER)]:
        for path in [r"SOFTWARE\Classes\CLSID", r"SOFTWARE\WOW6432Node\Classes\CLSID"]:
            try:
                key = winreg.OpenKey(hive, path)
                i = 0
                while True:
                    try:
                        sub = winreg.EnumKey(key, i)
                        try:
                            sk = winreg.OpenKey(key, sub)
                            val, _ = winreg.QueryValueEx(sk, "")
                            if "Unity" in str(val):
                                found.append(f"  [{hive_name}] {sub}: {val}")
                            winreg.CloseKey(sk)
                        except Exception:
                            pass
                        i += 1
                    except OSError:
                        break
                winreg.CloseKey(key)
            except Exception:
                pass
    return found


# --- Clear log ---
open(log_path, "w").close()

admin = is_admin()
log(f"Running as admin: {admin}")
log(f"dll64 exists: {os.path.isfile(dll64)}")
log(f"dll32 exists: {os.path.isfile(dll32)}")

if not admin:
    log("Not admin — launching elevated copy via ShellExecuteW (approve UAC)...")
    # Re-launch this script elevated; SW_SHOW=5 so the window is visible
    ret = ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, f'"{os.path.abspath(__file__)}"', None, 5
    )
    log(f"ShellExecuteW ret={ret} (>32 = success)")
    log("Elevated window should have opened. Check test_ucap.log for results.")
    input("Press Enter to close (check test_ucap.log for elevated results)...")
    sys.exit(0)

# --- Admin path ---
log("\n=== REGISTER 4 devices ===")
extra = [f"/i:UnityCaptureDevices={count}"]

rc64 = run_reg(reg64, dll64, extra)
log(f"  regsvr32_64 exit={rc64}")

rc32 = run_reg(reg32, dll32, extra)
log(f"  regsvr32_32 exit={rc32}")

log(f"\nregister ok: {rc64 == 0 or rc32 == 0}")

log("\n=== Registry scan ===")
devices = count_unity_devices()
if devices:
    for d in devices: log(d)
else:
    log("No Unity Capture entries found")

log("\n--- Sleeping 5s, then UNREGISTER ---")
time.sleep(5)

log("\n=== UNREGISTER ===")
rc64 = run_reg(reg64, dll64, ["/u"])
rc32 = run_reg(reg32, dll32, ["/u"])
log(f"  unregister_64 exit={rc64}, unregister_32 exit={rc32}")

log("\n=== Registry scan after unregister ===")
devices = count_unity_devices()
if devices:
    for d in devices: log(d)
else:
    log("No Unity Capture entries found (clean)")

log("\n=== DONE ===")
input("Done. Press Enter to close.")
