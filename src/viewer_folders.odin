package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import framework_draw "ui_framework:draw"
import framework_metal "ui_framework:metal"
import framework_ui "ui_framework:core"
import hal_ui "ui_framework:hal_wayland"

// FOLDER_BAR_HEIGHT is the fixed strip below the header that holds the source
// chips, the search field, and active-folder management controls.
FOLDER_BAR_HEIGHT :: f32(34)

viewer_folder_items :: proc() -> []Folder_Index_Image {
	if viewer.search_active && viewer.mode == .Folder {
		return viewer.folder_search.folder_images[:]
	}
	return viewer.folder_images.folder_images[:]
}

viewer_selected_folder_image :: proc() -> ^Folder_Index_Image {
	items := viewer_folder_items()
	if viewer.folder_selected < 0 || viewer.folder_selected >= len(items) {return nil}
	return &items[viewer.folder_selected]
}

viewer_reload_folders :: proc() -> bool {
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="folder.list",
	})
	if !exchanged || !response.ok {
		if exchanged {library_service_response_destroy(&response)}
		return false
	}
	library_service_response_destroy(&viewer.roots)
	viewer.roots = response
	viewer.needs_redraw = true
	return true
}

viewer_reload_folder_images :: proc() -> bool {
	if viewer.active_root_id <= 0 {return false}
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="folder.images",
		root_id=viewer.active_root_id,
	})
	if !exchanged || !response.ok {
		if exchanged {library_service_response_destroy(&response)}
		return false
	}
	library_service_response_destroy(&viewer.folder_images)
	viewer.folder_images = response
	viewer.folder_selected = -1
	viewer.needs_redraw = true
	return true
}

viewer_activate_library_source :: proc() {
	viewer.mode = .Library
	viewer.active_root_id = 0
	viewer_clear_search()
	viewer.needs_redraw = true
}

viewer_activate_folder_source :: proc(root_id: i64) {
	if root_id <= 0 {return}
	viewer.mode = .Folder
	viewer.active_root_id = root_id
	viewer_clear_search()
	viewer.needs_redraw = true
}

viewer_add_folder_source :: proc() {
	root_path, bookmark, choose_error := macos_choose_library_root()
	if choose_error != .None {return}
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="folder.add",
		path=root_path,
		bookmark=bookmark,
		recursive=true,
	})
	root_id: i64
	if exchanged && response.ok {
		if parsed, parsed_ok := strconv.parse_i64(response.message); parsed_ok {
			root_id = parsed
		}
		library_service_response_destroy(&response)
	} else {
		if exchanged {
			viewer_set_status(response.message)
			library_service_response_destroy(&response)
		} else {
			viewer_set_status("The library service is unavailable.")
		}
		return
	}
	viewer_reload_folders()
	if root_id > 0 {
		viewer_activate_folder_source(root_id)
		// Drive the incremental scan from the frame timer so a large folder
		// cannot stall the service or the UI; results appear as it runs.
		viewer.scanning_root_id = root_id
		viewer.last_scan_step = time.tick_add(time.tick_now(), -400*time.Millisecond)
		viewer_folder_scan_step()
	}
}

// viewer_folder_scan_step advances the incremental scan for the active root by
// one batch and refreshes folder data as images are indexed.
viewer_folder_scan_step :: proc() {
	if viewer.scanning_root_id <= 0 {return}
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="folder.scan",
		root_id=viewer.scanning_root_id,
	})
	done := false
	if exchanged && response.ok {
		done = response.message == "complete"
		if !done {
			library_service_response_destroy(&response)
			viewer_reload_folder_images()
			viewer.needs_redraw = true
			return
		}
	} else if exchanged {
		library_service_response_destroy(&response)
	}
	viewer.scanning_root_id = 0
	viewer_reload_folder_images()
	viewer_reload_folders()
	viewer_set_status("Folder scan complete.")
	viewer.needs_redraw = true
}

