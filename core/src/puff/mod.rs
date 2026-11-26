//! Snowpuff's own parts over the Snowhush snow: the extras (the cursor's swirl, hail, fog, stars and meteors, the
//! garland, the cat, the bullfinch, a flurry, frost to draw in), icicles under snowy windows, and the sounds.
//! Platform-free: the Windows app uses them as a crate, the Mac app through `ffi`.

pub mod extras;
pub mod ffi;
pub mod icicles;
pub mod sfx;
pub mod sound;
pub mod types;
