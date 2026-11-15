#!/usr/bin/env python3
"""MacRemote M1: reproducible native ZGFX microbenchmark.
No network service, no live display, no input injection.
"""
import argparse, csv, json, random, statistics, subprocess
from pathlib import Path

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--binary",required=True)
    parser.add_argument("--freerdp-lib",required=True)
    parser.add_argument("--out",required=True)
    parser.add_argument("--trials",type=int,default=5)
    args=parser.parse_args()
    binary, freerdp=Path(args.binary),Path(args.freerdp_lib)
    assert binary.is_file() and freerdp.is_file(), (binary,freerdp)
    outdir=Path(args.out);outdir.mkdir(parents=True,exist_ok=True)
    rows=[]
    cases=[(op,case,impl) for op in ('decode','encode')
          for case in ('code','solid','mixed','noise') for impl in ('iron','free')]
    for trial in range(1,args.trials+1):
        tasks=cases[:]
        random.Random(0xB0A7+trial).shuffle(tasks)
        for operation,case,impl in tasks:
            repetitions=4000 if operation=="decode" else 200
            completed=subprocess.run([str(binary),impl,case,operation,str(repetitions),str(freerdp)],
                    capture_output=True,text=True,timeout=45,check=False)
            if completed.returncode:
                raise RuntimeError(f"case={case} impl={impl} operation={operation} failed: {completed.stderr[-500:]}")
            fields=completed.stdout.strip().split(',')
            if fields[0]!="RESULT" or len(fields)!=12:raise RuntimeError(f"Invalid result {fields}")
            row={
                "trial":trial,"implementation":fields[1],"workload":fields[2],
                "operation":fields[3],"iterations":int(fields[4]),
                "input_bytes":int(fields[5]),"output_bytes":int(fields[6]),
                "wall_seconds":float(fields[7]),"cpu_ms":float(fields[8]),
                "peak_rss_mib":float(fields[9]),"checksum":int(fields[10]),"method":fields[11]
            }
            row["throughput_mib_s"]=round(row["iterations"]*row["input_bytes"]/1048576/row["wall_seconds"],3)
            row["latency_us_per_op"]=round(row["wall_seconds"]*1000000/row["iterations"],3)
            row["cpu_utilization_pct"]=round(row["cpu_ms"]/row["wall_seconds"]/10,2)
            row["wire_ratio_pct"]=round(100*row["output_bytes"]/row["input_bytes"],3)
            rows.append(row)
            print(f"R{trial} {operation} {case} {impl} {row['throughput_mib_s']:.1f} MiB/s, wire {row['wire_ratio_pct']:.2f}%",flush=True)
    with (outdir/"raw.csv").open("w",newline="") as f:
        writer=csv.DictWriter(f,lineterminator=chr(10),fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
    summary=[]
    for op in ('decode','encode'):
        for case in ('code','solid','mixed','noise'):
            for impl in ('iron','free'):
                selection=[r for r in rows if (r['operation'],r['workload'],r['implementation'])==(op,case,impl)]
                median=lambda field:round(statistics.median(r[field] for r in selection),3)
                summary.append({"operation":op,"workload":case,"implementation":impl,
                "n":len(selection),"raw_bytes":selection[0]["input_bytes"],
                "throughput_mib_s":median("throughput_mib_s"),
                "latency_us_per_op":median("latency_us_per_op"),
                "cpu_utilization_pct":median("cpu_utilization_pct"),
                "peak_rss_mib":median("peak_rss_mib"),
                "wire_ratio_pct":median("wire_ratio_pct")})
    with (outdir/"summary.json").open("w") as f:
        json.dump({"method":{"trials":args.trials,"iterations_per_decode":4000,
              "iterations_per_encode":200,"warmup_decode":100,
              "release_build":True,"interleaved_seed":0xB0A7,
              "same_wire_packet_for_both_decoders":True,
              "dynamic_frames_for_encoding":True,
              "scope":"ZGFX microbenchmark only; no H264, HY2, real RDP session"},
              "results":summary},f,indent=2)
    print("RESULTS_WRITTEN",outdir,"rows",len(rows))
if __name__=="__main__":main()
