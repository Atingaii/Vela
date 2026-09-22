//! Translation of NotchLayout and NotchViewModel's stack sizing at Swift 117a38b8.
//! The webview supplies measured text/card extents; geometry never assumes five accounts.
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

const K: f64 = 44.0 / 117.0;
pub const FLARE: f64 = 103.0 * K;
pub const GAP: f64 = 83.5 * K;
pub const BODY_DEPTH: f64 = 186.0 * K;
pub const CARD_WIDTH: f64 = 600.0 * K;
pub const TAIL: f64 = (75.0 + 28.0) * K;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
pub struct Content {
    pub count: usize,
    pub cell_extent: f64,
    pub card_height: f64,
}
pub static CONTENT: Mutex<Option<Content>> = Mutex::new(None);

impl Content {
    pub fn valid(&self) -> bool {
        self.count <= 256
            && self.cell_extent.is_finite()
            && self.card_height.is_finite()
            && (44.0..=200.0).contains(&self.cell_extent)
            && (0.0..=20000.0).contains(&self.card_height)
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Layout {
    pub edge: &'static str,
    /// CSS coordinates, before the notch's size preference is applied by the native zoom.
    pub width: f64,
    pub height: f64,
    pub spacing: f64,
    pub shape_length: f64,
    pub depth: f64,
    pub scale: f64,
}

pub fn calculate(edge: &str, content: Content, screen_height: f64, scale: f64) -> Layout {
    let edge = match edge {
        "left" => "left",
        "top" => "top",
        "bottom" => "bottom",
        _ => "right",
    };
    let vertical = matches!(edge, "left" | "right");
    let scale = scale.clamp(0.25, 4.0);
    let count = content.count as f64;
    let gaps = content.count.saturating_sub(1) as f64;
    let cell = if vertical { content.cell_extent } else { 44.0 };
    let packed = (69.5 + 50.1) * K + count * cell + 2.0 * FLARE;
    // Swift reserves tooltip space in screen points, independent of notch size.
    let slack = (190.0 * K * scale).max(
        (if vertical {
            content.card_height
        } else {
            CARD_WIDTH
        }) / 2.0
            + 49.5 * K,
    );
    let spacing = if vertical && gaps > 0.0 && screen_height > 0.0 {
        GAP.min(((screen_height - 2.0 * slack) / scale - packed) / gaps)
            .max(0.0)
    } else {
        GAP
    };
    let shape_length = packed + gaps * spacing;
    let length = shape_length + 2.0 * slack / scale;
    let depth = if vertical {
        BODY_DEPTH
    } else {
        BODY_DEPTH - 44.0 + content.cell_extent
    };
    let panel_depth = depth
        + ((if vertical {
            CARD_WIDTH
        } else {
            content.card_height
        }) + TAIL)
            / scale;
    let (width, height) = if vertical {
        (panel_depth, length)
    } else {
        (length, panel_depth)
    };
    Layout {
        edge,
        width,
        height,
        spacing,
        shape_length,
        depth,
        scale,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn content(count: usize) -> Content {
        Content {
            count,
            cell_extent: 71.11623931623932,
            card_height: 240.0,
        }
    }
    #[test]
    fn six_accounts_spend_spacing_before_clipping_flare_or_settings_orb() {
        let l = calculate("right", content(6), 900.0, 1.0);
        assert!(l.height > 650.0);
        assert!(l.height <= 900.0 + 0.01);
        assert!(l.spacing < GAP && l.spacing > 0.0);
        assert!(l.height - l.shape_length >= 2.0 * (FLARE + 28.5));
    }
    #[test]
    fn flat_stack_uses_ring_width_and_symmetric_padding() {
        let l = calculate("top", content(6), 900.0, 1.0);
        let expected = (69.5 + 50.1 + 206.0 + 5.0 * 83.5) * K + 6.0 * 44.0;
        assert!((l.shape_length - expected).abs() < 1e-9);
        assert_eq!(l.spacing, GAP);
    }
    #[test]
    fn tooltip_room_does_not_scale_with_the_notch() {
        for s in [0.75, 1.0, 1.5] {
            let l = calculate("left", content(2), 1200.0, s);
            assert!(((l.width - BODY_DEPTH) * s - CARD_WIDTH - TAIL).abs() < 1e-9);
        }
    }
    #[test]
    fn crowded_stack_keeps_ring_size_instead_of_negative_spacing() {
        let l = calculate("right", content(12), 768.0, 1.0);
        assert_eq!(l.spacing, 0.0);
        assert!(l.height > 768.0); // same limit as upstream; do not conceal clipping by shrinking rings
        assert!(!Content {
            count: 1,
            cell_extent: f64::NAN,
            card_height: 100.0
        }
        .valid());
    }
}
