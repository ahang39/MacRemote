#!/usr/bin/env python3
"""MacRemote M1 loopback-only RDP end-to-end benchmark.

Requires existing isolated FreeRDP 3.33.1 + IronRDP builds in the M1 cache.
NLA enforced. Test-only ephemeral credentials. No keyboard or mouse injection.
Never listens on a non-loopback interface. No screenshots recorded.
"""
import csv
import json
import os
import random
import re
import secrets
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path

os.umask(0o077)
CACHE=Path.home()/"Library/Caches/MacRemote/m1"
ROOT=CACHE/"e2e"
ROOT.mkdir(mode=0o700,parents=True,exist_ok=True)
HOME=ROOT/"freerdp-home"
HOME.mkdir(mode=0o700,exist_ok=True)
CLIENT=CACHE/"freerdp-e2e-build/client/Sample/sfreerdp"
IRON=CACHE/"ironrdp-target/release/examples/server"
FREE=CACHE/"freerdp-e2e-build/server/shadow/cli/freerdp-shadow-cli"
HASH=CACHE/"freerdp-build/winpr/tools/hash-cli/winpr-hash"
CERT=ROOT/"loopback.crt"
KEY=ROOT/"loopback.key"
OUT=Path.home()/"dev/repos/MacRemote/benchmarks/m1/e2e/results"
OUT.mkdir(parents=True,exist_ok=True)
for f in [CLIENT,IRON,FREE,HASH,CERT,KEY]:
    if not f.is_file():
        raise RuntimeError(f"Missing isolated prerequisite: {f}")

def port_available():
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]

def live(pid):
    try:os.kill(pid,0);return True
    except ProcessLookupError:return False

def reap(proc,timeout=8,force=False):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            got,status,ru=os.wait4(proc.pid,os.WNOHANG)
            if got==proc.pid:
                return {"status":os.waitstatus_to_exitcode(status),
                    "cpu_s":round(ru.ru_utime+ru.ru_stime,4),
                    "peak_rss_mib":round(ru.ru_maxrss/1024**2,3)}
        except ChildProcessError:
            return {"status":None,"cpu_s":None,"peak_rss_mib":None}
        time.sleep(.05)
    if force and live(proc.pid):
        os.killpg(proc.pid,signal.SIGTERM)
        return reap(proc,3,False)
    if live(proc.pid):
        os.killpg(proc.pid,signal.SIGKILL)
    return reap(proc,3,False)

def tcp_relay(actual_port, limit_mbps=0):
    """Count application bytes in both directions while preserving encrypted TLS."""
    lsock=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    lsock.bind(('127.0.0.1',0));lsock.listen(1)
    port=lsock.getsockname()[1]
    counts={"client_to_server":0,"server_to_client":0}
    done=threading.Event()
    def pump(src,dst,key):
        sent=0
        began=time.monotonic()
        try:
            while True:
                payload=src.recv(8192)
                if not payload:break
                if key=="server_to_client" and limit_mbps>0:
                    sent+=len(payload)
                    goal=sent/(limit_mbps*1000000/8)
                    delay=goal-(time.monotonic()-began)
                    if delay>0:time.sleep(delay)
                counts[key]+=len(payload)
                dst.sendall(payload)
        except (OSError,TimeoutError):
            pass
        finally:
            try:dst.shutdown(socket.SHUT_WR)
            except OSError:pass
    def worker():
        lsock.settimeout(15)
        try:
            down,_=lsock.accept()
            up=socket.create_connection(('127.0.0.1',actual_port),timeout=4)
            down.settimeout(9);up.settimeout(9)
            workers=[
                threading.Thread(target=pump,args=(down,up,"client_to_server"),daemon=True),
                threading.Thread(target=pump,args=(up,down,"server_to_client"),daemon=True)
            ]
            for w in workers:w.start()
            for w in workers:w.join(timeout=15)
            up.close();down.close()
        except OSError as ex:
            counts["proxy_error"]=type(ex).__name__
        finally:
            lsock.close();done.set()
    threading.Thread(target=worker,daemon=True).start()
    return port,counts,done

