//! The macOS menu-bar face, drawn into one template image from the same SVG marks as the notch.
//! AppKit drawing is invoked only by `tray::refresh_menu` on the main thread. The tray adapter
//! scales the PNG to 18 pt high, so the bitmap is rendered at 2x for Retina without shipping a
//! pre-rendered image or depending on a display-specific scale at build time.

#[cfg(target_os = "macos")]
pub fn render(app: &tauri::AppHandle, entries: &[crate::tray::MenuBarEntry], lang: &str) -> Option<tauri::image::Image<'static>> {
    use objc2::{runtime::AnyObject, AnyThread};
    use objc2_app_kit::{
        NSBitmapImageFileType, NSBitmapImageRep, NSColor, NSCompositingOperation, NSFont,
        NSFontAttributeName, NSForegroundColorAttributeName, NSGraphicsContext, NSImage,
        NSBezierPath, NSLineCapStyle, NSStringDrawing,
    };
    use objc2_core_graphics::CGContextScaleCTM;
    use objc2_foundation::{NSDictionary, NSData, NSAttributedStringKey, NSPoint, NSRect, NSSize, NSString};
    use tauri::Manager;

    if entries.is_empty() { return None; }
    let font_size = NSFont::menuBarFontOfSize(0.0).pointSize();
    let font = NSFont::monospacedDigitSystemFontOfSize_weight(font_size, 0.0);
    let glyph_size = (font_size * 1.1).round();
    let glyph_gap = (font_size * 0.3).round();
    let entry_gap = (font_size * 0.55).round();
    let height = 18.0;
    let baseline = ((height - font.capHeight()) * 0.5 * 2.0).round() * 0.5;
    let middle = baseline + font.capHeight() * 0.5;
    let font_object: &AnyObject = &font;
    let measure: objc2::rc::Retained<NSDictionary<NSAttributedStringKey, AnyObject>> =
        NSDictionary::from_slices(&[unsafe { NSFontAttributeName }], &[font_object]);
    let width = |text: &str| -> f64 {
        unsafe { NSString::from_str(text).sizeWithAttributes(Some(&measure)).width }
    };
    let percent_room = width("00%");
    let countdown_room = width(&crate::tray::countdown_room(lang));
    let endpoints = app.state::<crate::AppState>().cfg.lock().unwrap().custom_endpoints.clone();
    let custom_icons: std::collections::BTreeMap<_, _> = endpoints.iter()
        .map(|endpoint| (format!("custom-endpoint-{}", endpoint.id),
            (endpoint.icon.clone(), crate::custom_endpoint::icon_png_for(endpoint))))
        .collect();
    let glyphs: Vec<_> = entries.iter().map(|entry| {
        if let Some((icon, _)) = custom_icons.get(&entry.id) {
            glyph_id(icon).unwrap_or("codex") // Source's custom-endpoint fallback is the OpenAI mark.
        } else { glyph_id(&entry.id).unwrap_or("third") }
    }).collect();
    let mut counts = std::collections::HashMap::<&str, usize>::new();
    for glyph in &glyphs { *counts.entry(*glyph).or_default() += 1; }
    let compact = entries.len() > 2;
    let mut marks = Vec::new();
    let mut x = 0.0_f64;
    for (index, entry) in entries.iter().enumerate() {
        if index > 0 {
            x = (x + entry_gap).round();
            marks.push(Mark::Rule(x, middle - glyph_size * 0.5, glyph_size));
            x += 1.0 + entry_gap;
        }
        let alpha = if entry.stale && (entry.percent != "—" || entry.weekly_fraction.is_some()) { 0.5 } else { 1.0 };
        marks.push(Mark::Glyph(glyphs[index], custom_icons.get(&entry.id)
            .and_then(|(_, png)| png.clone()), x, middle - glyph_size * 0.5,
            glyph_size, entry.weekly_fraction, alpha));
        x += glyph_size + glyph_gap;
        if counts[glyphs[index]] > 1 {
            if let Some(slug) = profile_slug(&entry.id) {
                marks.push(Mark::Text(slug.into(), x, baseline, alpha));
                x += width(slug) + glyph_gap;
            }
        }
        if entry.percent == "—" && entry.countdown == "—" {
            marks.push(Mark::Text("—".into(), x, baseline, alpha));
            x += width("—");
            continue;
        }
        x += (percent_room - width(&entry.percent)).max(0.0);
        marks.push(Mark::Text(entry.percent.clone(), x, baseline, alpha));
        x += width(&entry.percent);
        if !compact {
            marks.push(Mark::Text(" · ".into(), x, baseline, alpha));
            x += width(" · ");
            let start = x;
            marks.push(Mark::Text(entry.countdown.clone(), x, baseline, alpha));
            x += width(&entry.countdown);
            x = x.max(start + countdown_room);
        }
    }
    let logical_width = x.ceil().max(1.0);
    let scale = 2.0;
    let bitmap = unsafe {
        NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
            NSBitmapImageRep::alloc(), std::ptr::null_mut(), (logical_width * scale).ceil() as isize,
            (height * scale) as isize, 8, 4, true, false,
            unsafe { objc2_app_kit::NSDeviceRGBColorSpace }, 0, 0,
        )
    }?;
    // The initializer owns the planes, but their initial bytes are not a drawing contract.
    let pixels = bitmap.bitmapData();
    if pixels.is_null() || bitmap.bytesPerRow() <= 0 { return None; }
    unsafe { std::ptr::write_bytes(pixels, 0,
        bitmap.bytesPerRow() as usize * (height * scale) as usize); }
    let context = NSGraphicsContext::graphicsContextWithBitmapImageRep(&bitmap)?;
    let previous = NSGraphicsContext::currentContext();
    NSGraphicsContext::setCurrentContext(Some(&context));
    NSGraphicsContext::saveGraphicsState_class();
    CGContextScaleCTM(Some(&context.CGContext()), scale, scale);
    for mark in marks {
        match mark {
            Mark::Text(text, x, y, alpha) => {
                let ink = NSColor::colorWithCalibratedWhite_alpha(0.0, alpha);
                let color_object: &AnyObject = &ink;
                let attrs: objc2::rc::Retained<NSDictionary<NSAttributedStringKey, AnyObject>> =
                    NSDictionary::from_slices(
                        &[unsafe { NSFontAttributeName }, unsafe { NSForegroundColorAttributeName }],
                        &[font_object, color_object],
                    );
                unsafe { NSString::from_str(&text).drawAtPoint_withAttributes(NSPoint { x, y }, Some(&attrs)); }
            }
            Mark::Rule(x, y, h) => {
                NSColor::colorWithCalibratedWhite_alpha(0.0, 0.35).setFill();
                NSBezierPath::bezierPathWithRect(NSRect { origin: NSPoint { x, y },
                    size: NSSize { width: 1.0, height: h } }).fill();
            }
            Mark::Glyph(id, custom_png, x, y, size, weekly, alpha) => {
                let mut inset = 0.0;
                if let Some(fraction) = weekly {
                    let center = NSPoint { x: x + size * 0.5, y: y + size * 0.5 };
                    let ring = NSBezierPath::bezierPath();
                    ring.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise(
                        center, size * 0.5 - 0.75, 90.0, -270.0, true);
                    ring.setLineWidth(1.0);
                    NSColor::colorWithCalibratedWhite_alpha(0.0, alpha * 0.32).setStroke();
                    ring.stroke();
                    if fraction > 0 {
                        let progress = NSBezierPath::bezierPath();
                        progress.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise(
                            center, size * 0.5 - 0.75, 90.0, 90.0 - 360.0 * fraction as f64 / 1000.0, true);
                        progress.setLineWidth(1.25);
                        progress.setLineCapStyle(NSLineCapStyle::Round);
                        NSColor::colorWithCalibratedWhite_alpha(0.0, alpha).setStroke();
                        progress.stroke();
                    }
                    inset = 2.25;
                }
                if let Some(bytes) = custom_png.as_deref().or_else(|| glyph_bytes(id)) {
                    let data = NSData::from_vec(bytes.to_vec());
                    if let Some(image) = NSImage::initWithData(NSImage::alloc(), &data) {
                        let optical = optical_scale(id);
                        let diameter = (size - inset * 2.0) * optical;
                        let source = image.size();
                        let fit = (diameter / source.width.max(1.0)).min(diameter / source.height.max(1.0));
                        let fitted = NSSize { width: source.width * fit, height: source.height * fit };
                        let rect = NSRect { origin: NSPoint { x: x + (size - fitted.width) * 0.5,
                            y: y + (size - fitted.height) * 0.5 }, size: fitted };
                        image.drawInRect_fromRect_operation_fraction(rect, NSRect::ZERO,
                            NSCompositingOperation::SourceOver, alpha);
                    }
                }
            }
        }
    }
    NSGraphicsContext::restoreGraphicsState_class();
    NSGraphicsContext::setCurrentContext(previous.as_deref());
    let png = unsafe { bitmap.representationUsingType_properties(
        NSBitmapImageFileType::PNG, &NSDictionary::new()) }?;
    tauri::image::Image::from_bytes(unsafe { png.as_bytes_unchecked() }).ok()
}

