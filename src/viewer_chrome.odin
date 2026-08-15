package main

import "core:fmt"
import "core:math"
import framework_draw "ui_framework:draw"
import framework_ui "ui_framework:core"
import hal_ui "ui_framework:hal_wayland"

VIEWER_WINDOW_MINIMIZE_STYLE :: uint(15)
VIEWER_WINDOW_RESIZE_INSET :: 6.0

Viewer_Icon_Point :: struct {
	point: [2]f32,
	move:  bool,
}

viewer_icon_xmark_points :: proc() -> [8]Viewer_Icon_Point {
	return {
		{{6.75827, 17.2426}, true},
		{{12.0009, 12}, false},
		{{17.2435, 6.75736}, true},
		{{12.0009, 12}, false},
		{{12.0009, 12}, true},
		{{6.75827, 6.75736}, false},
		{{12.0009, 12}, true},
		{{17.2435, 17.2426}, false},
	}
}

viewer_icon_minus_points :: proc() -> [2]Viewer_Icon_Point {
	return {
		{{6, 12}, true},
		{{18, 12}, false},
	}
}

viewer_icon_maximize_points :: proc() -> [12]Viewer_Icon_Point {
	return {
		{{7, 4}, true},
		{{4, 4}, false},
		{{4, 7}, false},
		{{17, 4}, true},
		{{20, 4}, false},
		{{20, 7}, false},
		{{7, 20}, true},
		{{4, 20}, false},
		{{4, 17}, false},
		{{17, 20}, true},
		{{20, 20}, false},
		{{20, 17}, false},
	}
}

viewer_settings_icon_rect :: proc(height: f32) -> framework_draw.Rect {
	control := hal_ui.window_control_rect(3, height)
	return {control.x+6, control.y+6, 18, 18}
}

viewer_refresh_rect :: proc(width, height: f32) -> framework_draw.Rect {
	return {
		width-90,
		height-hal_ui.METRICS.window_control-1,
		80,
		hal_ui.METRICS.window_control,
	}
}

viewer_icon_map_point :: proc(rect: framework_draw.Rect, x, y: f32) -> [2]f32 {
	return {rect.x+x*rect.w/24, rect.y+(24-y)*rect.h/24}
}

viewer_draw_icon_line :: proc(
	list: ^framework_draw.List,
	from, to: [2]f32,
	color: framework_draw.Color,
	thickness: f32,
) {
	dx, dy := to[0]-from[0], to[1]-from[1]
	length := math.sqrt(dx*dx+dy*dy)
	if length <= 0 {return}
	angle := math.atan2(dy, dx)
	framework_draw.push_transform(
		list,
		{
			math.cos(angle),
			math.sin(angle),
			-math.sin(angle),
			math.cos(angle),
			from[0],
			from[1],
		},
	)
	framework_draw.solid(list, {0, -thickness/2, length, thickness}, color, thickness/2)
	framework_draw.pop_transform(list)
}

viewer_draw_icon_cubic :: proc(
	list: ^framework_draw.List,
	from, control_1, control_2, to: [2]f32,
	color: framework_draw.Color,
	thickness: f32,
) {
	previous := from
	for index in 1..=12 {
		t := f32(index)/12
		inverse := 1-t
		next := [2]f32{
			inverse*inverse*inverse*from[0]+
			3*inverse*inverse*t*control_1[0]+
			3*inverse*t*t*control_2[0]+
			t*t*t*to[0],
			inverse*inverse*inverse*from[1]+
			3*inverse*inverse*t*control_1[1]+
			3*inverse*t*t*control_2[1]+
			t*t*t*to[1],
		}
		viewer_draw_icon_line(list, previous, next, color, thickness)
		previous = next
	}
}

