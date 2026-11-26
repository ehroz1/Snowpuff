//! Sound effects made on the fly, with no sound files: rain on the glass, hail ticking, snow crunching under the
//! cursor, an icicle's chime, a snowball's thud and fireworks. Both apps mix these over the ambience.

/// A one-off sound.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Cue {
    /// The cursor ploughing through a drift, 0 to 1.
    Crunch(f32),
    /// An icicle knocked off or shattering: its pitch, 0 low to 1 high.
    Chime(f32),
    /// A snowball landing.
    Splat,
    /// A firework bursting, and how far off: 0 near to 1 far.
    Boom(f32),
}

enum Voice {
    /// Granular noise: snow crunching.
    Crunch { left: f32, gain: f32, low: f32, grain: f32 },
    /// Three glassy partials ringing down.
    Chime { phase: [f32; 3], freq: [f32; 3], gain: f32, age: f32, pan: f32 },
    /// A soft low thud with a puff of noise.
    Thud { phase: f32, age: f32, low: f32, gain: f32 },
    /// A firework: a deep thump, then a scatter of crackles.
    Boom { phase: f32, age: f32, low: f32, gain: f32, crackle_in: f32, crackles: u32 },
    /// A single short tick of a drop or a hailstone on glass.
    Tick { phase: f32, freq: f32, age: f32, gain: f32, pan: f32 },
}

pub struct Sfx {
    /// 0 to 1.
    pub volume: f32,
    /// How hard it rains and hails, 0 for none: their beds of sound follow.
    pub rain: f32,
    pub hail: f32,
    sample_rate: f32,
    seed: u32,
    voices: Vec<Voice>,
    rain_level: f32,
    hail_level: f32,
    hiss: [f32; 2],
    hiss_low: [f32; 2],
}