viewer_search_append :: proc(addition: string, maximum: int) {
	if len(addition) == 0 || len(viewer.search_query)+len(addition) > maximum {return}
	next := fmt.aprintf("%s%s", viewer.search_query, addition)
	delete(viewer.search_query)
	viewer.search_query = next
	viewer.needs_redraw = true
}

viewer_search_backspace :: proc() {
	if len(viewer.search_query) == 0 {return}
	end := len(viewer.search_query)-1
	for end > 0 && (viewer.search_query[end] & 0xc0) == 0x80 {end -= 1}
	next := strings.clone(viewer.search_query[:end])
	delete(viewer.search_query)
	viewer.search_query = next
	viewer.needs_redraw = true
}

viewer_commit_search :: proc() {
	if len(viewer.search_query) == 0 {
		viewer_clear_search()
		return
	}
	if viewer.mode == .Folder {
		response, exchanged := library_cli_exchange({
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="folder.search",
			text=viewer.search_query,
		})
		if !exchanged || !response.ok {
			if exchanged {
				viewer_set_status(response.message)
				library_service_response_destroy(&response)
			}
			return
		}
		library_service_response_destroy(&viewer.folder_search)
		viewer.folder_search = response
		viewer.search_active = true
		viewer.folder_selected = -1
	} else {
		response, exchanged := library_cli_exchange({
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.search",
			text=viewer.search_query,
		})
		if !exchanged || !response.ok {
			if exchanged {
				viewer_set_status(response.message)
				library_service_response_destroy(&response)
			}
			return
		}
		library_service_response_destroy(&viewer.captures)
		viewer.captures = response
		viewer.search_active = true
		viewer.selected = -1
	}
	viewer.needs_redraw = true
}

viewer_clear_search :: proc() {
	delete(viewer.search_query)
	viewer.search_query = ""
	viewer.search_active = false
	viewer.search_focused = false
	viewer.folder_selected = -1
	viewer.selected = -1
	if viewer.mode == .Folder && viewer.active_root_id > 0 {
		viewer_reload_folder_images()
	} else {
		_ = viewer_reload_captures()
	}
	viewer.needs_redraw = true
}

viewer_folder_texture_native :: proc(image: ^Folder_Index_Image, maximum_pixels: int) -> ^Viewer_Texture {
	key := fmt.tprintf("f%d-%d", image.image_id, image.modified_unix_ms)
	for &entry in viewer.textures {
		if entry.digest == key && entry.maximum_pixels == maximum_pixels {
			if entry.native != nil || entry.retry_after_ms > library_now_unix_ms() {return &entry}
			if viewer.loads_this_frame >= 1 {return &entry}
			break
		}
	}
	entry_index := -1
	for &entry, index in viewer.textures {
		if entry.digest == key && entry.maximum_pixels == maximum_pixels {
			entry_index = index
			break
		}
	}
	if entry_index < 0 {
		append(&viewer.textures, Viewer_Texture{
			digest=strings.clone(key),
			maximum_pixels=maximum_pixels,
		})
		entry_index = len(viewer.textures)-1
	}
	entry := &viewer.textures[entry_index]
	if viewer.loads_this_frame >= 1 {return entry}
	viewer.loads_this_frame += 1
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="folder.thumbnail",
		root_id=image.root_id,
		image_id=image.image_id,
		maximum_pixels=maximum_pixels,
	})
	if !exchanged || !response.ok {
		entry.retry_after_ms = library_now_unix_ms()+5_000
		if exchanged {library_service_response_destroy(&response)}
		return entry
	}
	native, width, height, loaded := macos_texture_load_file(viewer.device, response.message)
	library_service_response_destroy(&response)
	if !loaded {
		entry.retry_after_ms = library_now_unix_ms()+5_000
		return entry
	}
	entry.native = native
	entry.width = width
	entry.height = height
	viewer.needs_redraw = true
	return entry
}

