//! The Mac app links one static library, so the C functions of both crates come from here: two Rust static
//! libraries in one app would each carry the standard library.

pub use snowpuff_core;
pub use snowpuff_net;
