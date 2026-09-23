//! Translation of NotchLayout and NotchViewModel's stack sizing at Swift 117a38b8.
//! Card heights follow Swift's semantic NotchLayout.cardHeight; DOM extents are fallback only.
use serde::{Deserialize, Serialize};

const K: f64 = 44.0 / 117.0;
pub const FLARE: f64 = 103.0 * K;
pub const GAP: f64 = 83.5 * K;
pub const BODY_DEPTH: f64 = 186.0 * K;
pub const CARD_WIDTH: f64 = 600.0 * K;
pub const CARD_CORNER: f64 = 49.5 * K;
pub const TAIL: f64 = (75.0 + 28.0) * K;
pub const SESSION_CEILING: usize = 12;
const DEFAULT_SESSION_CAP: usize = 4;

#[derive(Clone, Debug, Deserialize, PartialEq)]
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
    #[serde(default)]
    pub snapshots: Option<Vec<CardDescription>>,
    #[serde(skip)]
    pub body_line_height: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct CardDescription {
    window_count: usize,
    group_count: usize,
    money_window_count: usize,
    usage_detail_group_count: usize,
    status_message: Option<String>,
    block_message: Option<String>,
    has_token_usage: bool,
    has_plan: bool,
    has_reset_credits: bool,
    local_model_name: Option<String>,
    shows_local_performance: bool,
    local_ledger_rows: usize,
    compact_row_count: usize,
    shows_deepseek_pricing: bool,
    #[serde(skip)]
    status_height: Option<f64>,
    #[serde(skip)]
    block_height: Option<f64>,
    #[serde(skip)]
    model_name_height: Option<f64>,
}

impl CardDescription {
    fn valid(&self) -> bool {
        self.window_count <= 64 && self.group_count <= self.window_count
            && self.money_window_count <= self.window_count
            && self.compact_row_count + self.money_window_count <= self.window_count
            && self.usage_detail_group_count <= 32 && self.local_ledger_rows <= 64
            && [&self.status_message, &self.block_message, &self.local_model_name]
                .into_iter().all(|s| s.as_ref().is_none_or(|v| v.len() <= 4096))
    }
}