viewer_folder_bar_rect :: proc() -> framework_draw.Rect {
	grid, _, _, _ := viewer_grid_layout()
	margin := f32(hal_ui.METRICS.margin)
	return {grid.x, grid.y+grid.h+margin, grid.w, FOLDER_BAR_HEIGHT}
}

viewer_add_folder_bar :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	bar := viewer_folder_bar_rect()
	viewer_box(
		frame,
		"folder bar",
		"",
		bar,
		{background=theme.surface, border=theme.border, border_thickness=1, opacity=1},
		{.Draw_Background, .Draw_Border},
	)
	x := bar.x+8
	gap := f32(6)
	chip_height := bar.h-8

	selected := viewer.mode == .Library && !viewer.search_active
	viewer_control(
		frame,
		"source library",
		"show the capture library",
		"LIBRARY",
		{x, bar.y+4, 74, chip_height},
		{kind=.Source_Library},
		hal_ui.control_style(theme, selected ? .Selected : .Idle, .Focus),
	)
	x += 74+gap

	for &root, index in viewer.roots.folders {
		name := filepath.base(root.path)
		width := min(f32(190), max(f32(90), f32(len(name))*7+22))
		selected := viewer.mode == .Folder && viewer.active_root_id == root.root_id
		viewer_control(
			frame,
			fmt.tprintf("source folder %d", index),
			"show this folder's images",
			strings.to_upper(name, context.temp_allocator),
			{x, bar.y+4, width, chip_height},
			{kind=.Source_Folder, root_id=root.root_id},
			hal_ui.control_style(theme, selected ? .Selected : .Idle, .Focus),
		)
		x += width+gap
	}
	viewer_control(
		frame,
		"add folder",
		"add an image folder source",
		"ADD FOLDER",
		{x, bar.y+4, 92, chip_height},
		{kind=.Add_Folder},
		hal_ui.control_style(theme, role=.Positive),
	)

	right := bar.x+bar.w-8
	if viewer.mode == .Folder && viewer.active_root_id > 0 {
		right -= 76
		viewer_control(
			frame,
			"remove folder",
			"remove this folder source",
			"REMOVE",
			{right, bar.y+4, 68, chip_height},
			{kind=.Remove_Folder},
			hal_ui.control_style(theme, role=.Destructive),
		)
		right -= 64
		label := "SCAN"
		if viewer.scanning_root_id == viewer.active_root_id {label = "…"}
		viewer_control(
			frame,
			"scan folder",
			"rescan this folder",
			label,
			{right, bar.y+4, 56, chip_height},
			{kind=.Scan_Folder},
			hal_ui.control_style(theme, viewer.scanning_root_id == viewer.active_root_id ? .Disabled : .Idle),
		)
	}

	search_width := f32(220)
	if right-search_width < x+8 {search_width = max(f32(140), right-x-16)}
	search_rect := framework_draw.Rect{right-search_width, bar.y+4, search_width, chip_height}
	query := viewer.search_query
	if len(query) == 0 {query = "SEARCH  ⌘S"}
	active := viewer.search_focused || len(viewer.search_query) > 0
	search_style := framework_ui.Style{
		background=theme.field,
		border=viewer.search_focused ? theme.focus : theme.border,
		text=active ? theme.text : theme.muted,
		border_thickness=1,
		opacity=1,
		text_style={
			font=VIEWER_FONT,
			size=9,
			tracking=-0.3,
			horizontal=.Start,
			vertical=.Center,
			inset=8,
			truncate=true,
		},
	}
	viewer_control(
		frame,
		"search field",
		"search the active source",
		query,
		search_rect,
		{kind=.Focus_Search},
		search_style,
	)
	if viewer.search_active {
	viewer_control(
		frame,
		"clear search",
		"clear the active search",
		"×",
		{right-search_width-26, bar.y+4, 22, chip_height},
		{kind=.Clear_Search},
		hal_ui.control_style(theme),
	)
	}
}

