use std::{env, ffi::c_void, mem, hint::black_box, time::Instant, path::PathBuf};
use ironrdp_graphics::zgfx::{Compressor, Decompressor, wrap_compressed, wrap_uncompressed, compress_and_wrap_egfx, CompressionMode};
use libloading::{Library, Symbol};

type Context = *mut c_void;
type ContextNew = unsafe extern "C" fn(i32) -> Context;
type ContextFree = unsafe extern "C" fn(Context);
type Decompress = unsafe extern "C" fn(Context, *const u8, u32, *mut *mut u8, *mut u32, u32) -> i32;
type Compress = unsafe extern "C" fn(Context, *const u8, u32, *mut *mut u8, *mut u32, *mut u32) -> i32;

fn make_data(name: &str) -> Vec<u8> {
    let size = 16384;
    let mut s = Vec::with_capacity(size);
    let line = b"pub fn update(view: &mut View) { view.scroll(offset); println!(\"Hello MacRemote!\"); }\n";
    let mut state = 0x9E3779B9u32;
    for i in 0..size {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        let b = match name {
            "code" => line[i % line.len()],
            "solid" => if (i/1024)%2==0 {0x20} else {0xFE},
            "mixed" => if i%1024<768 {line[i%line.len()]} else { (state & 255) as u8 },
            "noise" => (state & 255) as u8,
            _ => panic!("unknown workload"),
        };
        s.push(b);
    }
    s
}
// Each encode iteration represents another *changed* synthetic frame, rather
// than repeatedly re-compressing the same random bytes (which would falsely
// report massive compression of supposedly high-entropy content).
fn make_frame(name: &str, frame: usize) -> Vec<u8> {
    let mut data=make_data(name);
    let mut state=(frame as u32 + 1).wrapping_mul(0x9E3779B9).wrapping_add(0x1234567);
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        (state & 0xff) as u8
    };
    match name {
        "code" => {
            // Changed identifiers on each frame, stable lines elsewhere.
            for chunk in data.chunks_mut(80) {
                if !chunk.is_empty() {chunk[0]=b'A'+ (frame % 26) as u8;}
            }
        }
        "solid" => {
            // Solid blocks change gray tone across frames, with the same shape.
            for b in data.iter_mut() {*b=b.wrapping_add((frame % 101) as u8);}
        }
        "mixed" => {
            // 1/4 of the content changes per frame (scrolling/dynamic graphics).
            for (i,b) in data.iter_mut().enumerate() {
                if i%1024>=768 {*b=next();}
            }
        }
        "noise" => for b in data.iter_mut() {*b=next();},
        _=>panic!("unknown case")
    }
    data
}
fn usage() -> (f64, usize) {
    let mut u: libc::rusage = unsafe { mem::zeroed() };
    assert_eq!(unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) }, 0);
    let cpu = (u.ru_utime.tv_sec + u.ru_stime.tv_sec) as f64 * 1000.0
        + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) as f64 / 1000.0;
    (cpu, u.ru_maxrss as usize)
}
fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 6 {
        eprintln!("USAGE: zgfx-comparison <free|iron> <code|solid|mixed|noise> <decode|encode> <iterations> <freerdp-dylib>");
        std::process::exit(2)
    }
    let which=&args[1]; let scenario=&args[2]; let op=&args[3];
    let iterations: usize=args[4].parse().unwrap();
    let raw=make_data(scenario);
    let mut comp=Compressor::new();
    let zipped=comp.compress(&raw).expect("compress");
    let packet=if zipped.len() < raw.len() {wrap_compressed(&zipped)} else {wrap_uncompressed(&raw)};
    let is_compressed=packet[1] & 0x20 != 0;
    let lib=unsafe{Library::new(PathBuf::from(&args[5])).expect("dlopen")};
    let new: Symbol<ContextNew> = unsafe{ lib.get(b"zgfx_context_new").unwrap() };
    let close: Symbol<ContextFree> = unsafe{ lib.get(b"zgfx_context_free").unwrap() };
    let decompress: Symbol<Decompress> = unsafe{ lib.get(b"zgfx_decompress").unwrap() };
    let compress: Symbol<Compress> = unsafe{ lib.get(b"zgfx_compress").unwrap() };

    // One-time reference verification using BOTH decoders for every exact same packet.
    let mut iron=Decompressor::new();
    let mut vec=Vec::new();
    let n=iron.decompress(&packet,&mut vec).expect("Rust decompression");
    assert_eq!(n,raw.len());
    assert_eq!(vec,raw,"Iron output differs");
    let ctx=unsafe {new(0)};
    assert!(!ctx.is_null());
    let mut ptr:*mut u8=std::ptr::null_mut(); let mut len=0u32;
    let rc=unsafe{decompress(ctx,packet.as_ptr(),packet.len() as u32,&mut ptr,&mut len,0)};
    if rc!=1 {panic!("FreeRDP did not decode same IronRDP packet: rc={rc} case={scenario} compressed={is_compressed}")};
    assert_eq!(len as usize,raw.len());
    let free_out=unsafe{std::slice::from_raw_parts(ptr,len as usize)};
    assert_eq!(free_out,raw.as_slice(),"FreeRDP output differs");
    unsafe{libc::free(ptr.cast());close(ctx)}

    // Reverse-direction interoperability: FreeRDP wire output -> IronRDP.
    let cctx=unsafe{new(1)};
    let mut cptr:*mut u8=std::ptr::null_mut();
    let mut cn=0u32;
    let mut cflags=0u32;
    assert_eq!(unsafe{compress(cctx,raw.as_ptr(),raw.len() as u32,&mut cptr,&mut cn,&mut cflags)},0);
    let packet_free=unsafe{std::slice::from_raw_parts(cptr,cn as usize)};
    let mut rust_plain=Vec::new();
    let mut rust_decoder=Decompressor::new();
    assert_eq!(rust_decoder.decompress(packet_free,&mut rust_plain).unwrap(), raw.len());
    assert_eq!(rust_plain, raw,"IronRDP could not decode FreeRDP-produced ZGFX wire data");
    unsafe{libc::free(cptr.cast());close(cctx)}

    if op=="decode" {
        let ctx_free=unsafe{new(0)};
        let mut ctx_iron=Decompressor::new();
        let mut checksum=0u64;
        // Warmup includes identical bytes, steady-state decoder histories.
        for _ in 0..100 {
            if which=="iron" {
                let mut out=Vec::new();
                ctx_iron.decompress(&packet,&mut out).unwrap();
                checksum=checksum.wrapping_add(out[0] as u64);
            } else {
                let mut p:*mut u8=std::ptr::null_mut();let mut n=0u32;
                assert_eq!(unsafe{decompress(ctx_free,packet.as_ptr(),packet.len() as u32,&mut p,&mut n,0)},1);
                checksum=checksum.wrapping_add(unsafe{*p} as u64);
                unsafe{libc::free(p.cast())};
            }
        }
        let (cpu0, _)=usage();
        let started=Instant::now();
        for _ in 0..iterations {
            if which=="iron" {
                let mut out=Vec::new();
                let written=ctx_iron.decompress(&packet,&mut out).unwrap();
                assert_eq!(written,raw.len());
                checksum=checksum.wrapping_add(out[written-1] as u64);
                black_box(&out);
            } else {
                let mut p:*mut u8=std::ptr::null_mut();let mut n=0u32;
                assert_eq!(unsafe{decompress(ctx_free,packet.as_ptr(),packet.len() as u32,&mut p,&mut n,0)},1);
                assert_eq!(n as usize,raw.len());
                checksum=checksum.wrapping_add(unsafe{*p.add(n as usize-1)} as u64);
                unsafe{libc::free(p.cast())};
            }
        }
        let elapsed=started.elapsed().as_secs_f64();
        let (cpu1,rss)=usage();
        unsafe{close(ctx_free)};
        println!("RESULT,{which},{scenario},{op},{iterations},{},{},{:.6},{:.3},{:.3},{},{}",raw.len(),packet.len(),elapsed,(cpu1-cpu0),rss as f64/1048576.0,checksum,if is_compressed {"compressed"} else {"raw"});
    } else {
        let ctx=unsafe{new(1)};
        let mut c=Compressor::new();
        let frames: Vec<Vec<u8>>=(0..iterations).map(|i| make_frame(scenario, i)).collect();
        let mut checksum=0u64;let mut wire_total=0usize;
        // Exclude fixture generation; keep real compression history across frames.
        let (cpu0,_)=usage();
        let started=Instant::now();
        for frame in &frames {
            if which=="iron" {
                let packet=compress_and_wrap_egfx(frame, &mut c, CompressionMode::Auto).unwrap();
                wire_total+=packet.len();
                checksum=checksum.wrapping_add(packet.len() as u64);
                black_box(&packet);
            } else {
                let mut p:*mut u8=std::ptr::null_mut();let mut n=0u32;let mut flags=0u32;
                assert_eq!(unsafe{compress(ctx,frame.as_ptr(),frame.len() as u32,&mut p,&mut n,&mut flags)},0);
                wire_total+=n as usize;
                checksum=checksum.wrapping_add(n as u64);
                unsafe{libc::free(p.cast())};
            }
        }
        let elapsed=started.elapsed().as_secs_f64();let (cpu1,rss)=usage();
        unsafe{close(ctx)};
        println!("RESULT,{which},{scenario},{op},{iterations},{},{},{:.6},{:.3},{:.3},{},{}",raw.len(),wire_total/iterations,elapsed,(cpu1-cpu0),rss as f64/1048576.0,checksum,"iron-auto-vs-free-raw");
    }
}