viewer_draw_iconoir_stroke :: proc(
	list: ^framework_draw.List,
	rect: framework_draw.Rect,
	color: framework_draw.Color,
	points: []Viewer_Icon_Point,
) {
	if list == nil || len(points) == 0 {return}
	thickness := 1.5*min(rect.w, rect.h)/24
	previous: [2]f32
	has_previous := false
	for command in points {
		mapped := viewer_icon_map_point(rect, command.point[0], command.point[1])
		if command.move {
			previous = mapped
			has_previous = true
			continue
		}
		if has_previous {viewer_draw_icon_line(list, previous, mapped, color, thickness)}
		previous = mapped
		has_previous = true
	}
}

viewer_draw_settings_icon :: proc(
	list: ^framework_draw.List,
	rect: framework_draw.Rect,
	color: framework_draw.Color,
) {
	if list == nil {return}
	thickness := 1.5*min(rect.w, rect.h)/24
	previous := viewer_icon_map_point(rect, 12, 15)
	inner := [4][3][2]f32{
		{{13.6569, 15}, {15, 13.6569}, {15, 12}},
		{{15, 10.3431}, {13.6569, 9}, {12, 9}},
		{{10.3431, 9}, {9, 10.3431}, {9, 12}},
		{{9, 13.6569}, {10.3431, 15}, {12, 15}},
	}
	for curve in inner {
		control_1 := viewer_icon_map_point(rect, curve[0][0], curve[0][1])
		control_2 := viewer_icon_map_point(rect, curve[1][0], curve[1][1])
		next := viewer_icon_map_point(rect, curve[2][0], curve[2][1])
		viewer_draw_icon_cubic(list, previous, control_1, control_2, next, color, thickness)
		previous = next
	}
	gear := [30][2]f32{
		{19.6224, 10.3954}, {18.5247, 7.7448}, {20, 6}, {18, 4},
		{16.2647, 5.48295}, {13.5578, 4.36974}, {12.9353, 2}, {10.981, 2},
		{10.3491, 4.40113}, {7.70441, 5.51596}, {6, 4}, {4, 6},
		{5.45337, 7.78885}, {4.3725, 10.4463}, {2, 11}, {2, 13},
		{4.40111, 13.6555}, {5.51575, 16.2997}, {4, 18}, {6, 20},
		{7.79116, 18.5403}, {10.397, 19.6123}, {11, 22}, {13, 22},
		{13.6045, 19.6132}, {16.2551, 18.5155}, {18.5159, 16.2494},
		{19.6139, 13.598}, {21.9999, 12.9772}, {22, 11},
	}
	previous = viewer_icon_map_point(rect, gear[0][0], gear[0][1])
	for index in 1..<26 {
		next := viewer_icon_map_point(rect, gear[index][0], gear[index][1])
		viewer_draw_icon_line(list, previous, next, color, thickness)
		previous = next
	}
	control_1 := viewer_icon_map_point(rect, 16.6969, 18.8313)
	control_2 := viewer_icon_map_point(rect, 18, 20)
	next := viewer_icon_map_point(rect, 18, 20)
	viewer_draw_icon_cubic(list, previous, control_1, control_2, next, color, thickness)
	previous = next
	next = viewer_icon_map_point(rect, 20, 18)
	viewer_draw_icon_line(list, previous, next, color, thickness)
	previous = next
	for index in 26..<len(gear) {
		next = viewer_icon_map_point(rect, gear[index][0], gear[index][1])
		viewer_draw_icon_line(list, previous, next, color, thickness)
		previous = next
	}
	viewer_draw_icon_line(
		list,
		previous,
		viewer_icon_map_point(rect, gear[0][0], gear[0][1]),
		color,
		thickness,
	)
}

viewer_draw_xmark_icon :: proc(user_data: rawptr, list: ^framework_draw.List, rect: framework_draw.Rect) {
	_ = user_data
	points := viewer_icon_xmark_points()
	viewer_draw_iconoir_stroke(list, rect, viewer_theme().destructive, points[:])
}

