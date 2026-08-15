//! CPU compositor used when the `gpu-preview` feature is off.
//! With `gpu-preview`, `wgpu_preview` can replace this path.

use crate::error::{MediaError, Result};
use crate::export::RgbaFrame;
use crate::plan::{CompositionPlan, Effect};

#[derive(Clone, Debug, PartialEq)]
pub struct LayerFrame {
    pub rgba: RgbaFrame,
    pub opacity: f32,
    pub center_x: f32,
    pub center_y: f32,
    pub scale_x: f32,
    pub scale_y: f32,
    pub rotation_degrees: f32,
    pub flip_horizontal: bool,
    pub flip_vertical: bool,
    pub crop_left: f32,
    pub crop_top: f32,
    pub crop_right: f32,
    pub crop_bottom: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ComposeRequest {
    pub width: u32,
    pub height: u32,
    pub background: [u8; 4],
    pub layers: Vec<LayerFrame>,
}

pub fn compose_frame(request: &ComposeRequest) -> Result<RgbaFrame> {
    if request.width == 0 || request.height == 0 {
        return Err(MediaError::InvalidRequest(
            "compose size must be nonzero".into(),
        ));
    }
    let mut out = vec![0_u8; (request.width as usize) * (request.height as usize) * 4];
    for pixel in out.chunks_exact_mut(4) {
        pixel.copy_from_slice(&request.background);
    }

    for layer in &request.layers {
        if layer.rgba.width == 0 || layer.rgba.height == 0 {
            continue;
        }
        blit_layer(&mut out, request.width, request.height, layer)?;
    }

    Ok(RgbaFrame {
        width: request.width,
        height: request.height,
        bytes: out,
    })
}

pub fn effects_to_layer_defaults(effects: &[Effect]) -> (f32, f32, f32, f32, f32, f32) {
    let mut opacity = 1.0_f32;
    let mut center_x = 0.5;
    let mut center_y = 0.5;
    let mut scale_x = 1.0;
    let mut scale_y = 1.0;
    let mut rotation = 0.0;
    for effect in effects {
        match effect {
            Effect::Opacity { value } => opacity = *value,
            Effect::Transform {
                x,
                y,
                scale_x: sx,
                scale_y: sy,
                rotation_degrees,
            } => {
                center_x = *x;
                center_y = *y;
                scale_x = *sx;
                scale_y = *sy;
                rotation = *rotation_degrees;
            }
            _ => {}
        }
    }
    (opacity, center_x, center_y, scale_x, scale_y, rotation)
}

pub fn empty_plan_frame(plan: &CompositionPlan) -> Result<RgbaFrame> {
    compose_frame(&ComposeRequest {
        width: plan.width.max(1),
        height: plan.height.max(1),
        background: [0, 0, 0, 255],
        layers: Vec::new(),
    })
}

fn blit_layer(out: &mut [u8], out_w: u32, out_h: u32, layer: &LayerFrame) -> Result<()> {
    let src = &layer.rgba;
    let opacity = layer.opacity.clamp(0.0, 1.0);
    let scale_x = if layer.scale_x.is_finite() && layer.scale_x > 0.0 {
        layer.scale_x
    } else {
        1.0
    };
    let scale_y = if layer.scale_y.is_finite() && layer.scale_y > 0.0 {
        layer.scale_y
    } else {
        1.0
    };
    let dest_w = (out_w as f32 * scale_x).max(1.0);
    let dest_h = (out_h as f32 * scale_y).max(1.0);
    let center_x = layer.center_x * out_w as f32;
    let center_y = layer.center_y * out_h as f32;
    let radians = -layer.rotation_degrees.to_radians();
    let (sin, cos) = radians.sin_cos();
    let crop_left = layer.crop_left.clamp(0.0, 1.0);
    let crop_top = layer.crop_top.clamp(0.0, 1.0);
    let crop_right = layer.crop_right.clamp(0.0, 1.0);
    let crop_bottom = layer.crop_bottom.clamp(0.0, 1.0);
    let visible_width = 1.0 - crop_left - crop_right;
    let visible_height = 1.0 - crop_top - crop_bottom;
    if visible_width <= 0.0 || visible_height <= 0.0 {
        return Ok(());
    }

    for y in 0..out_h {
        for x in 0..out_w {
            let relative_x = x as f32 + 0.5 - center_x;
            let relative_y = y as f32 + 0.5 - center_y;
            let local_x = cos * relative_x - sin * relative_y;
            let local_y = sin * relative_x + cos * relative_y;
            let normalized_x = local_x / dest_w + 0.5;
            let normalized_y = local_y / dest_h + 0.5;
            if !(0.0..1.0).contains(&normalized_x) || !(0.0..1.0).contains(&normalized_y) {
                continue;
            }
            let normalized_x = if layer.flip_horizontal {
                1.0 - normalized_x
            } else {
                normalized_x
            };
            let normalized_y = if layer.flip_vertical {
                1.0 - normalized_y
            } else {
                normalized_y
            };
            let source_x = crop_left + normalized_x * visible_width;
            let source_y = crop_top + normalized_y * visible_height;
            let sx = (source_x * src.width as f32)
                .floor()
                .clamp(0.0, src.width.saturating_sub(1) as f32) as u32;
            let sy = (source_y * src.height as f32)
                .floor()
                .clamp(0.0, src.height.saturating_sub(1) as f32) as u32;
            let src_i = ((sy * src.width + sx) * 4) as usize;
            let dst_i = ((y * out_w + x) * 4) as usize;
            if src_i + 3 >= src.bytes.len() || dst_i + 3 >= out.len() {
                continue;
            }
            let sa = (f32::from(src.bytes[src_i + 3]) / 255.0) * opacity;
            if sa <= 0.0 {
                continue;
            }
            for channel in 0..3 {
                let src_c = f32::from(src.bytes[src_i + channel]);
                let dst_c = f32::from(out[dst_i + channel]);
                let blended = src_c * sa + dst_c * (1.0 - sa);
                out[dst_i + channel] = blended.round().clamp(0.0, 255.0) as u8;
            }
            let da = f32::from(out[dst_i + 3]) / 255.0;
            out[dst_i + 3] = ((sa + da * (1.0 - sa)) * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composites_opaque_layer_over_background() {
        let layer = LayerFrame {
            rgba: RgbaFrame {
                width: 2,
                height: 2,
                bytes: vec![
                    255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255,
                ],
            },
            opacity: 1.0,
            center_x: 0.5,
            center_y: 0.5,
            scale_x: 1.0,
            scale_y: 1.0,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            crop_left: 0.0,
            crop_top: 0.0,
            crop_right: 0.0,
            crop_bottom: 0.0,
        };
        let frame = compose_frame(&ComposeRequest {
            width: 4,
            height: 4,
            background: [0, 0, 0, 255],
            layers: vec![layer],
        })
        .unwrap();
        assert_eq!(frame.width, 4);
        assert_eq!(frame.bytes.len(), 4 * 4 * 4);
        let center = 20_usize;
        assert_eq!(&frame.bytes[center..center + 3], &[255, 0, 0]);
    }
}
