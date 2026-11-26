//! Snowpuff's own parts over the Snowhush snow on one display: the extras (the cursor's swirl, hail, fog, stars and
//! meteors, the garland, the cat, the bullfinch, a flurry, frost to draw in), icicles under snowy windows and the
//! focused window's warm glow. The logic is the shared core's (core/src/puff); this steps it and draws it.

use std::collections::HashSet;
use std::mem::size_of;
use std::sync::OnceLock;

use windows::Win32::Graphics::Direct3D::{D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP, D3D_SRV_DIMENSION_BUFFER};
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_R32_FLOAT;
use windows::core::{Error, Result, s};

use snowpuff_core::geometry::{Rect, V2};
use snowpuff_core::puff::extras::{Extras, Input, Settings};
use snowpuff_core::puff::icicles::{Eaves, IcicleSprite, Icicles};
use snowpuff_core::puff::sfx::Cue;
use snowpuff_core::puff::types::{RainWindow, Sprite};
use snowpuff_core::simulation::{SnowSimulation, WindowId, WindowSurface};

use crate::render::{Gpu, compile_from, dynamic_buffer, pixel_shader, vertex_shader};

/// The extras' shapes are shared with the Mac; FN marks their functions in either language.
const SOURCE: &str = concat!("#define FN\n", include_str!("../../shaders/extras.shader"), "\n", include_str!("puff.hlsl"));