viewer_draw_minus_icon :: proc(user_data: rawptr, list: ^framework_draw.List, rect: framework_draw.Rect) {
	_ = user_data
	points := viewer_icon_minus_points()
	viewer_draw_iconoir_stroke(list, rect, viewer_theme().primary, points[:])
}

viewer_draw_maximize_icon :: proc(user_data: rawptr, list: ^framework_draw.List, rect: framework_draw.Rect) {
	_ = user_data
	points := viewer_icon_maximize_points()
	viewer_draw_iconoir_stroke(list, rect, viewer_theme().alternate, points[:])
}

viewer_draw_gear_icon :: proc(user_data: rawptr, list: ^framework_draw.List, rect: framework_draw.Rect) {
	_ = user_data
	viewer_draw_settings_icon(list, rect, viewer_theme().text_soft)
}

viewer_chrome_button_style :: proc(theme: hal_ui.Palette) -> framework_ui.Style {
	return {background=theme.field, text=theme.text, opacity=1}
}

viewer_add_icon_box :: proc(
	frame: ^framework_ui.Frame,
	name: string,
	rect: framework_draw.Rect,
	draw: framework_ui.Custom_Draw_Proc,
	layer: framework_ui.Layer,
) {
	_ = framework_ui.box_add(frame, {
		key=framework_ui.key_from_string(name),
		layout={position=.Absolute, absolute=rect},
		custom_draw=draw,
		layer=layer,
	})
}

viewer_add_window_chrome :: proc(
	frame: ^framework_ui.Frame,
	theme: hal_ui.Palette,
	layer: framework_ui.Layer,
	interactive: bool,
) {
	height := f32(viewer.height)
	style := viewer_chrome_button_style(theme)
	names := [4]string{"window close", "window minimize", "window zoom", "settings"}
	labels := [4]string{"close window", "minimize window", "zoom window", "settings"}
	actions := [4]Viewer_Action_Kind{.Window_Close, .Window_Minimize, .Window_Zoom, .Open_Settings}
	draws := [4]framework_ui.Custom_Draw_Proc{
		viewer_draw_xmark_icon,
		viewer_draw_minus_icon,
		viewer_draw_maximize_icon,
		viewer_draw_gear_icon,
	}
	for index in 0..<4 {
		rect := hal_ui.window_control_rect(index, height)
		prefix := "" if interactive else "modal "
		if interactive {
			passthrough := index < 3
			viewer_chrome_control(
				frame,
				names[index],
				labels[index],
				rect,
				{kind=actions[index]},
				style,
				passthrough,
				layer,
			)
		} else {
			viewer_box(frame, fmt_chrome_name(prefix, names[index], " fill"), "", rect, style, {.Draw_Background}, layer)
		}
		icon_rect := viewer_settings_icon_rect(height) if index == 3 else
			hal_ui.window_icon_rect(index, height)
		viewer_add_icon_box(frame, fmt_chrome_name(prefix, names[index], " icon"), icon_rect, draws[index], layer)
	}
}

fmt_chrome_name :: proc(prefix, name, suffix: string) -> string {
	return fmt.tprintf("%s%s%s", prefix, name, suffix)
}

viewer_chrome_control :: proc(
	frame: ^framework_ui.Frame,
	name, label: string,
	rect: framework_draw.Rect,
	action: Viewer_Action,
	style: framework_ui.Style,
	passthrough: bool,
	layer: framework_ui.Layer,
) {
	id := framework_ui.action_id_from_string(name)
	framework_ui.register_action(frame, {
		id=id,
		functional_name=name,
		label=label,
		enabled=true,
	})
	append(&viewer.bindings, Viewer_Action_Binding{id=id, action=action})
	flags := framework_ui.Box_Flags{.Draw_Background, .Interactive}
	if passthrough {flags += {.Input_Passthrough}}
	_ = framework_ui.box_add(frame, {
		key=framework_ui.Key(id),
		layout={position=.Absolute, absolute=rect},
		style=style,
		flags=flags,
		layer=layer,
		control={
			functional_name=name,
			accessibility_label=label,
			accessibility_role=.Button,
			flash_label=label,
			flash_anchor=.Top_Left,
			capabilities={.Hover, .Primary_Press, .Accessibility, .Flash, .CLI},
			action=id,
		},
	})
}

