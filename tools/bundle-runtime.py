#!/usr/bin/env python3
"""Relocate all non-system Mach-O dylibs into MacRemote.app/Contents/Frameworks."""
from pathlib import Path
import argparse, hashlib, re, shutil, subprocess, sys

SYSTEM=("/System/Library/","/usr/lib/","/Library/Apple/System/","/Library/Frameworks/")

def run(*args):
    return subprocess.check_output([str(a) for a in args],text=True).strip()

def dependencies(p):
    return [x.strip().split(" (compatibility version",1)[0]
            for x in run("/usr/bin/otool","-L",p).splitlines()[1:]
            if " (compatibility version" in x]

def rpaths(p):
    lines=run("/usr/bin/otool","-l",p).splitlines()
    result=[]
    for i,line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for candidate in lines[i+1:i+6]:
                m=re.match(r"\s*path (.*?) \(offset",candidate)
                if m:
                    result.append(m.group(1))
                    break
    return result

def sha(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for data in iter(lambda:f.read(1048576),b""):
            h.update(data)
    return h.digest()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("app",type=Path)
    parser.add_argument("--freerdp-build",type=Path,required=True)
    args=parser.parse_args()
    app=args.app.resolve()
    server=app/"Contents/MacOS/macremote-server"
    frameworks=app/"Contents/Frameworks"
    build=args.freerdp_build.resolve()
    if not server.is_file():raise RuntimeError("No native RDP server binary")
    if frameworks.exists():raise RuntimeError("Frameworks already exists; refusing overwrite")
    frameworks.mkdir(parents=True)
    rootdirs=[build/x for x in
        ("server/shadow","server/common","winpr/tools","winpr/libwinpr","libfreerdp")]
    brew_root=Path(run("brew","--prefix")).resolve()
    rootdirs.append(brew_root/"lib")
    rootdirs.extend(p for p in (brew_root/"opt").glob("*/lib") if p.is_dir())
    found={}
    instructions={}
    pending=[(server,True)]
    checked=set()
    def resolve(name,origin):
        if name.startswith("@loader_path/"):
            candidate=origin.parent/name[len("@loader_path/"):]
            if candidate.exists():return candidate.resolve()
        if name.startswith("@executable_path/"):
            candidate=server.parent/name[len("@executable_path/"):]
            if candidate.exists():return candidate.resolve()
        if name.startswith("/"):
            candidate=Path(name)
            if candidate.exists():return candidate.resolve()
        if name.startswith("@rpath/"):
            for folder in [origin.parent,*rootdirs]:
                candidate=folder/Path(name).name
                if candidate.exists():return candidate.resolve()
        raise RuntimeError(f"Missing dylib {name}, requested by {origin}")
    while pending:
        origin,isexe=pending.pop(0)
        if origin in checked:continue
        checked.add(origin)
        fixes=[]
        for dependency in dependencies(origin):
            if dependency.startswith(SYSTEM):continue
            resolved=resolve(dependency,origin)
            if resolved==origin.resolve():continue
            if resolved==server.resolve():raise RuntimeError("Executable dependency cycle")
            if not str(resolved).startswith((str(build)+"/",str(brew_root)+"/")):
                raise RuntimeError(f"Unexpected dylib outside known roots: {resolved}")
            name=Path(dependency).name
            if name in found and found[name]!=resolved:
                if sha(found[name])!=sha(resolved):
                    raise RuntimeError(f"Different dylibs with same basename {name}")
            else:
                found[name]=resolved
                pending.append((resolved,False))
            target=("@executable_path/../Frameworks/" if isexe else "@loader_path/")+name
            fixes.append((dependency,target))
        instructions[origin]=fixes
    for name,origin in sorted(found.items()):
        shutil.copy2(origin,frameworks/name)
    # A canonical source may be reached under different original absolute paths.
    for origin,fixes in instructions.items():
        if origin==server:target=server
        else:
            matches=[name for name,p in found.items() if p==origin]
            if not matches:raise RuntimeError(f"Missing copy for {origin}")
            target=frameworks/matches[0]
        for old,new in fixes:
            if old!=new:run("/usr/bin/install_name_tool","-change",old,new,target)
        for rp in rpaths(target):
            run("/usr/bin/install_name_tool","-delete_rpath",rp,target)
        if origin!=server:
            run("/usr/bin/install_name_tool","-id","@loader_path/"+target.name,target)
    # OpenSSL provider loaded via dlopen() is invisible to otool recursion.
    # FreeRDP WinPR explicitly loads the legacy provider for NTLM support.
    provider=Path(run("brew","--prefix","openssl@4"))/"lib/ossl-modules/legacy.dylib"
    if not provider.is_file():
        raise RuntimeError(f"Missing OpenSSL provider: {provider}")
    plugdir=frameworks/"ossl-modules"
    plugdir.mkdir()
    plugin=plugdir/"legacy.dylib"
    shutil.copy2(provider,plugin)
    for dep in dependencies(plugin):
        if dep.startswith(SYSTEM):continue
        if Path(dep).name!="libcrypto.4.dylib":
            raise RuntimeError(f"Unexpected provider dependency: {dep}")
        run("/usr/bin/install_name_tool","-change",dep,
            "@loader_path/../libcrypto.4.dylib",plugin)
    for rp in rpaths(plugin):
        run("/usr/bin/install_name_tool","-delete_rpath",rp,plugin)
    for dep in dependencies(plugin):
        if dep.startswith(SYSTEM):continue
        if dep!="@loader_path/../libcrypto.4.dylib":
            raise RuntimeError(f"Provider still depends on external library: {dep}")
    if rpaths(plugin):raise RuntimeError("Provider retains external RPATH")
    for path in [server,*sorted(frameworks.glob("*.dylib"))]:
        for dependency in dependencies(path):
            if dependency.startswith(SYSTEM):continue
            if path!=server and dependency=="@loader_path/"+path.name:continue
            prefix="@executable_path/../Frameworks/" if path==server else "@loader_path/"
            if not dependency.startswith(prefix):
                raise RuntimeError(f"External dependency remains: {path} {dependency}")
            if not (frameworks/Path(dependency).name).is_file():
                raise RuntimeError(f"Referenced library missing: {dependency}")
        if rpaths(path):raise RuntimeError(f"Absolute RPATH left in {path}")
    print("BUNDLED_DYLIB_COUNT="+str(len(found)+1))
    print("BUNDLED_DYLIB_BYTES="+str(sum(x.stat().st_size for x in frameworks.rglob("*.dylib"))))
    print("BUNDLED_RUNTIME_SELF_CONTAINED=YES")
if __name__=="__main__":
    try:main()
    except (RuntimeError,subprocess.CalledProcessError) as e:
        print("MacRemote bundling failed:",e,file=sys.stderr)
        raise SystemExit(2)
