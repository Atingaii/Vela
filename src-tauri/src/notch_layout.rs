//! Translation of NotchLayout and NotchViewModel's stack sizing at Swift 117a38b8.
//! The webview supplies measured text/card extents; geometry never assumes five accounts.
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

const K: f64 = 44.0 / 117.0;
pub const FLARE: f64 = 103.0 * K;
pub const GAP: f64 = 83.5 * K;
pub const BODY_DEPTH: f64 = 186.0 * K;
pub const CARD_WIDTH: f64 = 600.0 * K;
pub const CARD_CORNER: f64 = 49.5 * K;
pub const TAIL: f64 = (75.0 + 28.0) * K;
pub const SESSION_CEILING: usize = 12;
const DEFAULT_SESSION_CAP: usize = 4;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
pub struct Content {
    pub count: usize,
    pub cell_extent: f64,
    pub card_height: f64,
    /// Max card height for each session cap 0...12, measured with one more
    /// session than the cap so a hidden-count line always has room.
    #[serde(default)]
    pub budget_heights: Option<[f64; SESSION_CEILING + 1]>,
    #[serde(default)]
    pub has_plan: bool,
    #[serde(default)]
    pub has_token_usage: bool,
    #[serde(default)]
    pub has_reset_credits: bool,
}
pub static CONTENT: Mutex<Option<Content>> = Mutex::new(None);

impl Content {
    pub fn valid(&self) -> bool {
        self.count <= 256
            && self.cell_extent.is_finite()
            && self.card_height.is_finite()
            && (44.0..=200.0).contains(&self.cell_extent)
            && (0.0..=20000.0).contains(&self.card_height)
            && self.budget_heights.map_or(true, |heights| {
                heights
                    .iter()
                    .all(|h| h.is_finite() && (0.0..=20000.0).contains(h))
                    && heights.windows(2).all(|w| w[0] <= w[1])
            })
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
    pub session_cap: usize,
}

// NotchLayout.cardHeight(windowCount: 4, groupCount: 2,
// sessionCount: cap + 1, sessionCap: cap) at Swift 117a38b8. The SF Pro
// 9.4802pt card body has a 12pt rounded line box; the title is shorter than
// the 46-design-pixel glyph. This intentionally does not measure WebView CSS:
// sessionsFitting uses the fixed Swift worst-case card, not current content.
fn fitting_card_height(cap: usize, content: Content) -> f64 {
    let line = 12.0;
    let mut height = 2.0 * 32.0 * K + 46.0 * K;
    if content.has_plan {
        height += line;
    }
    let full_block = 2.0 * line + (16.8 + 10.5 + 17.8) * K;
    height += 21.0 * K + 4.0 * full_block + 3.0 * 20.0 * K;
    let group_extra = line + (12.0 + 2.0 * 16.0) * K;
    height += 2.0 * group_extra + (28.0 - 20.0 + 8.0) * K;
    if content.has_reset_credits {
        height += (20.0 + 2.5 + 20.0 + 2.0 * 12.0) * K + 3.0 * line;
    }
    if content.has_token_usage {
        height +=
            (20.0 + 2.5 + 20.0 + 14.0 + 5.0 * 40.0 + 4.0 * 8.0 + 14.0 + 2.5 + 12.0 + 15.0 + 115.0)
                * K
                + 2.0 * line;
    }
    let row = 2.0 * line + 10.0 * K;
    height += (20.0 + 2.5 + 20.0) * K
        + cap as f64 * row
        + cap.saturating_sub(1) as f64 * 20.0 * K
        + 20.0 * K
        + line;
    height
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
    // Swift spends the gaps against the cap-zero card, before solving how many
    // session rows fit. Measuring today's visible rows here would make the
    // window oscillate whenever activity changes.
    let actual_card = |cap: usize| {
        if content.count == 0 {
            fitting_card_height(cap, content)
        } else {
            content
                .budget_heights
                .map(|heights| heights[cap])
                .unwrap_or(content.card_height)
        }
    };
    let zero_card = actual_card(0);
    // Swift reserves tooltip space in screen points, independent of notch size.
    let slack = (190.0 * K * scale)
        .max((if vertical { zero_card } else { CARD_WIDTH }) / 2.0 + CARD_CORNER);
    let spacing = if vertical && gaps > 0.0 && screen_height > 0.0 {
        GAP.min(((screen_height - 2.0 * slack) / scale - packed) / gaps)
            .max(0.0)
    } else {
        GAP
    };
    let shape_length = packed + gaps * spacing;
    let depth = if vertical {
        BODY_DEPTH
    } else {
        BODY_DEPTH - 44.0 + content.cell_extent
    };
    // NotchViewModel.cardBudget and NotchLayout.sessionsFitting. The search
    // starts at one and stops at the first row that cannot fit.
    let session_cap = if content.budget_heights.is_some() {
        let card_budget = if vertical {
            screen_height / scale - shape_length - 2.0 * CARD_CORNER
        } else {
            screen_height / scale - depth - TAIL
        };
        (1..=SESSION_CEILING)
            .take_while(|&n| fitting_card_height(n, content) <= card_budget)
            .last()
            .unwrap_or(0)
    } else {
        DEFAULT_SESSION_CAP
    };
    let card_height = actual_card(session_cap);
    let final_slack = (190.0 * K * scale)
        .max((if vertical { card_height } else { CARD_WIDTH }) / 2.0 + CARD_CORNER);
    let length = shape_length + 2.0 * final_slack / scale;
    let panel_depth = depth + ((if vertical { CARD_WIDTH } else { card_height }) + TAIL) / scale;
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
        session_cap,
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
            budget_heights: None,
            has_plan: false,
            has_token_usage: false,
            has_reset_credits: false,
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
            card_height: 100.0,
            budget_heights: None,
            has_plan: false,
            has_token_usage: false,
            has_reset_credits: false,
        }
        .valid());
    }
    #[test]
    fn session_cap_uses_screen_budget_and_reserves_hidden_row() {
        let mut c = content(2);
        c.budget_heights = Some(std::array::from_fn(|n| 180.0 + n as f64 * 30.0));
        let small = calculate("right", c, 600.0, 1.0);
        let large = calculate("right", c, 1200.0, 1.0);
        assert_eq!(small.session_cap, 0); // actual one-window cards alone would fit two
        assert_eq!(large.session_cap, SESSION_CEILING);
        assert!((large.width - BODY_DEPTH - CARD_WIDTH - TAIL).abs() < 1e-9);
        assert!(large.height - large.shape_length >= 2.0 * (180.0 + 30.0 * 12.0) / 2.0);
    }
}
