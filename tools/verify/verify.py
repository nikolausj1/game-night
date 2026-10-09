#!/usr/bin/env python3
"""Game Night verification matrix runner (invoked by tools/verify.sh).

Boots the dedicated sims, installs the shared build, then for every matrix
entry: launch with args, wait, screenshot, check the app is still alive and
the screen is not the home screen, auto-rotate iPad shots, and emit
index.html + REPORT.md. See tools/verify/README.md.
"""
import argparse, concurrent.futures, datetime, glob, html, json, os, signal, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCRATCH_DEFAULT = ("/private/tmp/claude-501/-Users-justinnikolaus-Library-CloudStorage-"
                   "Dropbox--Projects-Digital-Card-Games/a7478288-cfd6-4de8-b4f5-c4c42aabd4dd/scratchpad")
LOCK = threading.Lock()


def log(msg):
    with LOCK:
        print(time.strftime("%H:%M:%S"), msg, flush=True)


def sh(cmd, timeout=120, check=False):
    """Run a command with a hard timeout. Returns (rc, stdout, stderr); rc=-999 on timeout."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             start_new_session=True)
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            return -999, "", "timeout after %ss: %s" % (timeout, " ".join(cmd))
        return p.returncode, out, err
    except Exception as e:  # noqa
        return -998, "", str(e)


def simctl(*a, timeout=120):
    return sh(["xcrun", "simctl", *a], timeout=timeout)


def pid_alive(pid):
    if not pid:
        return False
    rc, out, _ = sh(["ps", "-p", str(pid), "-o", "pid="], timeout=15)
    return rc == 0 and out.strip() != ""


def img_signature(path, size=48):
    from PIL import Image
    im = Image.open(path).convert("L").resize((size, size))
    return list(im.getdata())


def img_stats(path):
    from PIL import Image, ImageStat
    im = Image.open(path).convert("L")
    st = ImageStat.Stat(im)
    return st.mean[0], st.stddev[0]


def mean_abs_diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def boot(dev, timeout):
    udid = dev["udid"]
    rc, out, err = simctl("boot", udid, timeout=timeout)
    if rc not in (0,) and "current state: Booted" not in err and "Booted" not in err:
        log("  boot %s: rc=%s %s" % (dev["name"], rc, err.strip()[:200]))
    rc, out, err = simctl("bootstatus", udid, "-b", timeout=timeout)
    tail = " | ".join([l.strip() for l in (out + err).strip().splitlines() if l.strip()][-3:])
    return rc == 0, "rc=%s %s" % (rc, tail[:300])


def set_reduce_motion(udid, on):
    v = "true" if on else "false"
    simctl("spawn", udid, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", v, timeout=60)
    simctl("spawn", udid, "defaults", "write", "com.apple.Accessibility", "ReduceMotionPreferred", "-bool", v, timeout=60)
    # best-effort notify; harmless if the notification name is unknown
    simctl("spawn", udid, "notifyutil", "-p", "com.apple.accessibility.reduce.motion.changed", timeout=30)
    rc, out, _ = simctl("spawn", udid, "defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled", timeout=60)
    return out.strip()


def crash_reports_for(pid, since):
    hits = []
    for f in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/GameNight*.ips")):
        try:
            if os.path.getmtime(f) < since:
                continue
            with open(f, errors="replace") as fh:
                head = fh.read(4000)
            if '"pid":%s' % pid in head.replace(" ", "") or ('"pid" : %s' % pid) in head:
                hits.append(os.path.basename(f))
        except OSError:
            pass
    return hits


def run_entry(e, dev, ctx, baseline_sig):
    from PIL import Image
    udid, bundle = dev["udid"], ctx["bundle"]
    res = {"name": e["name"], "group": e.get("group", ""), "device": e["device"], "args": e["args"],
           "status": "PASS", "notes": [], "png": None}
    t0 = time.time()
    rm = bool(e.get("reduce_motion"))
    if rm:
        res["notes"].append("reduce-motion pref set (readback=%s)" % set_reduce_motion(udid, True))
    rc, out, err = simctl("launch", "--terminate-running-process", udid, bundle, *e["args"], timeout=ctx["launch_timeout"])
    pid = None
    if rc == 0:
        try:
            pid = int(out.strip().split(":")[-1])
        except ValueError:
            pass
    if rc != 0 or not pid:
        res["status"] = "FAIL"
        res["notes"].append("launch failed rc=%s: %s" % (rc, (err or out).strip()[:200]))
    else:
        time.sleep(max(1.0, e.get("wait", 8) * ctx["wait_scale"]))
        alive1 = pid_alive(pid)
        raw_dir = os.path.join(ctx["out"], "raw")
        os.makedirs(raw_dir, exist_ok=True)
        raw = os.path.join(raw_dir, e["name"] + ".png")
        src, serr = simctl("io", udid, "screenshot", "--type=png", raw, timeout=ctx["shot_timeout"])[0::2]
        if src != 0 or not os.path.exists(raw):
            res["status"] = "FAIL"
            res["notes"].append("screenshot failed: %s" % serr.strip()[:200])
        alive2 = pid_alive(pid)
        if not alive1 or not alive2:
            res["status"] = "FAIL"
            res["notes"].append("app NOT running at %s (pid %s) - crashed or exited" % (
                "screenshot time" if not alive1 else "post-screenshot check", pid))
            cr = crash_reports_for(pid, t0 - 5)
            if cr:
                res["notes"].append("crash report(s): " + ", ".join(cr))
        if os.path.exists(raw):
            try:
                im = Image.open(raw)
                w, h = im.size
                rot = e.get("rotate")
                if rot is None:
                    rot = (e["device"] == "ipad" and w < h)
                final = os.path.join(ctx["out"], e["name"] + ".png")
                if rot:
                    im.rotate(ctx["rotate_degrees"], expand=True).save(final)
                    res["notes"].append("rotated %s deg (raw %dx%d)" % (ctx["rotate_degrees"], w, h))
                else:
                    im.save(final)
                res["png"] = e["name"] + ".png"
                mean, std = img_stats(raw)
                d = mean_abs_diff(img_signature(raw), baseline_sig) if baseline_sig else None
                res["home_diff"] = None if d is None else round(d, 2)
                if d is not None and d < ctx["home_diff_min"] and res["status"] == "PASS":
                    res["status"] = "FAIL"
                    res["notes"].append("screen indistinguishable from home screen (diff %.2f)" % d)
                if std < 2.0 and res["status"] == "PASS":
                    res["status"] = "WARN"
                    res["notes"].append("near-uniform image (stddev %.1f) - blank render?" % std)
            except Exception as ex:  # noqa
                res["status"] = "FAIL"
                res["notes"].append("image processing: %s" % ex)
    if rm:
        set_reduce_motion(udid, False)
    res["secs"] = round(time.time() - t0, 1)
    log("  [%s] %-6s %s %s" % (e["device"], res["status"], e["name"], "; ".join(res["notes"])[:140]))
    return res


def run_device(devkey, entries, dev, ctx):
    results = []
    ok, msg = boot(dev, ctx["boot_timeout"])
    if not ok:
        return [{"name": e["name"], "group": e.get("group", ""), "device": devkey, "args": e["args"],
                 "status": "FAIL", "notes": ["sim failed to boot: " + msg], "png": None, "secs": 0} for e in entries]
    if ctx["install"]:
        simctl("uninstall", dev["udid"], ctx["bundle"], timeout=120)
        rc, out, err = simctl("install", dev["udid"], ctx["app"], timeout=ctx["install_timeout"])
        if rc != 0:
            return [{"name": e["name"], "group": e.get("group", ""), "device": devkey, "args": e["args"],
                     "status": "FAIL", "notes": ["install failed: " + err.strip()[:200]], "png": None, "secs": 0}
                    for e in entries]
        log("%s: installed" % dev["name"])
    set_reduce_motion(dev["udid"], False)
    # home-screen baseline
    simctl("terminate", dev["udid"], ctx["bundle"], timeout=60)
    time.sleep(3)
    base = os.path.join(ctx["out"], "raw", "_home-%s.png" % devkey)
    os.makedirs(os.path.dirname(base), exist_ok=True)
    simctl("io", dev["udid"], "screenshot", "--type=png", base, timeout=ctx["shot_timeout"])
    bsig = img_signature(base) if os.path.exists(base) else None
    for e in entries:
        results.append(run_entry(e, dev, ctx, bsig))
    simctl("terminate", dev["udid"], ctx["bundle"], timeout=60)
    return results


def write_reports(out, results, meta):
    n = len(results)
    cnt = {s: sum(1 for r in results if r["status"] == s) for s in ("PASS", "WARN", "FAIL")}
    lines = ["---", "title: Verify run %s" % meta["stamp"], "created: %s" % meta["date"],
             "modified: %s" % meta["date"], "version: 1.0", "author: tools/verify.sh", "tags:", "---", "",
             "# Verification run %s" % meta["stamp"], "",
             "- Result: **%d PASS, %d WARN, %d FAIL** of %d entries" % (cnt["PASS"], cnt["WARN"], cnt["FAIL"], n),
             "- Git HEAD: `%s` (working tree may include uncommitted edits)" % meta["head"],
             "- App build mtime: %s" % meta["app_mtime"],
             "- Host load average at start: %s" % meta["load"],
             "- Duration: %.0fs" % meta["secs"], ""]
    if meta.get("multipeer"):
        lines += ["## Two-sim Multipeer", "", meta["multipeer"], ""]
    lines += ["## Entries", "", "| Entry | Device | Status | Args | Notes |", "|---|---|---|---|---|"]
    for r in results:
        lines.append("| %s | %s | %s | `%s` | %s |" % (r["name"], r["device"], r["status"], " ".join(r["args"]),
                                                       "; ".join(r["notes"]).replace("|", "/")))
    lines += ["", "FAIL = app not running at screenshot time (crash/exit), launch/screenshot error, or screen identical "
              "to the home screen. WARN = near-blank render. PASS only proves the app is alive and drew something; "
              "look at the images (index.html).", ""]
    open(os.path.join(out, "REPORT.md"), "w").write("\n".join(lines))
    col = {"PASS": "#2e7d32", "WARN": "#b26a00", "FAIL": "#c62828"}
    h = ["<!doctype html><meta charset=utf-8><title>Verify %s</title>" % meta["stamp"],
         "<style>body{font:14px -apple-system,sans-serif;background:#111;color:#eee;margin:16px}"
         ".g{display:flex;flex-wrap:wrap;gap:14px}.c{background:#1c1c1e;border-radius:8px;padding:8px;width:340px}"
         ".c img{width:100%;border-radius:4px;display:block}.s{font-weight:700}.n{color:#aaa;font-size:11px;word-break:break-all}"
         "h2{margin:22px 0 8px}</style>",
         "<h1>Verification %s</h1><p>%d PASS / %d WARN / %d FAIL &mdash; HEAD %s</p>" % (
             meta["stamp"], cnt["PASS"], cnt["WARN"], cnt["FAIL"], html.escape(meta["head"]))]
    for g in dict.fromkeys(r["group"] for r in results):
        h.append("<h2>%s</h2><div class=g>" % html.escape(g))
        for r in [x for x in results if x["group"] == g]:
            img = '<a href="%s"><img src="%s"></a>' % (r["png"], r["png"]) if r["png"] else "<i>no image</i>"
            h.append('<div class=c><div><span class=s style="color:%s">%s</span> %s <small>(%s)</small></div>%s'
                     '<div class=n>%s<br>%s</div></div>' % (
                         col[r["status"]], r["status"], html.escape(r["name"]), r["device"], img,
                         html.escape(" ".join(r["args"])), html.escape("; ".join(r["notes"]))))
        h.append("</div>")
    open(os.path.join(out, "index.html"), "w").write("\n".join(h))
    json.dump({"meta": meta, "results": results}, open(os.path.join(out, "results.json"), "w"), indent=1)
    return cnt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma list of entry names or groups")
    ap.add_argument("--device", choices=["ipad", "iphone"])
    ap.add_argument("--no-install", action="store_true")
    ap.add_argument("--wait-scale", type=float, default=1.0, help="multiply every wait (use >1 on a loaded host)")
    ap.add_argument("--multipeer", action="store_true", help="also run multipeer.sh into the same run dir")
    ap.add_argument("--rotate-degrees", type=int, default=-90, help="PIL rotate angle for portrait-framed iPad shots")
    ap.add_argument("--boot-timeout", type=int, default=600, help="seconds to wait for each sim to finish booting")
    ap.add_argument("--app", help="path to GameNight.app (default: shared DerivedData)")
    ap.add_argument("--out-root", default=os.path.join(REPO, "_review", "verify"))
    a = ap.parse_args()

    m = json.load(open(os.path.join(HERE, "matrix.json")))
    scratch = os.environ.get("GN_SCRATCH", SCRATCH_DEFAULT)
    app = a.app or os.path.join(scratch, "dd-shared/Build/Products/Debug-iphonesimulator/GameNight.app")
    exe = os.path.join(app, "GameNight")
    if not os.path.isfile(exe):
        sys.exit("No complete built app at %s (executable missing - build in progress or failed?). "
                 "Run tools/build.sh first." % app)
    entries = m["entries"]
    if a.only:
        want = set(a.only.split(","))
        entries = [e for e in entries if e["name"] in want or e.get("group") in want]
    if a.device:
        entries = [e for e in entries if e["device"] == a.device]
    if not entries:
        sys.exit("no entries selected")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = os.path.join(a.out_root, stamp)
    os.makedirs(out, exist_ok=True)
    ctx = dict(bundle=m["bundle_id"], app=app, out=out, install=not a.no_install, wait_scale=a.wait_scale,
               rotate_degrees=a.rotate_degrees, home_diff_min=2.0, boot_timeout=a.boot_timeout, install_timeout=300,
               launch_timeout=180, shot_timeout=120)
    rc, head, _ = sh(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], timeout=30)
    meta = dict(stamp=stamp, date=datetime.date.today().isoformat(), head=head.strip(),
                app_mtime=time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(exe))),
                load=" ".join("%.0f" % x for x in os.getloadavg()))
    log("run dir: %s (%d entries)" % (out, len(entries)))
    t0 = time.time()
    by_dev = {}
    for e in entries:
        by_dev.setdefault(e["device"], []).append(e)
    results_by_name = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        futs = [ex.submit(run_device, k, v, m["devices"][k], ctx) for k, v in by_dev.items()]
        for f in futs:
            for r in f.result():
                results_by_name[r["name"]] = r
    results = [results_by_name[e["name"]] for e in entries]
    meta["secs"] = time.time() - t0
    if a.multipeer:
        log("running multipeer.sh")
        env = dict(os.environ, GN_VERIFY_OUT=out)
        p = subprocess.run([os.path.join(HERE, "multipeer.sh")], env=env, capture_output=True, text=True)
        meta["multipeer"] = "```\n" + (p.stdout[-3000:] or p.stderr[-1500:]) + "\n```\n(exit %d; details in `multipeer/`)" % p.returncode
        meta["multipeer_rc"] = p.returncode
    cnt = write_reports(out, results, meta)
    open(os.path.join(a.out_root, "latest.txt"), "w").write(stamp + "\n")
    log("DONE: %(PASS)d PASS, %(WARN)d WARN, %(FAIL)d FAIL -> %(o)s/REPORT.md" % dict(cnt, o=out))
    sys.exit(1 if cnt["FAIL"] or meta.get("multipeer_rc") else 0)


if __name__ == "__main__":
    main()
