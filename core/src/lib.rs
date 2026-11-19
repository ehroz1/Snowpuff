//! The snow itself, free of any platform: the simulation, its drifts and the geometry they use.
//! The Mac app has its own in Swift, and the site its own in JavaScript.

pub mod geometry;
pub mod icicles;
pub mod layer;
pub mod extras;
pub mod ffi;
pub mod rain;
pub mod sfx;
pub mod simulation;
pub mod sound;
pub mod version;

#[cfg(test)]
mod tests;