impl Sfx {
    pub fn new(sample_rate: f32) -> Sfx {
        Sfx {
            volume: 0.5,
            rain: 0.0,
            hail: 0.0,
            sample_rate: sample_rate.max(8000.0),
            seed: 0x2545_F491,
            voices: Vec::with_capacity(64),
            rain_level: 0.0,
            hail_level: 0.0,
            hiss: [0.0; 2],
            hiss_low: [0.0; 2],
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(8000.0);
    }

    /// Whether anything can still be heard.
    pub fn audible(&self) -> bool {
        self.rain > 0.0 || self.hail > 0.0 || self.rain_level > 0.001 || self.hail_level > 0.001 || !self.voices.is_empty()
    }

    pub fn play(&mut self, cue: Cue) {
        if self.voices.len() >= 48 {
            return;
        }
        let pan = self.noise() * 0.5;
        let voice = match cue {
            Cue::Crunch(strength) => Voice::Crunch { left: 0.12 + 0.1 * strength, gain: 0.35 * strength.clamp(0.2, 1.0), low: 0.0, grain: 0.0 },
            Cue::Chime(pitch) => {
                let base = 1700.0 + 1400.0 * pitch.clamp(0.0, 1.0) + self.noise() * 60.0;
                Voice::Chime { phase: [0.0; 3], freq: [base, base * 2.76, base * 5.4], gain: 0.16, age: 0.0, pan }
            }
            Cue::Splat => Voice::Thud { phase: 0.0, age: 0.0, low: 0.0, gain: 0.5 },
            Cue::Boom(far) => {
                let crackles = 18 + (self.chance() * 20.0) as u32;
                Voice::Boom { phase: 0.0, age: 0.0, low: 0.0, gain: 0.55 * (1.0 - 0.6 * far.clamp(0.0, 1.0)), crackle_in: 0.35, crackles }
            }
        };
        self.voices.push(voice);
    }

    fn noise(&mut self) -> f32 {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 17;
        self.seed ^= self.seed << 5;
        self.seed as f32 / u32::MAX as f32 * 2.0 - 1.0
    }

    fn chance(&mut self) -> f32 {
        self.noise() * 0.5 + 0.5
    }

    /// Adds the effects into interleaved stereo frames: call after the ambience has filled them.
    pub fn mix(&mut self, out: &mut [f32]) {
        let dt = 1.0 / self.sample_rate;
        let master = self.volume * 0.6;
        let tau = std::f32::consts::TAU;
        let mut spawned: Vec<Voice> = Vec::new();
        for frame in out.chunks_exact_mut(2) {
            let (mut l, mut r) = (0.0f32, 0.0f32);
            self.rain_level += (self.rain.min(2.5) - self.rain_level) * dt * 0.8;
            self.hail_level += (self.hail.min(2.5) - self.hail_level) * dt * 1.5;

            // Rain: a soft hiss, brighter as it gets heavier, and drops ticking on the glass now and then.
            if self.rain_level > 0.001 {
                for side in 0..2 {
                    let white = self.noise();
                    self.hiss_low[side] += (white - self.hiss_low[side]) * 0.35;
                    let band = self.hiss_low[side] - self.hiss[side];
                    self.hiss[side] += (self.hiss_low[side] - self.hiss[side]) * 0.04;
                    let value = band * 0.09 * self.rain_level.sqrt();
                    if side == 0 { l += value } else { r += value }
                }
                if self.chance() < self.rain_level * 14.0 * dt && self.voices.len() + spawned.len() < 48 {
                    let freq = 1800.0 + self.chance() * 2600.0;
                    let pan = self.noise() * 0.8;
                    spawned.push(Voice::Tick { phase: 0.0, freq, age: 0.0, gain: 0.05 + self.chance() * 0.05, pan });
                }
            }
            // Hail: harder, brighter ticks, many of them.
            if self.hail_level > 0.001 && self.chance() < self.hail_level * 45.0 * dt && self.voices.len() + spawned.len() < 48 {
                let freq = 3200.0 + self.chance() * 3800.0;
                let pan = self.noise() * 0.9;
                spawned.push(Voice::Tick { phase: 0.0, freq, age: 0.0, gain: 0.08 + self.chance() * 0.08, pan });
            }

            let mut voices = std::mem::take(&mut self.voices);
            voices.retain_mut(|voice| match voice {
                Voice::Crunch { left, gain, low, grain } => {
                    *left -= dt;
                    // Grains: short bursts of noise switching on and off at random, as snow packs under a step.
                    if *grain <= 0.0 && self.chance() < 900.0 * dt {
                        *grain = 0.002 + self.chance() * 0.006;
                    }
                    *grain -= dt;
                    let white = if *grain > 0.0 { self.noise() } else { 0.0 };
                    *low += (white - *low) * 0.25;
                    let envelope = (*left / 0.2).clamp(0.0, 1.0);
                    let value = *low * *gain * envelope;
                    l += value;
                    r += value * 0.9;
                    *left > 0.0
                }
                Voice::Chime { phase, freq, gain, age, pan } => {
                    *age += dt;
                    let mut value = 0.0;
                    for k in 0..3 {
                        phase[k] = (phase[k] + freq[k] * dt) % 1.0;
                        value += (phase[k] * tau).sin() * [1.0, 0.45, 0.22][k] * (-*age * [2.2, 4.5, 8.0][k]).exp();
                    }
                    let value = value * *gain * (*age / 0.002).min(1.0);
                    l += value * (1.0 - *pan);
                    r += value * (1.0 + *pan);
                    *age < 2.5
                }
                Voice::Thud { phase, age, low, gain } => {
                    *age += dt;
                    *phase = (*phase + (90.0 - 40.0 * (*age * 8.0).min(1.0)) * dt) % 1.0;
                    let white = self.noise();
                    *low += (white - *low) * 0.08;
                    let envelope = (-*age * 18.0).exp();
                    let value = ((*phase * tau).sin() * 0.7 + *low * 1.6) * envelope * *gain;
                    l += value;
                    r += value;
                    *age < 0.4
                }
                Voice::Boom { phase, age, low, gain, crackle_in, crackles } => {
                    *age += dt;
                    *phase = (*phase + (55.0 - 20.0 * (*age * 3.0).min(1.0)) * dt) % 1.0;
                    let white = self.noise();
                    *low += (white - *low) * 0.03;
                    let envelope = (-*age * 4.0).exp();
                    let value = ((*phase * tau).sin() * 0.8 + *low * 2.5) * envelope * *gain;
                    l += value;
                    r += value;
                    *crackle_in -= dt;
                    if *crackle_in <= 0.0 && *crackles > 0 {
                        *crackles -= 1;
                        *crackle_in = 0.01 + self.chance() * 0.06;
                        let freq = 2500.0 + self.chance() * 4000.0;
                        let pan = self.noise() * 0.9;
                        spawned.push(Voice::Tick { phase: 0.0, freq, age: 0.0, gain: *gain * 0.25, pan });
                    }
                    *age < 2.0 || *crackles > 0
                }
                Voice::Tick { phase, freq, age, gain, pan } => {
                    *age += dt;
                    *phase = (*phase + *freq * dt) % 1.0;
                    let value = (*phase * tau).sin() * (-*age * 160.0).exp() * *gain;
                    l += value * (1.0 - *pan);
                    r += value * (1.0 + *pan);
                    *age < 0.05
                }
            });
            voices.append(&mut spawned);
            self.voices = voices;

            frame[0] += (l * master).clamp(-1.0, 1.0);
            frame[1] += (r * master).clamp(-1.0, 1.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effects_ring_out_and_stay_in_range() {
        let mut sfx = Sfx::new(48000.0);
        sfx.volume = 1.0;
        for cue in [Cue::Crunch(1.0), Cue::Chime(0.5), Cue::Splat, Cue::Boom(0.0)] {
            sfx.play(cue);
        }
        sfx.rain = 2.2;
        sfx.hail = 1.0;
        let mut buffer = vec![0.0f32; 48000 * 2];
        sfx.mix(&mut buffer);
        let loudest = buffer.iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(loudest > 0.01 && loudest <= 1.0, "loudest {loudest}");
        sfx.rain = 0.0;
        sfx.hail = 0.0;
        for _ in 0..15 {
            buffer.iter_mut().for_each(|v| *v = 0.0);
            sfx.mix(&mut buffer);
        }
        assert!(!sfx.audible(), "still sounding after the rain stopped");
    }
}