#[cfg(target_os = "macos")]
enum Mark {
    Text(String, f64, f64, f64),
    Rule(f64, f64, f64),
    Glyph(&'static str, Option<Vec<u8>>, f64, f64, f64, Option<u32>, f64),
}

#[cfg(target_os = "macos")]
fn profile_slug(id: &str) -> Option<&str> {
    id.strip_prefix("claude-").or_else(|| id.strip_prefix("codex-"))
}

#[cfg(target_os = "macos")]
fn glyph_id(id: &str) -> Option<&'static str> {
    if id == "claude" || id.starts_with("claude-") { Some("claude") }
    else if id == "codex" || id.starts_with("codex-") || id == "openai" { Some("codex") }
    else if id == "gemini" || id.starts_with("antigravity-") { Some("gemini") }
    else { match id {
        "cursor" => "cursor", "grok" => "grok", "gemini-api" | "gemini-spark" => "gemini-api",
        "glm" => "glm", "kimi" => "kimi", "kiro" => "kiro", "copilot" => "copilot",
        "opencode" => "opencode", "commandcode" => "commandcode", "minimax" => "minimax",
        "ollama-cloud" => "ollama-cloud", "ollama-local" => "ollama-local",
        "lmstudio" => "lmstudio", "devin" => "devin", "deepseek" => "deepseek",
        "qianwenai" => "qianwenai", "qwen" => "qwen", "gemma" => "gemma",
        "meta" => "meta", "mistral" => "mistral", "third" => "third",
        _ => return None,
    }.into()}
}