viewer_add_folder_grid :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	grid, columns, tile_width, tile_height := viewer_grid_layout()
	viewer_box(frame, "folder grid background", "", grid, {background=theme.canvas, opacity=1}, {.Draw_Background, .Clip})
	items := viewer_folder_items()
	row_count := (len(items)+columns-1)/columns
	content_height := f32(row_count)*tile_height+f32(max(0, row_count-1))*8
	maximum_scroll := max(f32(0), content_height-grid.h)
	viewer.grid_scroll = min(max(viewer.grid_scroll, 0), maximum_scroll)
	for &image, index in items {
		row, column := index/columns, index%columns
		x := grid.x+f32(column)*(tile_width+8)
		y := grid.y+grid.h-tile_height-f32(row)*(tile_height+8)+viewer.grid_scroll
		rect := framework_draw.Rect{x, y, tile_width, tile_height}
		if rect.y+rect.h < grid.y || rect.y > grid.y+grid.h {continue}
		selected := index == viewer.folder_selected
		style := hal_ui.control_style(theme, selected ? .Selected : .Idle, .Primary)
		style.background = theme.surface
		name := filepath.base(image.path)
		viewer_control(
			frame,
			fmt.tprintf("folder image %d", image.image_id),
			fmt.tprintf("select %s", name),
			"",
			rect,
			{kind=.Select_Folder_Image, index=index},
			style,
		)
		image_area := framework_draw.Rect{rect.x+5, rect.y+28, rect.w-10, rect.h-33}
		entry := viewer_folder_texture_native(&image, 384)
		if entry != nil && entry.native != nil {
			handle := framework_metal.register_texture(&viewer.renderer, entry.native)
			viewer_image_box(
				frame,
				fmt.tprintf("folder image texture %d", image.image_id),
				viewer_aspect_fit(image_area, entry.width, entry.height),
				handle,
			)
		} else {
			viewer_add_text(
				frame,
				fmt.tprintf("folder image pending %d", image.image_id),
				"LOADING",
				image_area,
				theme.muted,
				9,
				.Center,
			)
		}
		viewer_add_text(
			frame,
			fmt.tprintf("folder image title %d", image.image_id),
			name,
			{rect.x+3, rect.y+3, rect.w-6, 22},
			theme.text,
			10,
		)
	}
}

viewer_add_folder_detail :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	panel := viewer_detail_rect()
	viewer_box(frame, "folder detail panel", "", panel, hal_ui.panel_style(theme, true), {.Draw_Background, .Clip})
	image := viewer_selected_folder_image()
	if image == nil {
		viewer_add_text(frame, "folder detail empty", "SELECT AN IMAGE", panel, theme.muted, 11, .Center)
		return
	}
	action_y := panel.y+10
	button_gap := f32(5)
	button_width := (panel.w-28-button_gap*3)/4
	actions := [4]Viewer_Action_Kind{.Open_In_Finder, .Copy_Image, .Copy_To_Folder, .Export_Folder_Image}
	texts := [4]string{"FINDER", "COPY", "COPY TO…", "EXPORT"}
	for index in 0..<4 {
		button_rect := framework_draw.Rect{
			panel.x+14+f32(index)*(button_width+button_gap),
			action_y,
			button_width,
			28,
		}
		viewer_control(
			frame,
			fmt.tprintf("folder detail action %d", index),
			strings.to_lower(texts[index], context.temp_allocator),
			texts[index],
			button_rect,
			{kind=actions[index]},
			hal_ui.control_style(theme),
		)
	}
	image_area := framework_draw.Rect{panel.x+14, panel.y+205, panel.w-28, panel.h-230}
	if image_area.h > 90 {
		entry := viewer_folder_texture_native(image, 2048)
		if entry != nil && entry.native != nil {
			handle := framework_metal.register_texture(&viewer.renderer, entry.native)
			viewer_image_box(frame, "folder detail image", viewer_aspect_fit(image_area, entry.width, entry.height), handle)
		} else {
			viewer_add_text(frame, "folder detail image pending", "LOADING", image_area, theme.muted, 10, .Center)
		}
	}
	cursor := panel.y+190
	viewer_detail_field(frame, theme, "folder detail path", "PATH", image.path, panel, &cursor)
	viewer_detail_field(frame, theme, "folder detail media", "MEDIA", image.media_type, panel, &cursor)
	if image.pixel_width > 0 {
		viewer_detail_field(
			frame,
			theme,
			"folder detail dimensions",
			"DIMENSIONS",
			fmt.tprintf("%d × %d", image.pixel_width, image.pixel_height),
			panel,
			&cursor,
		)
	}
	viewer_detail_field(
		frame,
		theme,
		"folder detail size",
		"SIZE",
		fmt.tprintf("%d BYTES", image.size_bytes),
		panel,
		&cursor,
	)
	if len(image.tags) > 0 {
		viewer_detail_field(frame, theme, "folder detail tags", "TAGS", image.tags, panel, &cursor)
	}
	if len(image.generated_tags) > 0 {
		viewer_detail_field(frame, theme, "folder detail generated tags", "GENERATED", image.generated_tags, panel, &cursor)
	}
}