/// Swift uses NSStringDrawing with the SF Pro body font, then rounds the bounding box to whole
/// line boxes. This is called only from a scheduled AppKit main-thread callback.
#[cfg(target_os = "macos")]
pub fn measure_card_text_on_main_thread(content: &mut Content) {
    use objc2::runtime::AnyObject;
    use objc2_app_kit::{NSFont, NSFontAttributeName, NSStringDrawingDeprecated, NSStringDrawingOptions};
    use objc2_foundation::{NSDictionary, NSAttributedStringKey, NSSize, NSString};
    let font = NSFont::systemFontOfSize(18.0 * K / 0.714);
    let line = (font.ascender() - font.descender() + font.leading()).ceil();
    content.body_line_height = Some(line);
    let font_object: &AnyObject = &font;
    let attributes: objc2::rc::Retained<NSDictionary<NSAttributedStringKey, AnyObject>> =
        NSDictionary::from_slices(&[unsafe { NSFontAttributeName }], &[font_object]);
    let text_height = |message: &str| {
        if message.is_empty() { return line; }
        let string = NSString::from_str(message);
        let rect = unsafe { string.boundingRectWithSize_options_attributes(
            NSSize { width: CARD_WIDTH - 2.0 * 32.0 * K, height: f64::MAX },
            NSStringDrawingOptions::UsesLineFragmentOrigin | NSStringDrawingOptions::UsesFontLeading,
            Some(&attributes),
        ) };
        (rect.size.height / line).ceil().max(1.0) * line
    };
    if let Some(cards) = &mut content.snapshots {
        for card in cards {
            card.status_height = card.status_message.as_deref().map(text_height);
            card.block_height = card.block_message.as_deref().map(text_height);
            card.model_name_height = card.local_model_name.as_deref().map(|name| (2.0 * line).min(text_height(name)));
        }
    }
}
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
            && self.snapshots.as_ref().is_none_or(|snapshots| {
                snapshots.len() == self.count && snapshots.iter().all(CardDescription::valid)
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
fn fitting_card_height(cap: usize, content: &Content) -> f64 {
    let line = content.body_line_height.unwrap_or(12.0);
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

fn usage_detail_height(groups: usize, pricing: bool, line: f64) -> f64 {
    if groups == 0 { return 0.0; }
    let summary = 2.5 * K + 20.0 * K + line + 20.0 * K + 2.0 * line + 4.0 * K;
    let chart = line + 12.0 * K + 96.0 * K;
    let divider = 20.0 * K + 2.5 * K;
    let pricing_height = if pricing { 20.0 * K + 2.0 * line + 4.0 * K + divider } else { 0.0 };
    20.0 * K + summary + pricing_height + divider + 20.0 * K + 2.0 * chart + 18.0 * K
}

/// Exact structural sum from Swift NotchLayout.cardHeight. Text heights are filled by AppKit
/// before this runs; the one-line fallback is used by platform-neutral unit tests only.
fn described_card_height(card: &CardDescription, cap: usize, line: f64) -> f64 {
    let mut height = 2.0 * 32.0 * K + (46.0 * K).max(line);
    if card.has_plan { height += line; }
    if card.block_message.is_some() {
        height += 21.0 * K + card.block_height.unwrap_or(line);
    }
    if card.local_model_name.is_some() {
        let rows = (if card.shows_local_performance { 7 } else { 4 }) + card.local_ledger_rows;
        height += 21.0 * K + card.model_name_height.unwrap_or(line)
            + 20.0 * K + rows as f64 * line
            + rows.saturating_sub(1) as f64 * 10.0 * K;
    } else if card.window_count > 0 {
        let full_count = card.window_count - card.compact_row_count - card.money_window_count;
        let full_block = 2.0 * line + (16.8 + 10.5 + 17.8) * K;
        let money_block = 3.0 * line + (16.8 + 12.0 + 14.0 + 4.0) * K;
        height += 21.0 * K + full_count as f64 * full_block
            + card.money_window_count as f64 * money_block
            + card.compact_row_count as f64 * line
            + card.window_count.saturating_sub(1) as f64 * 20.0 * K;
        if card.group_count > 0 {
            height += card.group_count as f64 * (line + (12.0 + 2.0 * 16.0) * K);
            height += card.group_count.saturating_sub(1) as f64 * 8.0 * K;
            height += 8.0 * K;
        }
    } else {
        height += 21.0 * K + card.status_height.unwrap_or(line);
    }
    if card.has_reset_credits {
        height += (20.0 + 2.5 + 20.0 + 2.0 * 12.0) * K + 3.0 * line;
    }
    height += usage_detail_height(card.usage_detail_group_count, card.shows_deepseek_pricing, line);
    if card.has_token_usage {
        height += (20.0 + 2.5 + 20.0 + 14.0 + 5.0 * 40.0 + 4.0 * 8.0 + 14.0
            + 2.5 + 12.0 + 15.0 + 115.0) * K + 2.0 * line;
    }
    if card.local_model_name.is_none() {
        // Swift passes sessionCount = cap + 1 to every remote provider, reserving the hidden row.
        let shown = cap;
        height += (20.0 + 2.5 + 20.0) * K
            + shown as f64 * (2.0 * line + 10.0 * K)
            + shown.saturating_sub(1) as f64 * 20.0 * K
            + 20.0 * K + line;
    }
    height
}

pub fn calculate(
    edge: &str,
    content: Content,
    screen_height: f64,
    scale: f64,
    hardware: Option<crate::native_notch::HardwareNotch>,
) -> Layout {
    let edge = match edge {
        "left" => "left",
        "top" => "top",
        "bottom" => "bottom",
        _ => "right",
    };
    let vertical = matches!(edge, "left" | "right");
    let hardware = hardware.filter(|_| edge == "top");
    let flare = if hardware.is_some() { 28.0 * K } else { FLARE };
    let scale = scale.clamp(0.25, 4.0);
    let count = content.count as f64;
    let gaps = content.count.saturating_sub(1) as f64;
    let cell = if vertical { content.cell_extent } else { 44.0 };
    let packed = (69.5 + 50.1) * K + count * cell + 2.0 * flare;
    // Swift spends the gaps against the cap-zero card, before solving how many
    // session rows fit. Measuring today's visible rows here would make the
    // window oscillate whenever activity changes.
    let actual_card = |cap: usize| match content.snapshots.as_ref() {
        Some(cards) if !cards.is_empty() => cards.iter()
            .map(|card| described_card_height(card, cap, content.body_line_height.unwrap_or(12.0)))
            .fold(0.0, f64::max),
        _ if content.count == 0 => fitting_card_height(cap, &content),
        _ => content.budget_heights.map(|heights| heights[cap])
            .unwrap_or(content.card_height),
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
    // NotchViewModel.endSpread opens the whole shape past the hardware width.
    // Hardware dimensions, cells and fillets share design coordinates; sizeScale
    // is applied once when main places the panel, not undone for the cutout.
    let shape_length = (packed + gaps * spacing)
        .max(hardware.map_or(0.0, |notch| notch.width + 2.0 * 78.8 * K));
    let depth = if vertical {
        BODY_DEPTH
    } else {
        BODY_DEPTH - 44.0 + content.cell_extent + hardware.map_or(0.0, |notch| notch.height)
    };
    // NotchViewModel.cardBudget and NotchLayout.sessionsFitting. The search
    // starts at one and stops at the first row that cannot fit.
    let session_cap = if content.budget_heights.is_some() || content.snapshots.is_some() {
        let card_budget = if vertical {
            screen_height / scale - shape_length - 2.0 * CARD_CORNER
        } else {
            screen_height / scale - depth - TAIL
        };
        (1..=SESSION_CEILING)
            .take_while(|&n| fitting_card_height(n, &content) <= card_budget)
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
    fn description() -> CardDescription {
        CardDescription {
            window_count: 1, group_count: 0, money_window_count: 0,
            usage_detail_group_count: 0, status_message: None, block_message: None,
            has_token_usage: false, has_plan: false, has_reset_credits: false,
            local_model_name: None, shows_local_performance: false,
            local_ledger_rows: 0, compact_row_count: 0,
            shows_deepseek_pricing: true, status_height: None, block_height: None,
            model_name_height: None,
        }
    }
    fn content(count: usize) -> Content {
        Content {
            count,
            cell_extent: 71.11623931623932,
            card_height: 240.0,
            budget_heights: None,
            has_plan: false,
            has_token_usage: false,
            has_reset_credits: false,
            snapshots: None,
            body_line_height: None,
        }
    }
    #[test]
    fn hardware_join_matches_swift_shape_inset_and_single_scale() {
        let hardware = crate::native_notch::HardwareNotch { width: 220.0, height: 32.0 };
        for count in [1, 6] {
            for scale in [0.8, 1.0, 1.2] {
                let ordinary = calculate("top", content(count), 982.0, scale, None);
                let joined = calculate("top", content(count), 982.0, scale, Some(hardware));
                let source_drawn = (69.5 + 50.1) * K + count as f64 * 44.0
                    + count.saturating_sub(1) as f64 * GAP + 2.0 * 28.0 * K;
                let source_shape = source_drawn.max(220.0 + 2.0 * 78.8 * K);
                assert!((joined.shape_length - source_shape).abs() < 0.0001);
                assert!((joined.depth - ordinary.depth - 32.0).abs() < 0.0001);
                // Card slack remains in screen points; hardware inset scales with the notch.
                assert!(((joined.height - ordinary.height) * scale - 32.0 * scale).abs() < 0.0001);
                for edge in ["left", "right", "bottom"] {
                    let with = calculate(edge, content(count), 982.0, scale, Some(hardware));
                    let without = calculate(edge, content(count), 982.0, scale, None);
                    assert_eq!(with.shape_length, without.shape_length);
                    assert_eq!(with.depth, without.depth);
                }
            }
        }
    }

    #[test]
    fn six_accounts_spend_spacing_before_clipping_flare_or_settings_orb() {
        let l = calculate("right", content(6), 900.0, 1.0, None);
        assert!(l.height > 650.0);
        assert!(l.height <= 900.0 + 0.01);
        assert!(l.spacing < GAP && l.spacing > 0.0);
        assert!(l.height - l.shape_length >= 2.0 * (FLARE + 28.5));
    }
    #[test]
    fn flat_stack_uses_ring_width_and_symmetric_padding() {
        let l = calculate("top", content(6), 900.0, 1.0, None);
        let expected = (69.5 + 50.1 + 206.0 + 5.0 * 83.5) * K + 6.0 * 44.0;
        assert!((l.shape_length - expected).abs() < 1e-9);
        assert_eq!(l.spacing, GAP);
    }
    #[test]
    fn tooltip_room_does_not_scale_with_the_notch() {
        for s in [0.75, 1.0, 1.5] {
            let l = calculate("left", content(2), 1200.0, s, None);
            assert!(((l.width - BODY_DEPTH) * s - CARD_WIDTH - TAIL).abs() < 1e-9);
        }
    }
    #[test]
    fn crowded_stack_keeps_ring_size_instead_of_negative_spacing() {
        let l = calculate("right", content(12), 768.0, 1.0, None);
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
            snapshots: None,
            body_line_height: None,
        }
        .valid());
    }
    #[test]
    fn session_cap_uses_screen_budget_and_reserves_hidden_row() {
        let mut c = content(2);
        c.budget_heights = Some(std::array::from_fn(|n| 180.0 + n as f64 * 30.0));
        let small = calculate("right", c.clone(), 600.0, 1.0, None);
        let large = calculate("right", c, 1200.0, 1.0, None);
        assert_eq!(small.session_cap, 0); // actual one-window cards alone would fit two
        assert_eq!(large.session_cap, SESSION_CEILING);
        assert!((large.width - BODY_DEPTH - CARD_WIDTH - TAIL).abs() < 1e-9);
        assert!(large.height - large.shape_length >= 2.0 * (180.0 + 30.0 * 12.0) / 2.0);
    }
    #[test]
    fn semantic_cards_budget_money_details_and_wrapped_errors() {
        let basic = description();
        let baseline = described_card_height(&basic, 4, 12.0);
        let mut money = basic.clone();
        money.money_window_count = 1;
        money.usage_detail_group_count = 1;
        assert!(described_card_height(&money, 4, 12.0) > baseline + 100.0);
        let mut blocked = basic;
        blocked.block_message = Some("three lines".into());
        blocked.block_height = Some(36.0);
        let three = described_card_height(&blocked, 4, 12.0);
        blocked.block_height = Some(12.0);
        assert!((three - described_card_height(&blocked, 4, 12.0) - 24.0).abs() < 1e-9);
    }
    #[test]
    fn semantic_snapshots_override_dom_measurement() {
        let mut c = content(2);
        c.snapshots = Some(vec![description(), description()]);
        c.budget_heights = Some([10_000.0; SESSION_CEILING + 1]);
        let native = calculate("left", c.clone(), 900.0, 1.0, None);
        c.snapshots = None;
        let dom = calculate("left", c, 900.0, 1.0, None);
        assert!(native.height < dom.height);
    }
}