#[cfg(target_os = "macos")]
fn optical_scale(id: &str) -> f64 {
    match id {
        "claude" | "cursor" | "qianwenai" => 0.97,
        "codex" => 0.94,
        "glm" | "opencode" | "kimi" | "kiro" | "minimax" | "ollama-cloud" => 0.95,
        "commandcode" | "copilot" | "lmstudio" => 0.96,
        "ollama-local" => 0.98,
        _ => 1.0,
    }
}

#[cfg(target_os = "macos")]
fn glyph_bytes(id: &str) -> Option<&'static [u8]> {
    Some(match id {
        "claude" => include_bytes!("../glyphs/swift/claude.svg"),
        "codex" => include_bytes!("../glyphs/swift/codex.svg"),
        "cursor" => include_bytes!("../glyphs/swift/cursor.svg"),
        "grok" => include_bytes!("../glyphs/swift/grok.svg"),
        "gemini" => include_bytes!("../glyphs/swift/gemini.svg"),
        "gemini-api" => include_bytes!("../glyphs/swift/gemini-api.svg"),
        "glm" => include_bytes!("../glyphs/swift/glm.svg"),
        "kimi" => include_bytes!("../glyphs/swift/kimi.svg"),
        "kiro" => include_bytes!("../glyphs/swift/kiro.svg"),
        "copilot" => include_bytes!("../glyphs/swift/copilot.svg"),
        "opencode" => include_bytes!("../glyphs/swift/opencode.svg"),
        "commandcode" => include_bytes!("../glyphs/swift/commandcode.svg"),
        "minimax" => include_bytes!("../glyphs/swift/minimax.svg"),
        "ollama-cloud" | "ollama-local" => include_bytes!("../glyphs/swift/ollama.svg"),
        "lmstudio" => include_bytes!("../glyphs/swift/lmstudio.svg"),
        "devin" => include_bytes!("../glyphs/swift/devin.png"),
        "deepseek" => include_bytes!("../glyphs/swift/deepseek.svg"),
        "qianwenai" => include_bytes!("../glyphs/swift/qianwenai.png"),
        "qwen" => include_bytes!("../glyphs/swift/qwen.svg"),
        "gemma" => include_bytes!("../glyphs/swift/gemma.svg"),
        "meta" => include_bytes!("../glyphs/swift/meta.svg"),
        "mistral" => include_bytes!("../glyphs/swift/mistral.svg"),
        "third" => include_bytes!("../glyphs/swift/third.svg"),
        _ => return None,
    })
}