/// What a frame is drawn with.
pub struct Frame {
    pub view: [f32; 2],
    pub scale: f32,
    pub time: f32,
    pub light: [f32; 4],
    pub lantern: [f32; 4],
    pub hearth: ([f32; 4], [f32; 4]),
    pub opacity: f32,
    pub shake: [f32; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Uniforms {
    view_size: [f32; 2],
    scale: f32,
    time: f32,
    light: [f32; 4],
    lantern: [f32; 4],
    hearth: [f32; 4],
    hearth_light: [f32; 4],
    opacity: f32,
    occluder_count: i32,
    shake: [f32; 2],
    occluders: [[f32; 4]; 16],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct FrostUniforms {
    view: [f32; 2],
    time: f32,
    cell: f32,
    reach: f32,
    mist: f32,
    columns: i32,
    rows: i32,
    light: [f32; 4],
}

struct Code {
    puff_vertex: Vec<u8>,
    puff_fragment: Vec<u8>,
    icicle_vertex: Vec<u8>,
    icicle_fragment: Vec<u8>,
    frost_vertex: Vec<u8>,
    frost_fragment: Vec<u8>,
}

fn code() -> Option<&'static Code> {
    static CODE: OnceLock<Option<Code>> = OnceLock::new();
    CODE.get_or_init(|| {
        let compile = |entry, target| compile_from(SOURCE, s!("puff.hlsl"), entry, target);
        let made = (|| -> Result<Code> {
            Ok(Code {
                puff_vertex: compile(s!("puffVertex"), s!("vs_4_0"))?,
                puff_fragment: compile(s!("puffFragment"), s!("ps_4_0"))?,
                icicle_vertex: compile(s!("icicleVertex"), s!("vs_4_0"))?,
                icicle_fragment: compile(s!("icicleFragment"), s!("ps_4_0"))?,
                frost_vertex: compile(s!("frostVertex"), s!("vs_4_0"))?,
                frost_fragment: compile(s!("frostFragment"), s!("ps_4_0"))?,
            })
        })();
        match made {
            Ok(code) => Some(code),
            Err(error) => {
                crate::log!("Snowpuff's shaders failed: {}", error.message());
                None
            }
        }
    })
    .as_ref()
}

/// A dynamic buffer of floats the shaders read through a view, and how many floats it holds.
struct Floats {
    buffer: ID3D11Buffer,
    view: ID3D11ShaderResourceView,
    capacity: usize,
}

impl Floats {
    fn new(device: &ID3D11Device, capacity: usize) -> Result<Floats> {
        let buffer = dynamic_buffer(device, capacity * size_of::<f32>(), D3D11_BIND_SHADER_RESOURCE)?;
        let desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
            Format: DXGI_FORMAT_R32_FLOAT,
            ViewDimension: D3D_SRV_DIMENSION_BUFFER,
            Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 {
                Buffer: D3D11_BUFFER_SRV {
                    Anonymous1: D3D11_BUFFER_SRV_0 { FirstElement: 0 },
                    Anonymous2: D3D11_BUFFER_SRV_1 { NumElements: capacity as u32 },
                },
            },
        };
        let mut view = None;
        unsafe { device.CreateShaderResourceView(&buffer, Some(&desc), Some(&mut view))? };
        Ok(Floats { buffer, view: view.ok_or_else(Error::empty)?, capacity })
    }

    /// Makes room for `count` floats, keeping the buffer when it is big enough.
    fn reserve(slot: &mut Option<Floats>, device: &ID3D11Device, count: usize) -> Result<()> {
        if slot.as_ref().is_none_or(|floats| floats.capacity < count) {
            *slot = Some(Floats::new(device, count.max(1024).next_power_of_two())?);
        }
        Ok(())
    }

    fn write(&self, context: &ID3D11DeviceContext, values: &[f32]) -> Result<()> {
        unsafe {
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            context.Map(&self.buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
            std::ptr::copy_nonoverlapping(values.as_ptr(), mapped.pData.cast::<f32>(), values.len().min(self.capacity));
            context.Unmap(&self.buffer, 0);
        }
        Ok(())
    }
}

struct Shaders {
    puff_vertex: ID3D11VertexShader,
    puff_fragment: ID3D11PixelShader,
    icicle_vertex: ID3D11VertexShader,
    icicle_fragment: ID3D11PixelShader,
    frost_vertex: ID3D11VertexShader,
    frost_fragment: ID3D11PixelShader,
    uniforms: ID3D11Buffer,
    frost_uniforms: ID3D11Buffer,
}

impl Shaders {
    fn new(device: &ID3D11Device) -> Option<Shaders> {
        let code = code()?;
        let made = (|| -> Result<Shaders> {
            Ok(Shaders {
                puff_vertex: vertex_shader(device, &code.puff_vertex)?,
                puff_fragment: pixel_shader(device, &code.puff_fragment)?,
                icicle_vertex: vertex_shader(device, &code.icicle_vertex)?,
                icicle_fragment: pixel_shader(device, &code.icicle_fragment)?,
                frost_vertex: vertex_shader(device, &code.frost_vertex)?,
                frost_fragment: pixel_shader(device, &code.frost_fragment)?,
                uniforms: dynamic_buffer(device, size_of::<Uniforms>(), D3D11_BIND_CONSTANT_BUFFER)?,
                frost_uniforms: dynamic_buffer(device, size_of::<FrostUniforms>(), D3D11_BIND_CONSTANT_BUFFER)?,
            })
        })();
        made.inspect_err(|error| crate::log!("Snowpuff's shaders: {}", error.message())).ok()
    }
}

fn write_constants<T: Copy>(context: &ID3D11DeviceContext, buffer: &ID3D11Buffer, value: &T) -> Result<()> {
    unsafe {
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        context.Map(buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
        std::ptr::copy_nonoverlapping(value as *const T, mapped.pData.cast::<T>(), 1);
        context.Unmap(buffer, 0);
    }
    Ok(())
}

pub struct Puff {
    pub extras: Extras,
    pub icicles: Icicles,
    /// Sounds asked for since they were last taken.
    pub cues: Vec<Cue>,
    /// The focused window glows warm onto the snow around it.
    pub warm_glow: bool,
    /// Given Snowpuff's settings since it was made.
    pub configured: bool,
    focused: Option<Rect>,
    hearth: [f32; 4],
    hearth_strength: f32,
    was_pressed: bool,
    shaders: Option<Option<Shaders>>,
    sprites: Option<Floats>,
    icicle_buffer: Option<Floats>,
    frost: Option<Floats>,
    sprite_scratch: Vec<Sprite>,
    icicle_scratch: Vec<IcicleSprite>,
}

impl Puff {
    pub fn new(width: f32, height: f32) -> Puff {
        Puff {
            extras: Extras::new(width, height),
            icicles: Icicles::new(),
            cues: Vec::new(),
            warm_glow: true,
            configured: false,
            focused: None,
            hearth: [0.0; 4],
            hearth_strength: 0.0,
            was_pressed: false,
            shaders: None,
            sprites: None,
            icicle_buffer: None,
            frost: None,
            sprite_scratch: Vec::new(),
            icicle_scratch: Vec::new(),
        }
    }

    pub fn set_settings(&mut self, settings: Settings, icicles: bool, calm: bool) {
        self.extras.settings = settings;
        if icicles != self.icicles.enabled() {
            if !icicles && calm {
                self.icicles.melt();
            }
            self.icicles.set_enabled(icicles);
        }
    }

    /// The windows on this display, front first, as the snow was just given them.
    pub fn set_windows(&mut self, surfaces: &[WindowSurface], covers: &[[f32; 4]], interval: f32, keep: &HashSet<WindowId>, taskbar: WindowId) {
        let windows: Vec<RainWindow> = surfaces
            .iter()
            .map(|surface| RainWindow { id: surface.id, frame: surface.frame, fronts: surface.blockers.clone(), ledge_only: surface.id == taskbar })
            .collect();
        self.extras.set_windows(&windows);
        self.extras.set_covers(covers);
        let eaves: Vec<Eaves> = surfaces
            .iter()
            .filter(|surface| surface.id != taskbar)
            .map(|surface| Eaves { id: surface.id, frame: surface.frame, fronts: surface.blockers.clone() })
            .collect();
        self.icicles.update(&eaves, interval, keep, false);
        self.focused = surfaces.iter().find(|surface| surface.id != taskbar).map(|surface| surface.frame);
    }

    /// Moves everything on; returns whether anything changed, and whether it moves enough to want a smooth rate.
    pub fn step(&mut self, dt: f32, cursor: Option<V2>, button: bool, magic: bool, daylight: f32, simulation: &mut SnowSimulation) -> (bool, bool) {
        self.extras.sample_ground(|x| simulation.ground_level(x));
        self.extras.step(Input { dt, cursor, button, magic, daylight, top_inset: 0.0 });
        self.cues.extend(self.extras.take_cues());
        let mut changed = self.extras.is_active();
        // A click on an icicle knocks it down with a ring.
        if let Some(cursor) = cursor
            && button
            && !self.was_pressed
            && let Some(pitch) = self.icicles.knock(cursor)
        {
            self.cues.push(Cue::Chime(pitch));
            changed = true;
        }
        self.was_pressed = button;
        if self.icicles.enabled() || !self.icicles.is_empty() {
            changed |= self.icicles.step(dt, simulation);
        }
        changed |= self.ease_hearth(dt);
        let smooth = self.extras.needs_smooth() || self.icicles.is_falling() || (self.hearth_strength > 0.0 && self.hearth_strength < 0.99);
        (changed, smooth)
    }

    pub fn is_empty(&self) -> bool {
        !self.extras.is_active() && self.icicles.is_empty() && self.hearth_strength == 0.0
    }

    pub fn clear(&mut self, calm: bool) {
        self.extras.clear();
        if calm {
            self.icicles.melt();
        } else {
            self.icicles.drop_all();
        }
    }

    /// Eases the glow toward the focused window, fading it in and out; returns whether it visibly changed.
    fn ease_hearth(&mut self, dt: f32) -> bool {
        let previous = (self.hearth, self.hearth_strength);
        match self.focused.filter(|_| self.warm_glow) {
            Some(frame) => {
                let goal = [frame.min_x(), frame.min_y(), frame.max_x(), frame.max_y()];
                let k = (dt * 9.0).min(1.0);
                for (now, goal) in self.hearth.iter_mut().zip(goal) {
                    *now = if self.hearth_strength < 0.01 { goal } else { *now + (goal - *now) * k };
                }
                self.hearth_strength += (1.0 - self.hearth_strength) * (dt * 2.5).min(1.0);
            }
            None => {
                self.hearth_strength -= self.hearth_strength * (dt * 2.5).min(1.0);
                if self.hearth_strength < 0.005 {
                    self.hearth_strength = 0.0;
                }
            }
        }
        let moved = self.hearth.iter().zip(previous.0).any(|(a, b)| (a - b).abs() > 0.4);
        moved || (self.hearth_strength - previous.1).abs() > 0.004
    }

    /// The glow for the shaders: the window's frame, and how far and how brightly it spills.
    pub fn glow(&self) -> ([f32; 4], [f32; 4]) {
        (self.hearth, [70.0, 0.42 * self.hearth_strength, 280.0, 0.0])
    }

    /// Draws the icicles, the extras and the frost into the render target already set.
    pub fn draw(&mut self, gpu: &Gpu, frame: Frame) -> Result<()> {
        let device = &gpu.device;
        let context = &gpu.context;
        if self.shaders.is_none() {
            self.shaders = Some(Shaders::new(device));
        }
        let Some(Some(shaders)) = &self.shaders else { return Ok(()) };
        let mut uniforms = Uniforms {
            view_size: frame.view,
            scale: frame.scale,
            time: frame.time,
            light: frame.light,
            lantern: frame.lantern,
            hearth: frame.hearth.0,
            hearth_light: frame.hearth.1,
            opacity: frame.opacity,
            occluder_count: 0,
            shake: frame.shake,
            occluders: [[0.0; 4]; 16],
        };
        unsafe {
            context.IASetInputLayout(None);
            context.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            context.OMSetBlendState(&gpu.blend, None, u32::MAX);
            context.RSSetState(&gpu.raster);
            let constants = [Some(shaders.uniforms.clone()), Some(shaders.frost_uniforms.clone())];
            context.VSSetConstantBuffers(0, Some(&constants));
            context.PSSetConstantBuffers(0, Some(&constants));
        }

        // Icicles, in runs that share the windows in front of them.
        let count = self.icicles.count();
        if count > 0 {
            self.icicle_scratch.resize(count, IcicleSprite::default());
            let groups = self.icicles.write(&mut self.icicle_scratch);
            let written = groups.iter().map(|group| group.offset + group.count).max().unwrap_or(0);
            if written > 0 {
                Floats::reserve(&mut self.icicle_buffer, device, written * 8)?;
                let floats = self.icicle_buffer.as_ref().ok_or_else(Error::empty)?;
                let values: Vec<f32> = self.icicle_scratch[..written]
                    .iter()
                    .flat_map(|c| [c.root.x, c.root.y, c.length, c.width, c.angle, c.seed, c.alpha, 0.0])
                    .collect();
                floats.write(context, &values)?;
                unsafe {
                    context.VSSetShader(&shaders.icicle_vertex, None);
                    context.PSSetShader(&shaders.icicle_fragment, None);
                    context.VSSetShaderResources(1, Some(&[Some(floats.view.clone())]));
                    for group in &groups {
                        let n = group.occluders.len().min(16);
                        uniforms.occluder_count = n as i32;
                        uniforms.occluders[..n].copy_from_slice(&group.occluders[..n]);
                        write_constants(context, &shaders.uniforms, &uniforms)?;
                        context.DrawInstanced(4, group.count as u32, 0, group.offset as u32);
                    }
                }
                uniforms.occluder_count = 0;
            }
        }

        // The extras.
        let wanted = self.extras.sprite_count();
        if wanted > 0 {
            self.sprite_scratch.resize(wanted, Sprite::default());
            let n = self.extras.write(&mut self.sprite_scratch).min(wanted);
            if n > 0 {
                Floats::reserve(&mut self.sprites, device, n * 17)?;
                let floats = self.sprites.as_ref().ok_or_else(Error::empty)?;
                let values: Vec<f32> = self.sprite_scratch[..n]
                    .iter()
                    .flat_map(|s| {
                        [
                            s.position.x,
                            s.position.y,
                            s.velocity.x,
                            s.velocity.y,
                            s.size,
                            s.alpha,
                            s.soft,
                            s.tint_amount,
                            s.tint[0],
                            s.tint[1],
                            s.tint[2],
                            s.lump,
                            s.leaf[0],
                            s.leaf[1],
                            s.leaf[2],
                            s.spin[0],
                            s.spin[1],
                        ]
                    })
                    .collect();
                floats.write(context, &values)?;
                write_constants(context, &shaders.uniforms, &uniforms)?;
                unsafe {
                    context.VSSetShader(&shaders.puff_vertex, None);
                    context.PSSetShader(&shaders.puff_fragment, None);
                    context.VSSetShaderResources(0, Some(&[Some(floats.view.clone())]));
                    context.DrawInstanced(4, n as u32, 0, 0);
                }
            }
        }

        // Frost on the glass, in front of everything.
        let reach = self.extras.frost_reach();
        let (values, columns, rows, cell) = self.extras.frost_grid();
        if reach > 0.0 && columns > 0 && rows > 0 {
            Floats::reserve(&mut self.frost, device, columns * rows)?;
            let floats = self.frost.as_ref().ok_or_else(Error::empty)?;
            floats.write(context, values)?;
            let frost = FrostUniforms {
                view: frame.view,
                time: frame.time,
                cell,
                reach,
                mist: if self.extras.frost_is_mist() { 1.0 } else { 0.0 },
                columns: columns as i32,
                rows: rows as i32,
                light: frame.light,
            };
            write_constants(context, &shaders.frost_uniforms, &frost)?;
            unsafe {
                context.VSSetShader(&shaders.frost_vertex, None);
                context.PSSetShader(&shaders.frost_fragment, None);
                context.PSSetShaderResources(2, Some(&[Some(floats.view.clone())]));
                context.DrawInstanced(4, 4, 0, 0);
            }
        }
        unsafe {
            // Unbound, the snow's own buffers in these slots are free again next frame.
            context.VSSetShaderResources(0, Some(&[None, None]));
            context.PSSetShaderResources(2, Some(&[None]));
        }
        Ok(())
    }
}