def test_once(which,trial,limit_mbps=0):
    actual=port_available()
    password=secrets.token_urlsafe(24)
    sam=ROOT/f"sam_{which}_{trial}.tmp"
    serverlog=ROOT/f"server_{which}_{trial}.log"
    clientlog=ROOT/f"client_{which}_{trial}.log"
    if which=="iron":
        command=[str(IRON),"--bind-addr",f"127.0.0.1:{actual}",
            "--sec","hybrid","--cert",str(CERT),"--key",str(KEY),
            "--user","bench","--pass",password]
    else:
        h=subprocess.run([str(HASH),"-u","bench","-p",password,"-f","sam","-v","1"],
            capture_output=True,text=True,timeout=8,check=True)
        sam.write_text(h.stdout.strip()+"\n")
        sam.chmod(0o600)
        command=[str(FREE),"/bind-address:127.0.0.1",f"/port:{actual}",
            f"/sam-file:{sam}","/sec:nla","-may-interact","-gfx","-rfx","/log-level:WARN"]

    env=os.environ.copy()
    env["WLOG_LEVEL"]="WARN"
    if which=="free":
        env["HOME"]=str(HOME)
        env["XDG_CONFIG_HOME"]=str(HOME)
    server_handle=serverlog.open("w")
    server=subprocess.Popen(command,stdout=server_handle,stderr=subprocess.STDOUT,
        env=env,cwd=ROOT,start_new_session=True)
    client=None
    try:
        ready=False
        for _ in range(80):
            if not live(server.pid):break
            try:
                with socket.create_connection(("127.0.0.1",actual),timeout=.1):
                    ready=True;break
            except OSError:time.sleep(.08)
        if not ready:
            raise RuntimeError(f"{which} failed loopback startup, see isolated log")

        proxyport,counts,proxy_done=tcp_relay(actual,limit_mbps)
        client_args=[str(CLIENT),f"/v:127.0.0.1:{proxyport}","/u:bench",
            f"/p:{password}","/cert:ignore","/sec:nla","-gfx",
            "/size:1920x1080","/bpp:32"]
        env_client=os.environ.copy()
        env_client["HOME"]=str(HOME)
        env_client["XDG_CONFIG_HOME"]=str(HOME)
        env_client["WLOG_LEVEL"]="ERROR"
        with clientlog.open("w") as cliout:
            started=time.monotonic()
            client=subprocess.Popen(client_args,stdout=cliout,stderr=subprocess.STDOUT,
                env=env_client,cwd=ROOT,start_new_session=True)
            client_usage=reap(client,timeout=12,force=True)
            elapsed=time.monotonic()-started
        proxy_done.wait(7)
        content=clientlog.read_text(errors="replace")
        meta={k:int(v) for k,v in re.findall(r"M1BENCH,([A-Z_]+),([0-9]+)",content)}
        record={"trial":trial,"server":which,"client_exit":client_usage["status"],
           "wall_s":round(elapsed,3),
           "client_cpu_s":client_usage["cpu_s"],
           "client_peak_rss_mib":client_usage["peak_rss_mib"],
           "handshake_ms":meta.get("CONNECTED_MS"),
           "first_paint_ms":meta.get("FIRST_FRAME_MS"),
           "paint_updates":meta.get("DONE_FRAMES"),
           "active_duration_ms":max(0,meta.get("DONE_MS",0)-meta.get("CONNECTED_MS",0)),
           "client_width":meta.get("CLIENT_WIDTH"),
           "client_height":meta.get("CLIENT_HEIGHT"),
           "tx_client_bytes":counts["client_to_server"],
           "tx_server_bytes":counts["server_to_client"],
           "proxy_error":counts.get("proxy_error","")}
        if not (record["client_exit"]==0 and record["handshake_ms"] is not None
                and record["first_paint_ms"] is not None and record["paint_updates"]>=1):
            # Keep only error line, never the test password or session clipboard/screen.
            clean=[l for l in content.splitlines()
                if "ERROR" in l or "Error:" in l]
            record["error_tail"]=" | ".join(clean[-4:])[:400].replace(password,"[redacted]")
        return record
    finally:
        if client and live(client.pid):
            try:os.killpg(client.pid,signal.SIGTERM)
            except ProcessLookupError:pass
        if live(server.pid):
            try:os.killpg(server.pid,signal.SIGTERM)
            except ProcessLookupError:pass
        # Exact child usage for server, after shutdown.
        server_usage=reap(server,timeout=4,force=True)
        server_handle.close()
        sam.unlink(missing_ok=True)
        # The caller obtains server resource usage via this local per-trial record.
        resource_data[which,trial]=server_usage

if __name__=="__main__":
    import sys,statistics
    trials=int(sys.argv[1]) if len(sys.argv)>1 else 5
    limit_mbps=float(sys.argv[2]) if len(sys.argv)>2 else 0
    if limit_mbps>0:
        OUT=Path.home()/f"dev/repos/MacRemote/benchmarks/m1/e2e/results-{limit_mbps:g}mbps"
        OUT.mkdir(parents=True,exist_ok=True)
    if (OUT/"raw.json").exists():
        raise SystemExit(f"Result already exists, refusing overwrite: {OUT}")
    resource_data={}
    cases=[(server,tr) for tr in range(1,trials+1) for server in ("iron","free")]
    random.Random(0xF3EED).shuffle(cases)
    records=[]
    for server,trial in cases:
        row=test_once(server,trial,limit_mbps)
        row.update({"server_"+k:v for k,v in resource_data[server,trial].items()})
        records.append(row)
        print("TRIAL",server,trial,"status",row["client_exit"],
          "connect",row["handshake_ms"],"first",row["first_paint_ms"],
          "frames",row["paint_updates"],"s2c_bytes",row["tx_server_bytes"],
          "server_cpu_s",row["server_cpu_s"],flush=True)
        if row["client_exit"]!=0 or row["paint_updates"] is None:
            print("FAILURE",row.get("error_tail","unknown"),flush=True)
    with (OUT/"raw.json").open("w") as f:json.dump(records,f,indent=2)
    keys=sorted({key for row in records for key in row.keys()})
    with (OUT/"raw.csv").open("w",newline="") as f:
        wr=csv.DictWriter(f,lineterminator=chr(10),fieldnames=keys);wr.writeheader();wr.writerows(records)
    summary={}
    metrics=("handshake_ms","first_paint_ms","paint_updates","tx_client_bytes",
             "tx_server_bytes","client_cpu_s","server_cpu_s","client_peak_rss_mib",
             "server_peak_rss_mib","active_duration_ms")
    for server in ("iron","free"):
        matched=[row for row in records if row["server"]==server and
                 row["client_exit"]==0 and row["handshake_ms"] is not None]
        with_frames=[row for row in matched if row["first_paint_ms"] is not None]
        summary[server]={"n_success":len(matched),"n_first_frame":len(with_frames),"n_total":trials,
          "screen_source":"synthetic moving rectangles" if server=="iron" else "macOS physical screen capture",
          "median":{k:round(statistics.median(vals),3)
             for k in metrics
             if (vals:=[r[k] for r in matched if r.get(k) is not None])}}
    (OUT/"summary.json").write_text(json.dumps(summary,indent=2))
    print("NETWORK_LIMIT_MBPS",limit_mbps,"SUMMARY",json.dumps(summary),flush=True)
