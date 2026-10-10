#!/usr/bin/env python3
"""Patch Godot 4.7.1 so Space Miner can skip SDL gamepad startup.

The exported game remains a single executable. The patch is applied only while
building Space Miner's custom Godot export template in CI.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def patch_header(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "private:\n\tclass Joypad : public Input::JoypadFeatures {",
        "private:\n\tbool initialized = false;\n\n\tclass Joypad : public Input::JoypadFeatures {",
        "joypad_sdl.h initialized flag",
    )
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_cpp(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '#include "core/input/default_controller_mappings.h"\n#include "core/variant/dictionary.h"',
        '#include "core/input/default_controller_mappings.h"\n#include "core/io/file_access.h"\n#include "core/os/os.h"\n#include "core/variant/dictionary.h"',
        "joypad_sdl.cpp includes",
    )

    helpers = r'''static String _space_miner_read_text_file(const String &p_path) {
	Error error = OK;
	String value = FileAccess::get_file_as_string(p_path, &error);
	if (error != OK) {
		return String();
	}
	return value.strip_edges().to_lower();
}

static bool _space_miner_is_steam_deck() {
	// Steam sets this for native Steam Deck launches, and it may also survive
	// into a Proton/Wine process. Check it on every desktop platform first.
	if (OS::get_singleton()->has_environment("SteamDeck") &&
			OS::get_singleton()->get_environment("SteamDeck").strip_edges() == "1") {
		return true;
	}

#ifdef LINUXBSD_ENABLED
	const String vendor = _space_miner_read_text_file("/sys/class/dmi/id/sys_vendor");
	const String product = _space_miner_read_text_file("/sys/class/dmi/id/product_name");
	const String board = _space_miner_read_text_file("/sys/class/dmi/id/board_name");
	const bool have_dmi = !vendor.is_empty() || !product.is_empty() || !board.is_empty();

	if (have_dmi) {
		const bool valve_hardware = vendor.contains("valve");
		const bool deck_model =
				product.contains("jupiter") ||
				product.contains("galileo") ||
				product.contains("steam deck") ||
				board.contains("jupiter") ||
				board.contains("galileo") ||
				board.contains("steam deck");
		return valve_hardware && deck_model;
	}
#endif

	return false;
}

static bool _space_miner_gamepad_enabled() {
	const bool platform_default = _space_miner_is_steam_deck();
	const String user_data_dir = OS::get_singleton()->get_user_data_dir();
	if (user_data_dir.is_empty()) {
		return platform_default;
	}

	Error error = OK;
	const String settings = FileAccess::get_file_as_string(
			user_data_dir.path_join("space_miner_settings.cfg"), &error);
	if (error != OK) {
		return platform_default;
	}

	String section;
	const PackedStringArray lines = settings.split("\n");
	for (int i = 0; i < lines.size(); i++) {
		const String line = lines[i].strip_edges();
		if (line.is_empty() || line.begins_with(";") || line.begins_with("#")) {
			continue;
		}

		if (line.begins_with("[") && line.ends_with("]")) {
			section = line.substr(1, line.length() - 2).strip_edges().to_lower();
			continue;
		}

		if (section != "controls") {
			continue;
		}

		const int equals = line.find("=");
		if (equals < 0) {
			continue;
		}

		const String key = line.substr(0, equals).strip_edges().to_lower();
		if (key != "gamepad_enabled") {
			continue;
		}

		const String value = line.substr(equals + 1).strip_edges().to_lower();
		if (value == "true" || value == "1" || value == "yes" || value == "on") {
			return true;
		}
		if (value == "false" || value == "0" || value == "no" || value == "off") {
			return false;
		}
	}

	return platform_default;
}

'''

    text = replace_once(
        text,
        "JoypadSDL::~JoypadSDL() {",
        helpers + "JoypadSDL::~JoypadSDL() {\n\tif (!initialized) {\n\t\treturn;\n\t}",
        "joypad_sdl.cpp helpers/destructor",
    )

    text = replace_once(
        text,
        "Error JoypadSDL::initialize() {\n\tSDL_SetHint(SDL_HINT_JOYSTICK_THREAD, \"1\");",
        "Error JoypadSDL::initialize() {\n\tif (!_space_miner_gamepad_enabled()) {\n\t\tprint_verbose(\"Space Miner: SDL joypad backend disabled for this run.\");\n\t\treturn OK;\n\t}\n\n\tSDL_SetHint(SDL_HINT_JOYSTICK_THREAD, \"1\");",
        "joypad_sdl.cpp initialize gate",
    )

    text = replace_once(
        text,
        "\tERR_FAIL_COND_V_MSG(!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD), FAILED, SDL_GetError());",
        "\tERR_FAIL_COND_V_MSG(!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD), FAILED, SDL_GetError());\n\tinitialized = true;",
        "joypad_sdl.cpp initialized state",
    )

    text = replace_once(
        text,
        "void JoypadSDL::process_events() {\n\t// Update rumble first for it to be applied when we handle SDL events",
        "void JoypadSDL::process_events() {\n\tif (!initialized) {\n\t\treturn;\n\t}\n\n\t// Update rumble first for it to be applied when we handle SDL events",
        "joypad_sdl.cpp process guard",
    )

    path.write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("godot_source", type=Path)
    args = parser.parse_args()

    source = args.godot_source.resolve()
    header = source / "drivers" / "sdl" / "joypad_sdl.h"
    cpp = source / "drivers" / "sdl" / "joypad_sdl.cpp"

    if not header.is_file() or not cpp.is_file():
        raise RuntimeError(f"Not a Godot source tree: {source}")

    patch_header(header)
    patch_cpp(cpp)
    print(f"Patched Godot gamepad startup in {source}")


if __name__ == "__main__":
    main()
