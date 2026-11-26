//! What Snowpuff's own parts share: the sprite they hand the apps, and what they need of a window.

use crate::geometry::{Rect, V2};

pub type WindowId = isize;

/// A sprite as Snowpuff's parts give it: 17 floats, which both apps draw with their own shaders.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct Sprite {
    pub position: V2,
    pub velocity: V2,
    pub size: f32,
    pub alpha: f32,
    pub soft: f32,
    /// How much of the tint shows instead of white.
    pub tint_amount: f32,
    pub tint: [f32; 3],
    pub lump: f32,
    /// The kind, below zero (see extras.rs), and two values of its own.
    pub leaf: [f32; 3],
    pub spin: [f32; 2],
}

/// What the extras need of a window: where it is and which windows are in front of it.
#[derive(Clone, Debug)]
pub struct RainWindow {
    pub id: WindowId,
    pub frame: Rect,
    /// Frames of the windows in front of this one.
    pub fronts: Vec<Rect>,
    /// The Dock or the taskbar: something sits on it but nothing hangs under it.
    pub ledge_only: bool,
}
