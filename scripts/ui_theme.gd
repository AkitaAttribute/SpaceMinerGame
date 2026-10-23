class_name SpaceMinerTheme
extends RefCounted

static func palette(dark: bool) -> Dictionary:
    if dark:
        return {
            "background": Color("#111827"),
            "panel": Color("#1d293a"),
            "panel_alt": Color("#253449"),
            "text": Color("#eef4ff"),
            "muted": Color("#9eacc1"),
            "accent": Color("#4fb7d8"),
            "accent_hover": Color("#69c9e6"),
            "border": Color("#50647f"),
            "danger": Color("#d96f78"),
            "overlay": Color(0.02, 0.03, 0.05, 0.64),
            "parts_overlay": Color(0.02, 0.03, 0.05, 0.28),
        }
    return {
        "background": Color("#dce6f2"),
        "panel": Color("#f8fbff"),
        "panel_alt": Color("#e8f0f8"),
        "text": Color("#172238"),
        "muted": Color("#53657d"),
        "accent": Color("#267ea6"),
        "accent_hover": Color("#3594bd"),
        "border": Color("#7f96ad"),
        "danger": Color("#a84550"),
        "overlay": Color(0.75, 0.80, 0.87, 0.62),
        "parts_overlay": Color(0.75, 0.80, 0.87, 0.26),
    }

static func build(dark: bool) -> Theme:
    var colors := palette(dark)
    var theme := Theme.new()
    theme.default_font_size = 17

    theme.set_color("font_color", "Label", colors["text"])
    theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.22) if dark else Color(1, 1, 1, 0.2))
    theme.set_color("font_color", "Button", colors["text"])
    theme.set_color("font_hover_color", "Button", colors["text"])
    theme.set_color("font_pressed_color", "Button", colors["text"])
    theme.set_color("font_focus_color", "Button", colors["text"])
    theme.set_color("font_color", "CheckButton", colors["text"])
    theme.set_color("font_color", "OptionButton", colors["text"])
    theme.set_color("font_hover_color", "OptionButton", colors["text"])

    var normal := _box(colors["panel_alt"], colors["border"], 10, 1)
    var hover := _box(colors["accent_hover"].lerp(colors["panel_alt"], 0.62), colors["accent"], 10, 1)
    var pressed := _box(colors["accent"].lerp(colors["panel_alt"], 0.48), colors["accent"], 10, 2)
    var focus := _box(colors["panel_alt"], colors["accent"], 10, 2)
    var disabled := _box(colors["panel_alt"], colors["border"], 10, 1)
    disabled.bg_color.a = 0.45

    for type_name in ["Button", "OptionButton", "CheckButton"]:
        theme.set_stylebox("normal", type_name, normal)
        theme.set_stylebox("hover", type_name, hover)
        theme.set_stylebox("pressed", type_name, pressed)
        theme.set_stylebox("focus", type_name, focus)
        theme.set_stylebox("disabled", type_name, disabled)

    theme.set_stylebox("panel", "PanelContainer", _box(colors["panel"], colors["border"], 14, 1))
    theme.set_stylebox("panel", "Panel", _box(colors["panel"], colors["border"], 14, 1))
    theme.set_stylebox("panel", "PopupPanel", _box(colors["panel"], colors["border"], 10, 1))
    theme.set_stylebox("normal", "LineEdit", _box(colors["panel_alt"], colors["border"], 8, 1))
    theme.set_stylebox("focus", "LineEdit", _box(colors["panel_alt"], colors["accent"], 8, 2))
    theme.set_color("font_color", "LineEdit", colors["text"])
    theme.set_color("font_selected_color", "LineEdit", colors["text"])
    theme.set_color("selection_color", "LineEdit", colors["accent"])

    return theme

static func _box(background: Color, border: Color, radius: int, width: int) -> StyleBoxFlat:
    var box := StyleBoxFlat.new()
    box.bg_color = background
    box.border_color = border
    box.set_border_width_all(width)
    box.corner_radius_top_left = radius
    box.corner_radius_top_right = radius
    box.corner_radius_bottom_left = radius
    box.corner_radius_bottom_right = radius
    box.content_margin_left = 10
    box.content_margin_right = 10
    box.content_margin_top = 8
    box.content_margin_bottom = 8
    return box