viewer_window_zoom_next_frame :: proc(
	current, visible, restore: Rect,
	has_restore: bool,
) -> (next, next_restore: Rect, next_has_restore: bool) {
	if has_restore && current == visible {
		return restore, {}, false
	}
	return visible, current, true
}

viewer_toggle_window_zoom :: proc() {
	if viewer.window == nil {return}
	screen := msg_id(viewer.window, sel_registerName("screen"))
	if screen == nil {
		screen = msg_id(objc_getClass("NSScreen"), sel_registerName("mainScreen"))
	}
	if screen == nil {return}
	current := msg_rect(viewer.window, sel_registerName("frame"))
	visible := msg_rect(screen, sel_registerName("visibleFrame"))
	next, restore, has_restore := viewer_window_zoom_next_frame(
		current,
		visible,
		viewer.window_zoom_restore_frame,
		viewer.window_has_zoom_restore,
	)
	viewer.window_zoom_restore_frame = restore
	viewer.window_has_zoom_restore = has_restore
	msg_void_rect_bool(viewer.window, sel_registerName("setFrame:display:"), next, true)
	viewer.needs_redraw = true
}

viewer_resize_edges :: proc(point: Point, width, height: f64) -> u8 {
	edges := u8(0)
	if point.x <= VIEWER_WINDOW_RESIZE_INSET {edges |= 1}
	if point.x >= width-VIEWER_WINDOW_RESIZE_INSET {edges |= 2}
	if point.y <= VIEWER_WINDOW_RESIZE_INSET {edges |= 4}
	if point.y >= height-VIEWER_WINDOW_RESIZE_INSET {edges |= 8}
	return edges
}

viewer_begin_resize :: proc(point: Point) -> bool {
	edges := viewer_resize_edges(point, viewer.width, viewer.height)
	if edges == 0 {return false}
	viewer.resize_edges = edges
	viewer.resize_start_mouse = msg_point(
		objc_getClass("NSEvent"),
		sel_registerName("mouseLocation"),
	)
	viewer.resize_start_frame = msg_rect(viewer.window, sel_registerName("frame"))
	return true
}

viewer_apply_resize :: proc() {
	if viewer.resize_edges == 0 || viewer.window == nil {return}
	mouse := msg_point(objc_getClass("NSEvent"), sel_registerName("mouseLocation"))
	delta := Point{
		mouse.x-viewer.resize_start_mouse.x,
		mouse.y-viewer.resize_start_mouse.y,
	}
	start := viewer.resize_start_frame
	frame := start
	if viewer.resize_edges&1 != 0 {
		frame.size.width = max(VIEWER_MIN_WIDTH, start.size.width-delta.x)
		frame.origin.x = start.origin.x+start.size.width-frame.size.width
	} else if viewer.resize_edges&2 != 0 {
		frame.size.width = max(VIEWER_MIN_WIDTH, start.size.width+delta.x)
	}
	if viewer.resize_edges&4 != 0 {
		frame.size.height = max(VIEWER_MIN_HEIGHT, start.size.height-delta.y)
		frame.origin.y = start.origin.y+start.size.height-frame.size.height
	} else if viewer.resize_edges&8 != 0 {
		frame.size.height = max(VIEWER_MIN_HEIGHT, start.size.height+delta.y)
	}
	msg_void_rect_bool(viewer.window, sel_registerName("setFrame:display:"), frame, true)
	viewer.needs_redraw = true
}

viewer_header_click_should_zoom :: proc(click_count: uint) -> bool {
	return click_count >= 2
}