viewer_copy_selected_to_folder :: proc() {
	image := viewer_selected_folder_image()
	if image == nil {return}
	destination, _, choose_error := macos_choose_library_root()
	if choose_error != .None {return}
	name := filepath.base(image.path)
	dest_path, joined_error := filepath.join([]string{destination, name}, context.temp_allocator)
	if joined_error != nil {return}
	if os.exists(dest_path) {
		viewer_set_status("A file with that name already exists in the destination.")
		return
	}
	if copy_error := os.copy_file(dest_path, image.path); copy_error != nil {
		viewer_set_status("The image could not be copied to the destination.")
		return
	}
	viewer_set_status(dest_path)
}

viewer_copy_selected_image :: proc() {
	image := viewer_selected_folder_image()
	if image == nil {return}
	if !objc_initialize() {return}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return}
	defer macos_autorelease_pool_end(pool)
	image_obj := msg_id_id(
		msg_id(objc_getClass("NSImage"), sel_registerName("alloc")),
		sel_registerName("initWithContentsOfFile:"),
		nsstring(image.path),
	)
	if image_obj == nil {
		viewer_set_status("The image could not be loaded for the clipboard.")
		return
	}
	defer msg_void(image_obj, sel_registerName("release"))
	tiff := msg_id(image_obj, sel_registerName("TIFFRepresentation"))
	if tiff == nil {
		viewer_set_status("The clipboard image data could not be created.")
		return
	}
	pasteboard := msg_id(objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"))
	_ = msg_bool(pasteboard, sel_registerName("clearContents"))
	_ = msg_bool_id_id(pasteboard, sel_registerName("setData:forType:"), tiff, nsstring("public.tiff"))
	viewer_set_status("The image was copied to the clipboard.")
}

viewer_reveal_selected_in_finder :: proc() {
	image := viewer_selected_folder_image()
	if image == nil {return}
	if !objc_initialize() {return}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return}
	defer macos_autorelease_pool_end(pool)
	workspace := msg_id(objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"))
	array := msg_id_id(objc_getClass("NSArray"), sel_registerName("arrayWithObject:"), nsurl_file(image.path))
	_ = msg_bool_id(workspace, sel_registerName("activateFileViewerSelectingURLs:"), array)
	viewer_set_status("The image was revealed in Finder.")
}

viewer_export_selected_folder_image :: proc() {
	image := viewer_selected_folder_image()
	if image == nil {return}
	path, choose_error := macos_choose_export_path(filepath.base(image.path))
	if choose_error != .None {return}
	if os.exists(path) {
		viewer_set_status("A file with that name already exists.")
		return
	}
	if copy_error := os.copy_file(path, image.path); copy_error != nil {
		viewer_set_status("The image could not be exported.")
		return
	}
	viewer_set_status(path)
}
