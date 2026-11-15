// Validate sequential codec interoperability using actual IronRDP Auto packets
// and FreeRDP's ZGFX C decoder, outside the timed benchmark.
use ironrdp_graphics::zgfx::{Compressor, Decompressor, compress_and_wrap_egfx, CompressionMode};
use libloading::{Library, Symbol};
use std::{ffi::c_void, env};
type Context=*mut c_void;
type ContextNew=unsafe extern "C" fn(i32)->Context;
type ContextFree=unsafe extern "C" fn(Context);
type Decompress=unsafe extern "C" fn(Context,*const u8,u32,*mut *mut u8,*mut u32,u32)->i32;
type Compress=unsafe extern "C" fn(Context,*const u8,u32,*mut *mut u8,*mut u32,*mut u32)->i32;

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

fn main(){
 let libpath=env::args().nth(1).expect("pass path to libfreerdp3.dylib");
 let lib=unsafe{Library::new(libpath).expect("dynamic load FreeRDP")};
 let create:Symbol<ContextNew>=unsafe{lib.get(b"zgfx_context_new").unwrap()};
 let destroy:Symbol<ContextFree>=unsafe{lib.get(b"zgfx_context_free").unwrap()};
 let decode:Symbol<Decompress>=unsafe{lib.get(b"zgfx_decompress").unwrap()};
 let encode:Symbol<Compress>=unsafe{lib.get(b"zgfx_compress").unwrap()};
 for name in ["code","solid","mixed","noise"]{
   let mut encoder=Compressor::new();
   let mut iron_decoder=Decompressor::new();
   let free_decoder=unsafe{create(0)};
   let free_encoder=unsafe{create(1)};
   let mut total=0usize;
   for i in 0..200usize{
     let frame=make_frame(name,i);
     let packet=compress_and_wrap_egfx(&frame,&mut encoder,CompressionMode::Auto).expect("IronRDP Auto encode");
     let mut out=Vec::new();
     iron_decoder.decompress(&packet,&mut out).expect("IronRDP stream decode");
     assert_eq!(out,frame,"IronRDP stream mismatch {name} frame={i}");
     let mut p:*mut u8=std::ptr::null_mut();let mut n=0u32;
     assert_eq!(unsafe{decode(free_decoder,packet.as_ptr(),packet.len() as u32,&mut p,&mut n,0)},1,"FreeRDP decoder failed {name} frame={i}");
     assert_eq!(n as usize,frame.len());
     assert_eq!(unsafe{std::slice::from_raw_parts(p,n as usize)},frame,"FreeRDP cross-stream mismatch {name} frame={i}");
     unsafe{libc::free(p.cast())};

     let mut fp:*mut u8=std::ptr::null_mut();let mut fnn=0u32;let mut flags=0u32;
     assert_eq!(unsafe{encode(free_encoder,frame.as_ptr(),frame.len() as u32,&mut fp,&mut fnn,&mut flags)},0);
     // FreeRDP stream -> fresh separate IronRDP stream-decode context for raw case.
     let mut iron_other=Decompressor::new();
     let mut from_free=Vec::new();
     iron_other.decompress(unsafe{std::slice::from_raw_parts(fp,fnn as usize)},&mut from_free).expect("FreeRDP-to-IronRDP");
     assert_eq!(from_free,frame);
     unsafe{libc::free(fp.cast())};
     total+=packet.len();
   }
   unsafe{destroy(free_decoder);destroy(free_encoder)};
   println!("PASS {} 200 sequential packets decoded by both, mean wire {:.2}%",name,100.0*total as f64/(200*16384) as f64);
 }
 println!("PASS 800 sequential IronRDP Auto packets cross-decoded using FreeRDP and IronRDP");
}
