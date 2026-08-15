package main

import "core:testing"
import framework_draw "ui_framework:draw"
import hal_ui "ui_framework:hal_wayland"

viewer_icon_points_use_iconoir_viewbox :: proc(
	t: ^testing.T,
	points: []Viewer_Icon_Point,
	path_length: int,
) {
	for point, index in points {
		testing.expect(t, point.point[0] >= 0 && point.point[0] <= 24)
		testing.expect(t, point.point[1] >= 0 && point.point[1] <= 24)
		testing.expect_value(t, point.move, index%path_length == 0)
	}
}

@(test)
viewer_window_icons_match_iconoir_paths_test :: proc(t: ^testing.T) {
	xmark := viewer_icon_xmark_points()
	testing.expect_value(t, len(xmark), 8)
	viewer_icon_points_use_iconoir_viewbox(t, xmark[:], 2)

	minus := viewer_icon_minus_points()
	testing.expect_value(t, len(minus), 2)
	viewer_icon_points_use_iconoir_viewbox(t, minus[:], 2)

	maximize := viewer_icon_maximize_points()
	testing.expect_value(t, len(maximize), 12)
	viewer_icon_points_use_iconoir_viewbox(t, maximize[:], 3)
}

@(test)
viewer_window_controls_reach_top_edge_test :: proc(t: ^testing.T) {
	height := f32(720)
	close := hal_ui.window_control_rect(0, height)
	minimize := hal_ui.window_control_rect(1, height)
	zoom := hal_ui.window_control_rect(2, height)
	testing.expect_value(t, close, framework_draw.Rect{0, 690, 30, 30})
	testing.expect_value(t, minimize, framework_draw.Rect{38, 690, 30, 30})
	testing.expect_value(t, zoom, framework_draw.Rect{76, 690, 30, 30})
	testing.expect_value(t, close.y+close.h, height)
}

@(test)
viewer_settings_control_precedes_title_without_overlap_test :: proc(t: ^testing.T) {
	settings := hal_ui.window_control_rect(3, 760)
	title := hal_ui.title_rect(1280, 760, 1280-90-hal_ui.METRICS.gap)
	testing.expect_value(t, settings, framework_draw.Rect{114, 730, 30, 30})
	testing.expect(t, title.x-(settings.x+settings.w) >= 16)
}

@(test)
viewer_header_double_click_toggles_window_zoom_test :: proc(t: ^testing.T) {
	testing.expect(t, !viewer_header_click_should_zoom(1))
	testing.expect(t, viewer_header_click_should_zoom(2))
	testing.expect(t, viewer_header_click_should_zoom(3))
}

@(test)
viewer_window_zoom_geometry_fills_and_restores_test :: proc(t: ^testing.T) {
	current := Rect{Point{200, 140}, Size{1200, 800}}
	visible := Rect{Point{0, 31}, Size{1920, 1049}}
	next, restore, has_restore := viewer_window_zoom_next_frame(current, visible, {}, false)
	testing.expect_value(t, next, visible)
	testing.expect_value(t, restore, current)
	testing.expect(t, has_restore)

	next, restore, has_restore = viewer_window_zoom_next_frame(next, visible, restore, has_restore)
	testing.expect_value(t, next, current)
	testing.expect_value(t, restore, Rect{})
	testing.expect(t, !has_restore)
}

@(test)
viewer_resize_edges_detect_six_point_insets_test :: proc(t: ^testing.T) {
	width, height := 800.0, 600.0
	testing.expect_value(t, viewer_resize_edges({3, 300}, width, height), u8(1))
	testing.expect_value(t, viewer_resize_edges({797, 300}, width, height), u8(2))
	testing.expect_value(t, viewer_resize_edges({400, 2}, width, height), u8(4))
	testing.expect_value(t, viewer_resize_edges({400, 597}, width, height), u8(8))
	testing.expect_value(t, viewer_resize_edges({2, 2}, width, height), u8(5))
	testing.expect_value(t, viewer_resize_edges({400, 300}, width, height), u8(0))
}
