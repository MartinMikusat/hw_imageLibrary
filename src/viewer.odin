package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import command_palette "command_palette:."
import flash "flash:."
import framework_coretext "ui_framework:coretext"
import framework_draw "ui_framework:draw"
import framework_macos "ui_framework:macos"
import framework_metal "ui_framework:metal"
import framework_ui "ui_framework:core"
import hal_ui "ui_framework:hal_wayland"

foreign import viewer_metal "system:Metal.framework"
foreign viewer_metal {
	MTLCreateSystemDefaultDevice :: proc "c" () -> Id ---
}

Viewer_Clear_Color :: struct {red, green, blue, alpha: f64}

viewer_msg_void_clear_color :: proc(receiver: Id, selector: Sel, color: Viewer_Clear_Color) {
	p := transmute(proc "c" (Id, Sel, Viewer_Clear_Color))objc_send_address
	p(receiver, selector, color)
}

Viewer_Action_Kind :: enum {
	None,
	Window_Close,
	Window_Minimize,
	Window_Zoom,
	Refresh,
	Open_Settings,
	Close_Modal,
	Choose_Folder,
	Choose_Move,
	Select_Capture,
	Open_Source,
	Export,
	Delete_Restore,
	Download,
	Edit_Note,
	Save_Note,
	Authorize_Device,
	Retire_Device,
	Purge_Object,
	Confirm_Destructive,
	Set_Theme,
	Command_Palette,
	Command_Result,
	Source_Library,
	Source_Folder,
	Add_Folder,
	Scan_Folder,
	Remove_Folder,
	Select_Folder_Image,
	Copy_To_Folder,
	Copy_Image,
	Open_In_Finder,
	Export_Folder_Image,
	Focus_Search,
	Clear_Search,
}

Viewer_Action :: struct {
	kind:   Viewer_Action_Kind,
	index:  int,
	root_id: i64,
}

Viewer_Action_Binding :: struct {
	id:     framework_ui.Action_ID,
	action: Viewer_Action,
}

Viewer_AX_Binding :: struct {
	element:    Id,
	control_id: framework_ui.Key,
}

Viewer_Texture :: struct {
	digest:          string,
	maximum_pixels:  int,
	native:          Id,
	width, height:   int,
	retry_after_ms:  i64,
}

Viewer_Modal :: enum {
	None,
	Settings,
	Note,
	Command_Palette,
	Confirm,
}

Viewer_Confirmation_Kind :: enum {
	None,
	Retire_Device,
	Purge_Object,
	Move_Library,
}

Viewer_Source_Mode :: enum {
	Library,
	Folder,
}

Viewer_State :: struct {
	app, window, view, delegate: Id,
	device, queue, layer:        Id,
	frame_timer:                 framework_macos.Frame_Timer,
	renderer:                    framework_metal.Renderer,
	text:                        framework_coretext.Context,
	controls:                    framework_ui.Context,
	registry:                    framework_ui.Registry_View,
	bindings:                    [dynamic]Viewer_Action_Binding,
	ax_bindings:                 [dynamic]Viewer_AX_Binding,
	ax_children:                 Id,
	textures:                    [dynamic]Viewer_Texture,
	captures:                    Library_Service_Response,
	devices:                     Library_Service_Response,
	purges:                      Library_Service_Response,
	roots:                       Library_Service_Response,
	folder_images:               Library_Service_Response,
	folder_search:               Library_Service_Response,
	settings:                    Local_Settings,
	settings_loaded:             bool,
	palette:                     command_palette.State,
	flash:                       flash.State,
	width, height, scale:        f64,
	grid_scroll:                 f32,
	selected:                    int,
	mode:                        Viewer_Source_Mode,
	active_root_id:              i64,
	folder_selected:             int,
	scanning_root_id:            i64,
	last_scan_step:              time.Tick,
	search_query:                string,
	search_focused:              bool,
	search_active:               bool,
	modal:                       Viewer_Modal,
	note_buffer:                 string,
	confirmation_kind:           Viewer_Confirmation_Kind,
	confirmation_value:          string,
	confirmation_buffer:         string,
	status:                      string,
	needs_redraw:                bool,
	last_reload:                 time.Tick,
	reload_started:              bool,
	reload_failed:               bool,
	loads_this_frame:            int,
}

viewer: Viewer_State

VIEWER_DEFAULT_WIDTH :: 1280.0
VIEWER_DEFAULT_HEIGHT :: 780.0
VIEWER_MIN_WIDTH :: 760.0
VIEWER_MIN_HEIGHT :: 520.0
VIEWER_WINDOW_STYLE :: uint(14)
VIEWER_HEADER_HEIGHT :: f32(hal_ui.METRICS.header_height)
VIEWER_STATUS_HEIGHT :: f32(26)
VIEWER_FONT :: framework_ui.Font_Handle(1)
VIEWER_COMMAND_MODIFIER :: uint(1 << 20)

viewer_set_status :: proc(value: string) {
	delete(viewer.status)
	viewer.status = strings.clone(value)
	viewer.needs_redraw = true
}

viewer_theme :: proc() -> hal_ui.Palette {
	if viewer.settings_loaded && viewer.settings.interface_theme == "hw-dark" {
		return hal_ui.palette(.HW_Dark)
	}
	return hal_ui.palette(.HW_Light)
}

viewer_selected_capture :: proc() -> ^Library_Index_Capture {
	if viewer.selected < 0 || viewer.selected >= len(viewer.captures.captures) {return nil}
	return &viewer.captures.captures[viewer.selected]
}

viewer_object_state_label :: proc(state: Library_Object_State) -> string {
	switch state {
	case .Available: return "LOADING"
	case .Unavailable: return "IN ICLOUD"
	case .Missing: return "MISSING"
	case .Corrupt: return "CORRUPT"
	case .Purged: return "PURGED"
	}
	return "UNAVAILABLE"
}

viewer_reload_captures :: proc() -> bool {
	selected_id := ""
	if selected := viewer_selected_capture(); selected != nil {
		selected_id = strings.clone(selected.capture_id, context.temp_allocator)
	}
	response, exchanged := library_cli_exchange(
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.list",
			include_deleted=true,
		},
	)
	if !exchanged || !response.ok {
		if exchanged {
			viewer_set_status(response.message)
			library_service_response_destroy(&response)
		} else {
			viewer_set_status("The library service is unavailable.")
		}
		viewer.last_reload = time.tick_now()
		viewer.reload_started = true
		viewer.reload_failed = true
		return false
	}
	library_service_response_destroy(&viewer.captures)
	viewer.captures = response
	viewer.selected = -1
	if len(selected_id) > 0 {
		for capture, index in viewer.captures.captures {
			if capture.capture_id == selected_id {viewer.selected = index; break}
		}
	}
	if viewer.selected < 0 && len(viewer.captures.captures) > 0 {viewer.selected = 0}
	viewer.last_reload = time.tick_now()
	viewer.reload_started = true
	viewer.reload_failed = false
	viewer.needs_redraw = true
	return true
}

viewer_reload_settings :: proc() {
	if viewer.settings_loaded {
		local_settings_destroy(&viewer.settings)
		viewer.settings_loaded = false
	}
	settings, settings_error := local_settings_load()
	if settings_error == .None {
		viewer.settings = settings
		viewer.settings_loaded = true
	}
	library_service_response_destroy(&viewer.devices)
	library_service_response_destroy(&viewer.purges)
	if !viewer.settings_loaded {return}
	devices, devices_ok := library_cli_exchange(
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="library.devices"},
	)
	if devices_ok {viewer.devices = devices}
	purges, purges_ok := library_cli_exchange(
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="library.purge-status"},
	)
	if purges_ok {viewer.purges = purges}
}

viewer_prepare_default_library :: proc() {
	settings, settings_error := local_settings_load(context.temp_allocator)
	if settings_error == .None {return}
	if settings_error != .Not_Found {return}
	root_path, path_error := library_icloud_root_off_main()
	if path_error != .None {return}
	defer delete(root_path)
	response := library_cli_configure_root(root_path, LOCAL_SETTINGS_MODE_ICLOUD, "")
	if !response.ok {viewer_set_status(response.message)}
}

viewer_extension_for_media_type :: proc(media_type: string) -> string {
	switch media_type {
	case "image/avif": return "avif"
	case "image/gif": return "gif"
	case "image/jpeg": return "jpg"
	case "image/png": return "png"
	case "image/webp": return "webp"
	}
	return "img"
}

viewer_mutation :: proc(request: Library_Service_Request, reload := true) -> bool {
	response, exchanged := library_cli_exchange(request)
	if !exchanged {
		viewer_set_status("The library service is unavailable.")
		return false
	}
	success := response.ok
	if success {viewer_set_status(response.message)} else {viewer_set_status(response.message)}
	library_service_response_destroy(&response)
	if success && reload {_ = viewer_reload_captures()}
	return success
}

viewer_open_command_palette :: proc() {
	entries := []command_palette.Entry{
		{id=1, title="Refresh library", category="LIBRARY"},
		{id=2, title="Open settings", category="LIBRARY"},
		{id=3, title="Open source page", category="CAPTURE"},
		{id=4, title="Export original", category="CAPTURE"},
		{id=5, title="Edit note", category="CAPTURE"},
		{id=6, title="Delete or restore", category="CAPTURE"},
	}
	if command_palette.open(&viewer.palette, entries, 0) == .None {
		viewer.modal = .Command_Palette
		viewer.needs_redraw = true
	}
}

viewer_begin_flash :: proc() {
	targets := make([dynamic]flash.Target, 0, len(viewer.registry.controls), context.temp_allocator)
	for &control in viewer.registry.controls {
		if .Flash not_in control.capabilities || !control.enabled {continue}
		append(&targets, flash.Target{
			id=flash.Target_ID(control.id),
			label=control.flash_label,
			rect={f64(control.rect.x), f64(control.rect.y), f64(control.rect.w), f64(control.rect.h)},
			anchor=.Top_Left,
		})
	}
	_ = flash.begin(&viewer.flash, targets[:])
	viewer.needs_redraw = true
}

viewer_activate_flash_target :: proc(id: flash.Target_ID) {
	activation, activated := framework_ui.activate_control_in_view(
		viewer.registry,
		framework_ui.Key(id),
		.Flash,
	)
	if !activated {return}
	if binding := viewer_binding_for_id(activation.action); binding != nil {
		viewer_execute_action(binding.action)
	}
}

viewer_execute_command :: proc(id: command_palette.Entry_ID) {
	switch id {
	case 1: _ = viewer_reload_captures()
	case 2: viewer.modal = .Settings; viewer_reload_settings()
	case 3: viewer_execute_action({kind=.Open_Source})
	case 4: viewer_execute_action({kind=.Export})
	case 5: viewer_execute_action({kind=.Edit_Note})
	case 6: viewer_execute_action({kind=.Delete_Restore})
	}
}

viewer_execute_action :: proc(action: Viewer_Action) {
	switch action.kind {
	case .Window_Close:
		msg_void_id(viewer.window, sel_registerName("performClose:"), nil)
	case .Window_Minimize:
		msg_void_id(viewer.window, sel_registerName("miniaturize:"), nil)
	case .Window_Zoom:
		msg_void_id(viewer.window, sel_registerName("zoom:"), nil)
	case .Refresh:
		_ = viewer_reload_captures()
	case .Open_Settings:
		viewer.modal = .Settings
		viewer_reload_settings()
		viewer.needs_redraw = true
	case .Close_Modal:
		command_palette.close(&viewer.palette)
		viewer.modal = .None
		delete(viewer.note_buffer)
		viewer.note_buffer = ""
		delete(viewer.confirmation_value)
		viewer.confirmation_value = ""
		delete(viewer.confirmation_buffer)
		viewer.confirmation_buffer = ""
		viewer.confirmation_kind = .None
		viewer.needs_redraw = true
	case .Choose_Folder:
		root_path, bookmark, choose_error := macos_choose_library_root()
		if choose_error == .None {
			response := library_cli_rebind_root(root_path, bookmark) if viewer.settings_loaded else
			            library_cli_configure_root(
				            root_path,
				            LOCAL_SETTINGS_MODE_BOOKMARK,
				            bookmark,
			            )
			if response.ok {
				viewer_set_status("The library folder is configured.")
				_ = viewer_reload_captures()
				viewer_reload_settings()
			} else {
				viewer_set_status(response.message)
			}
		}
	case .Choose_Move:
		destination, choose_error := macos_choose_library_move_destination()
		if choose_error == .None {
			delete(viewer.confirmation_value)
			viewer.confirmation_value = destination
			delete(viewer.confirmation_buffer)
			viewer.confirmation_buffer = ""
			viewer.confirmation_kind = .Move_Library
			viewer.modal = .Confirm
			viewer.needs_redraw = true
		}
	case .Select_Capture:
		if action.index >= 0 && action.index < len(viewer.captures.captures) {
			viewer.selected = action.index
			viewer.needs_redraw = true
		}
	case .Open_Source:
		if capture := viewer_selected_capture(); capture != nil {
			if macos_open_url(capture.page_url) {
				viewer_set_status(capture.page_url)
			} else {
				viewer_set_status("The recorded source URL could not be opened.")
			}
		}
	case .Export:
		if capture := viewer_selected_capture(); capture != nil {
			suggested := fmt.tprintf(
				"%s.%s",
				capture.capture_id,
				viewer_extension_for_media_type(capture.media_type),
			)
			path, choose_error := macos_choose_export_path(suggested)
			if choose_error == .None {
				_ = viewer_mutation({
					protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
					command="capture.export",
					capture_id=capture.capture_id,
					path=path,
				}, false)
			}
		}
	case .Delete_Restore:
		if capture := viewer_selected_capture(); capture != nil {
			if capture.deleted && capture.object_state != .Available {
				viewer_set_status("The recovery bytes are no longer available, so this capture cannot be restored.")
				return
			}
			command := "capture.delete"
			if capture.deleted {command = "capture.restore"}
			_ = viewer_mutation({
				protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
				command=command,
				capture_id=capture.capture_id,
			})
		}
	case .Download:
		if capture := viewer_selected_capture(); capture != nil {
			_ = viewer_mutation({
				protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
				command="capture.download",
				capture_id=capture.capture_id,
			}, false)
		}
	case .Edit_Note:
		if capture := viewer_selected_capture(); capture != nil {
			delete(viewer.note_buffer)
			viewer.note_buffer = strings.clone(capture.note)
			viewer.modal = .Note
			viewer.needs_redraw = true
		}
	case .Save_Note:
		if capture := viewer_selected_capture(); capture != nil {
			if viewer_mutation({
				protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
				command="capture.note-set",
				capture_id=capture.capture_id,
				text=viewer.note_buffer,
			}) {
				viewer.modal = .None
			}
		}
	case .Authorize_Device:
		if action.index >= 0 && action.index < len(viewer.devices.devices) {
			device := &viewer.devices.devices[action.index]
			if viewer_mutation({
				protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
				command="library.device-authorize",
				device_id=device.device_id,
			}, false) {
				viewer_reload_settings()
			}
		}
	case .Retire_Device:
		if action.index >= 0 && action.index < len(viewer.devices.devices) {
			device := &viewer.devices.devices[action.index]
			delete(viewer.confirmation_value)
			viewer.confirmation_value = strings.clone(device.device_id)
			delete(viewer.confirmation_buffer)
			viewer.confirmation_buffer = ""
			viewer.confirmation_kind = .Retire_Device
			viewer.modal = .Confirm
			viewer.needs_redraw = true
		}
	case .Purge_Object:
		if action.index >= 0 && action.index < len(viewer.purges.purges) {
			purge := &viewer.purges.purges[action.index]
			delete(viewer.confirmation_value)
			viewer.confirmation_value = strings.clone(purge.object_digest)
			delete(viewer.confirmation_buffer)
			viewer.confirmation_buffer = ""
			viewer.confirmation_kind = .Purge_Object
			viewer.modal = .Confirm
			viewer.needs_redraw = true
		}
	case .Confirm_Destructive:
		if viewer.confirmation_buffer != viewer.confirmation_value {
			viewer_set_status("The confirmation text does not match.")
			return
		}
		request := Library_Service_Request{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			confirmation=viewer.confirmation_value,
		}
		if viewer.confirmation_kind == .Retire_Device {
			request.command = "library.device-retire"
			request.device_id = viewer.confirmation_value
		} else if viewer.confirmation_kind == .Purge_Object {
			request.command = "library.purge"
			request.object_digest = viewer.confirmation_value
		} else if viewer.confirmation_kind == .Move_Library {
			request.command = "library.move"
			request.path = viewer.confirmation_value
		} else {
			return
		}
		if viewer_mutation(request, false) {
			viewer.modal = .Settings
			viewer_reload_settings()
			_ = viewer_reload_captures()
		}
	case .Set_Theme:
		value := "hw-light"
		if action.index == 1 {value = "hw-dark"}
		if viewer_mutation({
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="settings.theme-set",
			text=value,
		}, false) {
			viewer_reload_settings()
			viewer.needs_redraw = true
		}
	case .Command_Palette:
		viewer_open_command_palette()
	case .Command_Result:
		if id, activated := command_palette.activate_result(&viewer.palette, action.index); activated {
			viewer.modal = .None
			viewer_execute_command(id)
		}
	case .Source_Library:
		viewer_activate_library_source()
	case .Source_Folder:
		viewer_activate_folder_source(action.root_id)
	case .Add_Folder:
		viewer_add_folder_source()
	case .Scan_Folder:
		if viewer.active_root_id > 0 {
			viewer.scanning_root_id = viewer.active_root_id
			viewer.last_scan_step = time.tick_add(time.tick_now(), -400*time.Millisecond)
			viewer_folder_scan_step()
			viewer.needs_redraw = true
		}
	case .Remove_Folder:
		if viewer.active_root_id > 0 {
			if viewer_mutation({
				protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
				command="folder.remove",
				root_id=viewer.active_root_id,
			}, false) {
				viewer.active_root_id = 0
				viewer.mode = .Library
				viewer_reload_folders()
				_ = viewer_reload_captures()
			}
		}
	case .Select_Folder_Image:
		if action.index >= 0 && action.index < len(viewer_folder_items()) {
			viewer.folder_selected = action.index
			viewer.needs_redraw = true
		}
	case .Copy_To_Folder:
		viewer_copy_selected_to_folder()
	case .Copy_Image:
		viewer_copy_selected_image()
	case .Open_In_Finder:
		viewer_reveal_selected_in_finder()
	case .Export_Folder_Image:
		viewer_export_selected_folder_image()
	case .Focus_Search:
		viewer.search_focused = true
		viewer.needs_redraw = true
	case .Clear_Search:
		viewer_clear_search()
	case .None:
	}
}

viewer_binding_for_id :: proc(id: framework_ui.Action_ID) -> ^Viewer_Action_Binding {
	for &binding in viewer.bindings {if binding.id == id {return &binding}}
	return nil
}

viewer_control_for_key :: proc(key: framework_ui.Key) -> ^framework_ui.Control_Record {
	return framework_ui.control_in_view(viewer.registry, key)
}

viewer_ax_control :: proc(element: Id) -> ^framework_ui.Control_Record {
	for binding in viewer.ax_bindings {
		if binding.element == element {return viewer_control_for_key(binding.control_id)}
	}
	return nil
}

viewer_on_ax_press :: proc "c" (self: Id, command: Sel) -> bool {
	context = runtime.default_context()
	control := viewer_ax_control(self)
	if control == nil {return false}
	activation, activated := framework_ui.activate_control_in_view(
		viewer.registry,
		control.id,
		.Accessibility,
	)
	if !activated {return false}
	if binding := viewer_binding_for_id(activation.action); binding != nil {
		viewer_execute_action(binding.action)
		return true
	}
	return false
}

viewer_on_ax_children :: proc "c" (self: Id, command: Sel) -> Id {
	return viewer.ax_children
}

viewer_on_ax_is_element :: proc "c" (self: Id, command: Sel) -> bool {
	return false
}

viewer_ax_screen_rect :: proc(rect: framework_draw.Rect) -> Rect {
	view_rect := Rect{{f64(rect.x), f64(rect.y)}, {f64(rect.w), f64(rect.h)}}
	window_rect := msg_rect_rect_id(
		viewer.view,
		sel_registerName("convertRect:toView:"),
		view_rect,
		nil,
	)
	return msg_rect_rect(
		viewer.window,
		sel_registerName("convertRectToScreen:"),
		window_rect,
	)
}

viewer_rebuild_accessibility :: proc() {
	clear(&viewer.ax_bindings)
	if viewer.ax_children != nil {msg_void(viewer.ax_children, sel_registerName("release"))}
	array := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
	viewer.ax_children = msg_id(array, sel_registerName("retain"))
	element_class := objc_getClass("hw_gallery_AccessibilityElement")
	for &control in viewer.registry.controls {
		if .Accessibility not_in control.capabilities {continue}
		element := msg_id(element_class, sel_registerName("new"))
		msg_void_id(element, sel_registerName("setAccessibilityParent:"), viewer.view)
		msg_void_id(element, sel_registerName("setAccessibilityRole:"), nsstring("AXButton"))
		msg_void_id(element, sel_registerName("setAccessibilityLabel:"), nsstring(control.accessibility_label))
		msg_void_bool(element, sel_registerName("setAccessibilityEnabled:"), control.enabled)
		msg_void_rect(element, sel_registerName("setAccessibilityFrame:"), viewer_ax_screen_rect(control.rect))
		msg_void_id(array, sel_registerName("addObject:"), element)
		append(&viewer.ax_bindings, Viewer_AX_Binding{element=element, control_id=control.id})
		msg_void(element, sel_registerName("release"))
	}
}

viewer_control :: proc(
	frame: ^framework_ui.Frame,
	name, label, text: string,
	rect: framework_draw.Rect,
	action: Viewer_Action,
	style: framework_ui.Style,
	enabled := true,
	layer := framework_ui.Layer.Base,
) {
	id := framework_ui.action_id_from_string(name)
	framework_ui.register_action(frame, {
		id=id,
		functional_name=name,
		label=label,
		enabled=enabled,
	})
	append(&viewer.bindings, Viewer_Action_Binding{id=id, action=action})
	flags := framework_ui.Box_Flags{
		.Draw_Background,
		.Draw_Text,
		.Interactive,
	}
	if style.border_thickness > 0 {flags += {.Draw_Border}}
	if !enabled {flags += {.Disabled}}
	_ = framework_ui.box_add(frame, {
		key=framework_ui.Key(id),
		layout={position=.Absolute, absolute=rect},
		style=style,
		flags=flags,
		layer=layer,
		text=text,
		control={
			functional_name=name,
			accessibility_label=label,
			accessibility_role=.Button,
			flash_label=label,
			flash_anchor=.Top_Left,
			capabilities={.Hover, .Primary_Press, .Accessibility, .Flash, .Command_Menu, .CLI},
			action=id,
		},
	})
}

viewer_box :: proc(
	frame: ^framework_ui.Frame,
	name, text: string,
	rect: framework_draw.Rect,
	style: framework_ui.Style,
	flags: framework_ui.Box_Flags,
	layer := framework_ui.Layer.Base,
) {
	_ = framework_ui.box_add(frame, {
		key=framework_ui.key_from_string(name),
		layout={position=.Absolute, absolute=rect},
		style=style,
		flags=flags,
		layer=layer,
		text=text,
	})
}

viewer_image_box :: proc(
	frame: ^framework_ui.Frame,
	name: string,
	rect: framework_draw.Rect,
	texture: framework_draw.Texture_Handle,
	layer := framework_ui.Layer.Base,
) {
	if texture == framework_draw.Texture_Handle(0) {return}
	_ = framework_ui.box_add(frame, {
		key=framework_ui.key_from_string(name),
		layout={position=.Absolute, absolute=rect},
		flags={.Draw_Image},
		layer=layer,
		texture=texture,
		texture_src={0, 1, 1, -1},
	})
}

viewer_texture_native :: proc(
	capture: ^Library_Index_Capture,
	maximum_pixels: int,
) -> ^Viewer_Texture {
	for &entry in viewer.textures {
		if entry.digest == capture.object_digest && entry.maximum_pixels == maximum_pixels {
			if entry.native != nil || entry.retry_after_ms > library_now_unix_ms() {return &entry}
			if viewer.loads_this_frame >= 1 {return &entry}
			break
		}
	}
	entry_index := -1
	for &entry, index in viewer.textures {
		if entry.digest == capture.object_digest && entry.maximum_pixels == maximum_pixels {
			entry_index = index
			break
		}
	}
	if entry_index < 0 {
		append(&viewer.textures, Viewer_Texture{
			digest=strings.clone(capture.object_digest),
			maximum_pixels=maximum_pixels,
		})
		entry_index = len(viewer.textures)-1
	}
	entry := &viewer.textures[entry_index]
	if viewer.loads_this_frame >= 1 {return entry}
	viewer.loads_this_frame += 1
	response, exchanged := library_cli_exchange({
		protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
		command="capture.thumbnail",
		capture_id=capture.capture_id,
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

viewer_aspect_fit :: proc(rect: framework_draw.Rect, width, height: int) -> framework_draw.Rect {
	if width <= 0 || height <= 0 || rect.w <= 0 || rect.h <= 0 {return rect}
	scale := min(rect.w/f32(width), rect.h/f32(height))
	w, h := f32(width)*scale, f32(height)*scale
	return {rect.x+(rect.w-w)/2, rect.y+(rect.h-h)/2, w, h}
}

viewer_add_text :: proc(
	frame: ^framework_ui.Frame,
	name, text: string,
	rect: framework_draw.Rect,
	color: framework_draw.Color,
	size := f32(hal_ui.METRICS.base_font),
	horizontal := framework_ui.Text_Align.Start,
	layer := framework_ui.Layer.Base,
) {
	style := framework_ui.Style{
		text=color,
		opacity=1,
		text_style={
			font=VIEWER_FONT,
			size=size,
			tracking=-0.45,
			horizontal=horizontal,
			vertical=.Center,
			inset=5,
			truncate=true,
		},
	}
	viewer_box(frame, name, text, rect, style, {.Draw_Text}, layer)
}

viewer_add_header :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	header := hal_ui.header_rect(f32(viewer.width), f32(viewer.height))
	viewer_box(frame, "header background", "", header, {background=theme.header, opacity=1}, {.Draw_Background})
	labels := [3]string{"×", "−", "□"}
	names := [3]string{"window close", "window minimize", "window zoom"}
	actions := [3]Viewer_Action_Kind{.Window_Close, .Window_Minimize, .Window_Zoom}
	for index in 0..<3 {
		viewer_control(
			frame,
			names[index],
			names[index],
			labels[index],
			hal_ui.window_control_rect(index, f32(viewer.height)),
			{kind=actions[index]},
			hal_ui.control_style(theme),
		)
	}
	viewer_add_text(
		frame,
		"window title",
		"IMAGE LIBRARY",
		hal_ui.title_rect(f32(viewer.width), f32(viewer.height), f32(viewer.width)-190),
		theme.text,
		12,
	)
	viewer_control(
		frame,
		"refresh",
		"refresh library",
		"REFRESH",
		{f32(viewer.width)-180, f32(viewer.height)-32, 80, 26},
		{kind=.Refresh},
		hal_ui.control_style(theme),
	)
	viewer_control(
		frame,
		"settings",
		"library settings",
		"SETTINGS",
		{f32(viewer.width)-94, f32(viewer.height)-32, 88, 26},
		{kind=.Open_Settings},
		hal_ui.control_style(theme),
	)
}

viewer_grid_layout :: proc() -> (rect: framework_draw.Rect, columns: int, tile_width, tile_height: f32) {
	margin := f32(hal_ui.METRICS.margin)
	detail_width := max(f32(360), f32(viewer.width)*0.42)
	rect = {
		margin,
		VIEWER_STATUS_HEIGHT+margin,
		f32(viewer.width)-detail_width-margin*3,
		f32(viewer.height)-VIEWER_HEADER_HEIGHT-VIEWER_STATUS_HEIGHT-FOLDER_BAR_HEIGHT-margin*2,
	}
	columns = max(1, int((rect.w+8)/174))
	tile_width = (rect.w-f32(columns-1)*8)/f32(columns)
	tile_height = 154
	return
}

viewer_add_grid :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	grid, columns, tile_width, tile_height := viewer_grid_layout()
	viewer_box(frame, "grid background", "", grid, {background=theme.canvas, opacity=1}, {.Draw_Background, .Clip})
	row_count := (len(viewer.captures.captures)+columns-1)/columns
	content_height := f32(row_count)*tile_height+f32(max(0, row_count-1))*8
	maximum_scroll := max(f32(0), content_height-grid.h)
	viewer.grid_scroll = min(max(viewer.grid_scroll, 0), maximum_scroll)
	for &capture, index in viewer.captures.captures {
		row, column := index/columns, index%columns
		x := grid.x+f32(column)*(tile_width+8)
		y := grid.y+grid.h-tile_height-f32(row)*(tile_height+8)+viewer.grid_scroll
		rect := framework_draw.Rect{x, y, tile_width, tile_height}
		if rect.y+rect.h < grid.y || rect.y > grid.y+grid.h {continue}
		selected := index == viewer.selected
		style := hal_ui.control_style(theme, selected ? .Selected : .Idle, .Primary)
		style.background = theme.surface
		viewer_control(
			frame,
			fmt.tprintf("capture %s", capture.capture_id),
			fmt.tprintf("select %s", capture.page_title),
			"",
			rect,
			{kind=.Select_Capture, index=index},
			style,
		)
		image_area := framework_draw.Rect{rect.x+5, rect.y+28, rect.w-10, rect.h-33}
		entry := viewer_texture_native(&capture, 384)
		if entry != nil && entry.native != nil {
			handle := framework_metal.register_texture(&viewer.renderer, entry.native)
			viewer_image_box(
				frame,
				fmt.tprintf("capture image %s", capture.capture_id),
				viewer_aspect_fit(image_area, entry.width, entry.height),
				handle,
			)
		} else {
			viewer_add_text(
				frame,
				fmt.tprintf("capture pending %s", capture.capture_id),
				viewer_object_state_label(capture.object_state),
				image_area,
				theme.muted,
				9,
				.Center,
			)
		}
		title := capture.page_title
		if len(title) == 0 {title = capture.alt_text}
		if len(title) == 0 {title = capture.capture_id}
		viewer_add_text(
			frame,
			fmt.tprintf("capture title %s", capture.capture_id),
			title,
			{rect.x+3, rect.y+3, rect.w-6, 22},
			capture.deleted ? theme.dim : theme.text,
			10,
		)
	}
}

viewer_detail_rect :: proc() -> framework_draw.Rect {
	grid, _, _, _ := viewer_grid_layout()
	margin := f32(hal_ui.METRICS.margin)
	return {
		grid.x+grid.w+margin,
		grid.y,
		f32(viewer.width)-(grid.x+grid.w+margin)-margin,
		grid.h,
	}
}

viewer_detail_field :: proc(
	frame: ^framework_ui.Frame,
	theme: hal_ui.Palette,
	name, label, value: string,
	panel: framework_draw.Rect,
	cursor: ^f32,
) {
	if len(value) == 0 {return}
	viewer_add_text(frame, fmt.tprintf("%s label", name), label, {panel.x+14, cursor^-17, panel.w-28, 15}, theme.muted, 8)
	cursor^ -= 20
	viewer_add_text(frame, fmt.tprintf("%s value", name), value, {panel.x+14, cursor^-22, panel.w-28, 21}, theme.text_soft, 10)
	cursor^ -= 28
}

viewer_add_detail :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	if viewer.mode == .Folder {
		viewer_add_folder_detail(frame, theme)
		return
	}
	panel := viewer_detail_rect()
	viewer_box(frame, "detail panel", "", panel, hal_ui.panel_style(theme, true), {.Draw_Background, .Clip})
	capture := viewer_selected_capture()
	if capture == nil {
		viewer_add_text(frame, "detail empty", "SELECT A CAPTURE", panel, theme.muted, 11, .Center)
		return
	}
	action_y := panel.y+10
	button_gap := f32(5)
	button_width := (panel.w-28-button_gap*3)/4
	actions := [4]Viewer_Action_Kind{.Open_Source, .Export, .Edit_Note, .Delete_Restore}
	texts := [4]string{"SOURCE", "EXPORT", "NOTE", capture.deleted ? "RESTORE" : "DELETE"}
	for index in 0..<4 {
		button_rect := framework_draw.Rect{
			panel.x+14+f32(index)*(button_width+button_gap),
			action_y,
			button_width,
			28,
		}
		if index == 3 && capture.deleted && capture.object_state != .Available {
			viewer_add_text(frame, "detail restore unavailable", "PURGED", button_rect, theme.dim, 9, .Center)
			continue
		}
		viewer_control(
			frame,
			fmt.tprintf("detail action %d", index),
			strings.to_lower(texts[index], context.temp_allocator),
			texts[index],
			button_rect,
			{kind=actions[index]},
			hal_ui.control_style(theme, role=actions[index] == .Delete_Restore ? .Destructive : .Primary),
		)
	}
	image_area := framework_draw.Rect{panel.x+14, panel.y+205, panel.w-28, panel.h-230}
	if image_area.h > 90 {
		entry := viewer_texture_native(capture, 2048)
		if entry != nil && entry.native != nil {
			handle := framework_metal.register_texture(&viewer.renderer, entry.native)
			viewer_image_box(frame, "detail image", viewer_aspect_fit(image_area, entry.width, entry.height), handle)
		} else {
			viewer_add_text(frame, "detail image pending", viewer_object_state_label(capture.object_state), image_area, theme.muted, 10, .Center)
			if capture.object_state == .Unavailable {
				viewer_control(
					frame,
					"download original",
					"download original from iCloud",
					"DOWNLOAD",
					{image_area.x+(image_area.w-110)/2, image_area.y+10, 110, 28},
					{kind=.Download},
					hal_ui.control_style(theme),
				)
			}
		}
	}
	cursor := panel.y+190
	viewer_detail_field(frame, theme, "detail title", "PAGE", capture.page_title, panel, &cursor)
	viewer_detail_field(frame, theme, "detail source", "SOURCE URL", capture.page_url, panel, &cursor)
	viewer_detail_field(frame, theme, "detail image url", "IMAGE URL", capture.current_src, panel, &cursor)
	viewer_detail_field(frame, theme, "detail alt", "ALT TEXT", capture.alt_text, panel, &cursor)
	viewer_detail_field(frame, theme, "detail caption", "CAPTION", capture.figure_caption, panel, &cursor)
	viewer_detail_field(frame, theme, "detail note", capture.note_conflict ? "NOTE · CONFLICT" : "NOTE", capture.note, panel, &cursor)
}

viewer_add_status :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	text := viewer.status
	if len(text) == 0 {
		if viewer.mode == .Folder {
			text = fmt.tprintf("%d IMAGES", len(viewer_folder_items()))
		} else {
			text = fmt.tprintf("%d CAPTURES", len(viewer.captures.captures))
		}
	}
	viewer_box(frame, "status background", "", {0, 0, f32(viewer.width), VIEWER_STATUS_HEIGHT}, {background=theme.header, opacity=1}, {.Draw_Background})
	viewer_add_text(frame, "status text", text, {8, 2, f32(viewer.width)-16, VIEWER_STATUS_HEIGHT-4}, theme.muted, 9)
}

viewer_add_settings_modal :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	viewer_box(frame, "settings backdrop", "", {0, 0, f32(viewer.width), f32(viewer.height)}, {background=theme.backdrop, opacity=1}, {.Draw_Background}, .Modal)
	w, h := min(f32(760), f32(viewer.width)-48), min(f32(620), f32(viewer.height)-48)
	modal := framework_draw.Rect{(f32(viewer.width)-w)/2, (f32(viewer.height)-h)/2, w, h}
	viewer_box(frame, "settings modal", "", modal, {background=theme.modal, border=theme.border, border_thickness=1, opacity=1}, {.Draw_Background, .Draw_Border}, .Modal)
	viewer_add_text(frame, "settings heading", "LIBRARY SETTINGS", {modal.x+18, modal.y+modal.h-48, modal.w-120, 32}, theme.text, 16, layer=.Modal)
	viewer_control(frame, "settings close", "close settings", "CLOSE", {modal.x+modal.w-90, modal.y+modal.h-42, 72, 26}, {kind=.Close_Modal}, hal_ui.control_style(theme), layer=.Modal)
	cursor := modal.y+modal.h-82
	if viewer.settings_loaded {
		viewer_add_text(frame, "settings appearance label", "APPEARANCE", {modal.x+18, cursor, 120, 18}, theme.muted, 8, layer=.Modal)
		light_selected := viewer.settings.interface_theme != "hw-dark"
		viewer_control(frame, "theme light", "use HW Light", "HW LIGHT", {modal.x+142, cursor-3, 96, 24}, {kind=.Set_Theme, index=0}, hal_ui.control_style(theme, light_selected ? .Selected : .Idle, .Focus), layer=.Modal)
		viewer_control(frame, "theme dark", "use HW Dark", "HW DARK", {modal.x+244, cursor-3, 96, 24}, {kind=.Set_Theme, index=1}, hal_ui.control_style(theme, !light_selected ? .Selected : .Idle, .Focus), layer=.Modal)
		cursor -= 38
		viewer_add_text(frame, "settings root label", "LIBRARY ROOT", {modal.x+18, cursor, modal.w-36, 16}, theme.muted, 8, layer=.Modal)
		cursor -= 25
		viewer_add_text(frame, "settings root", viewer.settings.library_path, {modal.x+18, cursor, modal.w-260, 22}, theme.text_soft, 10, layer=.Modal)
		viewer_control(frame, "reconnect library", "replace the machine-local library bookmark", "RECONNECT…", {modal.x+modal.w-220, cursor-2, 106, 24}, {kind=.Choose_Folder}, hal_ui.control_style(theme), layer=.Modal)
		viewer_control(frame, "move library", "move authoritative library root", "MOVE…", {modal.x+modal.w-104, cursor-2, 86, 24}, {kind=.Choose_Move}, hal_ui.control_style(theme), layer=.Modal)
		cursor -= 38
		viewer_add_text(frame, "settings membership label", "THIS MAC", {modal.x+18, cursor, modal.w-36, 16}, theme.muted, 8, layer=.Modal)
		cursor -= 25
		viewer_add_text(frame, "settings membership", fmt.tprintf("%s · %s", viewer.settings.device_id, viewer.settings.membership_status), {modal.x+18, cursor, modal.w-36, 22}, theme.text_soft, 10, layer=.Modal)
		cursor -= 42
		viewer_add_text(frame, "settings devices heading", "DEVICES AND ACKNOWLEDGEMENT", {modal.x+18, cursor, modal.w-36, 20}, theme.text, 11, layer=.Modal)
		cursor -= 31
		for &device, index in viewer.devices.devices {
			state := "PENDING"
			if device.retired {state = "RETIRED"} else if device.authorized {state = "ACTIVE"}
			label := fmt.tprintf("%s · %s · ACK %d", device.device_name, state, device.accepted_cutoff)
			viewer_add_text(frame, fmt.tprintf("settings device %d", index), label, {modal.x+18, cursor, modal.w-154, 22}, device.retired ? theme.dim : theme.text_soft, 9, layer=.Modal)
			if device.pending_request && !device.authorized {
				viewer_control(frame, fmt.tprintf("authorize device %d", index), "authorize pending device", "AUTHORIZE", {modal.x+modal.w-124, cursor-2, 106, 24}, {kind=.Authorize_Device, index=index}, hal_ui.control_style(theme, role=.Positive), layer=.Modal)
			} else if device.authorized && !device.retired && device.device_id != viewer.settings.device_id {
				viewer_control(frame, fmt.tprintf("retire device %d", index), "retire device", "RETIRE", {modal.x+modal.w-104, cursor-2, 86, 24}, {kind=.Retire_Device, index=index}, hal_ui.control_style(theme, role=.Destructive), layer=.Modal)
			}
			cursor -= 27
			if cursor < modal.y+190 {break}
		}
		viewer_add_text(frame, "settings purge heading", "PHYSICAL PURGE", {modal.x+18, cursor-2, modal.w-36, 20}, theme.text, 11, layer=.Modal)
		cursor -= 31
		shown := 0
		for &purge, index in viewer.purges.purges {
			if purge.block != "eligible" && len(purge.commit_event_id) == 0 {continue}
			label := fmt.tprintf("%s… · %s", purge.object_digest[:12], purge.block)
			viewer_add_text(frame, fmt.tprintf("settings purge %d", index), label, {modal.x+18, cursor, modal.w-154, 22}, theme.text_soft, 9, layer=.Modal)
			viewer_control(frame, fmt.tprintf("purge object %d", index), "physically purge object", "PURGE", {modal.x+modal.w-104, cursor-2, 86, 24}, {kind=.Purge_Object, index=index}, hal_ui.control_style(theme, role=.Destructive), layer=.Modal)
			cursor -= 27
			shown += 1
			if shown >= 3 || cursor < modal.y+70 {break}
		}
		if shown == 0 {
			blocked := 0
			for purge in viewer.purges.purges {if purge.block != "eligible" {blocked += 1}}
			viewer_add_text(frame, "settings purge none", fmt.tprintf("No object is eligible; %d remain blocked by live references, retention, or device acknowledgement.", blocked), {modal.x+18, cursor, modal.w-36, 28}, theme.muted, 9, layer=.Modal)
		}
	} else {
		viewer_add_text(frame, "settings unavailable", "iCloud is unavailable. Choose the single authoritative library folder.", {modal.x+18, cursor-30, modal.w-36, 44}, theme.text_soft, 10, layer=.Modal)
		viewer_control(frame, "choose folder", "choose library folder", "CHOOSE FOLDER", {modal.x+18, cursor-76, 150, 30}, {kind=.Choose_Folder}, hal_ui.control_style(theme), layer=.Modal)
	}
}

viewer_add_note_modal :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	viewer_box(frame, "note backdrop", "", {0, 0, f32(viewer.width), f32(viewer.height)}, {background=theme.backdrop, opacity=1}, {.Draw_Background}, .Modal)
	w, h := min(f32(680), f32(viewer.width)-48), f32(260)
	modal := framework_draw.Rect{(f32(viewer.width)-w)/2, (f32(viewer.height)-h)/2, w, h}
	viewer_box(frame, "note modal", "", modal, {background=theme.modal, border=theme.border, border_thickness=1, opacity=1}, {.Draw_Background, .Draw_Border}, .Modal)
	viewer_add_text(frame, "note heading", "EDIT NOTE", {modal.x+18, modal.y+modal.h-48, modal.w-36, 30}, theme.text, 15, layer=.Modal)
	viewer_box(frame, "note field", viewer.note_buffer, {modal.x+18, modal.y+70, modal.w-36, 118}, {background=theme.field, border=theme.focus, text=theme.text, border_thickness=1, opacity=1, text_style={font=VIEWER_FONT, size=11, tracking=-0.3, horizontal=.Start, vertical=.Start, inset=10, truncate=true}}, {.Draw_Background, .Draw_Border, .Draw_Text}, .Modal)
	viewer_control(frame, "note cancel", "cancel note editing", "CANCEL", {modal.x+modal.w-178, modal.y+22, 74, 30}, {kind=.Close_Modal}, hal_ui.control_style(theme), layer=.Modal)
	viewer_control(frame, "note save", "save note", "SAVE", {modal.x+modal.w-96, modal.y+22, 78, 30}, {kind=.Save_Note}, hal_ui.control_style(theme, role=.Positive), layer=.Modal)
}

viewer_add_confirmation_modal :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	viewer_box(frame, "confirmation backdrop", "", {0, 0, f32(viewer.width), f32(viewer.height)}, {background=theme.backdrop, opacity=1}, {.Draw_Background}, .Modal)
	w, h := min(f32(720), f32(viewer.width)-48), f32(300)
	modal := framework_draw.Rect{(f32(viewer.width)-w)/2, (f32(viewer.height)-h)/2, w, h}
	viewer_box(frame, "confirmation modal", "", modal, {background=theme.modal, border=theme.destructive, border_thickness=1, opacity=1}, {.Draw_Background, .Draw_Border}, .Modal)
	heading := "RETIRE DEVICE"
	explanation := "Retirement fixes this device's accepted cutoff. A returning Mac must discard stale operations and join with a new identity."
	if viewer.confirmation_kind == .Purge_Object {
		heading = "PHYSICALLY PURGE OBJECT"
		explanation = "The service will publish the proof before removing bytes. Capture records, tombstones, and purge history remain authoritative."
	} else if viewer.confirmation_kind == .Move_Library {
		heading = "MOVE AUTHORITATIVE LIBRARY"
		explanation = "The service coordinates the move, validates the destination, commits a new bookmark, and rebuilds local state. Every other active Mac must be retired first."
	}
	viewer_add_text(frame, "confirmation heading", heading, {modal.x+18, modal.y+modal.h-50, modal.w-36, 30}, theme.destructive, 15, layer=.Modal)
	viewer_add_text(frame, "confirmation explanation", explanation, {modal.x+18, modal.y+modal.h-98, modal.w-36, 38}, theme.text_soft, 10, layer=.Modal)
	viewer_add_text(frame, "confirmation instruction", "TYPE OR PASTE THIS EXACT IDENTIFIER", {modal.x+18, modal.y+146, modal.w-36, 18}, theme.muted, 8, layer=.Modal)
	viewer_add_text(frame, "confirmation value", viewer.confirmation_value, {modal.x+18, modal.y+119, modal.w-36, 24}, theme.text, 9, layer=.Modal)
	viewer_box(frame, "confirmation field", viewer.confirmation_buffer, {modal.x+18, modal.y+72, modal.w-36, 36}, {background=theme.field, border=theme.focus, text=theme.text, border_thickness=1, opacity=1, text_style={font=VIEWER_FONT, size=10, tracking=-0.3, horizontal=.Start, vertical=.Center, inset=10, truncate=true}}, {.Draw_Background, .Draw_Border, .Draw_Text}, .Modal)
	viewer_control(frame, "confirmation cancel", "cancel destructive action", "CANCEL", {modal.x+modal.w-198, modal.y+22, 84, 30}, {kind=.Close_Modal}, hal_ui.control_style(theme), layer=.Modal)
	viewer_control(frame, "confirmation commit", "confirm destructive action", "CONFIRM", {modal.x+modal.w-106, modal.y+22, 88, 30}, {kind=.Confirm_Destructive}, hal_ui.control_style(theme, viewer.confirmation_buffer == viewer.confirmation_value ? .Selected : .Disabled, .Destructive), viewer.confirmation_buffer == viewer.confirmation_value, .Modal)
}

viewer_add_palette_modal :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	viewer_box(frame, "palette backdrop", "", {0, 0, f32(viewer.width), f32(viewer.height)}, {background=theme.backdrop, opacity=1}, {.Draw_Background}, .Modal)
	w := min(f32(660), f32(viewer.width)-48)
	results := command_palette.visible_results(&viewer.palette)
	h := min(f32(420), f32(92+min(8, len(results))*36))
	modal := framework_draw.Rect{(f32(viewer.width)-w)/2, f32(viewer.height)-VIEWER_HEADER_HEIGHT-h-18, w, h}
	viewer_box(frame, "palette modal", "", modal, {background=theme.modal, border=theme.border, border_thickness=1, opacity=1}, {.Draw_Background, .Draw_Border}, .Modal)
	query := command_palette.query(&viewer.palette)
	if len(query) == 0 {query = "TYPE TO SEARCH COMMANDS"}
	viewer_box(frame, "palette query", query, {modal.x+14, modal.y+modal.h-50, modal.w-28, 36}, {background=theme.field, border=theme.focus, text=len(command_palette.query(&viewer.palette)) == 0 ? theme.muted : theme.text, border_thickness=1, opacity=1, text_style={font=VIEWER_FONT, size=11, tracking=-0.3, horizontal=.Start, vertical=.Center, inset=10, truncate=true}}, {.Draw_Background, .Draw_Border, .Draw_Text}, .Modal)
	for result, index in results {
		if index >= 8 {break}
		y := modal.y+modal.h-88-f32(index)*36
		selected := index == command_palette.selected_index(&viewer.palette)
		viewer_control(frame, fmt.tprintf("command result %d", index), result.entry.title, result.entry.title, {modal.x+14, y, modal.w-28, 30}, {kind=.Command_Result, index=index}, hal_ui.control_style(theme, selected ? .Selected : .Idle, .Focus), result.available, .Modal)
	}
}

viewer_add_flash_hints :: proc(frame: ^framework_ui.Frame, theme: hal_ui.Palette) {
	if !flash.is_active(&viewer.flash) {return}
	for hint, index in flash.visible_hints(&viewer.flash) {
		width := max(f32(24), f32(len(hint.label))*8+12)
		x := f32(hint.target.rect.x)
		y := f32(hint.target.rect.y+hint.target.rect.h)-22
		style := hal_ui.control_style(theme, hint.selected ? .Selected : .Idle, .Focus)
		style.background = theme.modal
		viewer_box(frame, fmt.tprintf("flash hint background %d", index), "", {x, y, width, 22}, style, {.Draw_Background, .Draw_Border}, .Tooltip)
		viewer_add_text(frame, fmt.tprintf("flash hint text %d", index), hint.label, {x, y, width, 22}, theme.text, 10, .Center, .Tooltip)
	}
}

viewer_build_frame :: proc() -> framework_ui.Frame {
	viewer.loads_this_frame = 0
	framework_metal.begin_texture_frame(&viewer.renderer)
	framework_coretext.begin_frame(&viewer.text, f32(viewer.scale), framework_metal.atlas_io(&viewer.renderer))
	frame := framework_ui.begin_frame(
		&viewer.controls,
		{viewport={0, 0, f32(viewer.width), f32(viewer.height)}},
		framework_coretext.backend(&viewer.text),
		context.temp_allocator,
	)
	clear(&viewer.bindings)
	theme := viewer_theme()
	viewer_box(&frame, "canvas", "", {0, 0, f32(viewer.width), f32(viewer.height)}, {background=theme.canvas, opacity=1}, {.Draw_Background})
	viewer_add_header(&frame, theme)
	viewer_add_folder_bar(&frame, theme)
	if viewer.mode == .Library {
		viewer_add_grid(&frame, theme)
	} else {
		viewer_add_folder_grid(&frame, theme)
	}
	viewer_add_detail(&frame, theme)
	viewer_add_status(&frame, theme)
	switch viewer.modal {
	case .Settings: viewer_add_settings_modal(&frame, theme)
	case .Note: viewer_add_note_modal(&frame, theme)
	case .Command_Palette: viewer_add_palette_modal(&frame, theme)
	case .Confirm: viewer_add_confirmation_modal(&frame, theme)
	case .None:
	}
	if viewer.modal == .None {viewer_add_flash_hints(&frame, theme)}
	return frame
}

viewer_render :: proc() {
	if viewer.layer == nil || viewer.width <= 0 || viewer.height <= 0 {return}
	drawable := msg_id(viewer.layer, sel_registerName("nextDrawable"))
	if drawable == nil {return}
	command_buffer := msg_id(viewer.queue, sel_registerName("commandBuffer"))
	pass := msg_id(objc_getClass("MTLRenderPassDescriptor"), sel_registerName("renderPassDescriptor"))
	attachments := msg_id(pass, sel_registerName("colorAttachments"))
	p_index := transmute(proc "c" (Id, Sel, uint) -> Id)objc_send_address
	attachment := p_index(attachments, sel_registerName("objectAtIndexedSubscript:"), 0)
	msg_void_id(attachment, sel_registerName("setTexture:"), msg_id(drawable, sel_registerName("texture")))
	msg_void_u(attachment, sel_registerName("setLoadAction:"), 2)
	msg_void_u(attachment, sel_registerName("setStoreAction:"), 1)
	theme := viewer_theme()
	viewer_msg_void_clear_color(attachment, sel_registerName("setClearColor:"), {f64(theme.canvas[0]), f64(theme.canvas[1]), f64(theme.canvas[2]), 1})
	encoder := msg_id_id(command_buffer, sel_registerName("renderCommandEncoderWithDescriptor:"), pass)
	frame := viewer_build_frame()
	defer framework_ui.frame_destroy(&frame)
	output := framework_ui.end_frame(&frame)
	framework_ui.publish(&viewer.controls, output)
	viewer.registry = framework_ui.registry_view_from_records(
		viewer.controls.published.actions[:],
		viewer.controls.published.controls[:],
		viewer.controls.published.frame,
	)
	framework_ui.registry_assert_valid(viewer.registry)
	viewer_rebuild_accessibility()
	framework_coretext.flush(&viewer.text)
	encoded := framework_metal.encode(
		&viewer.renderer,
		encoder,
		output.draw_list,
		[2]f32{f32(viewer.width), f32(viewer.height)},
		f32(viewer.scale),
	)
	msg_void(encoder, sel_registerName("endEncoding"))
	msg_void_id(command_buffer, sel_registerName("presentDrawable:"), drawable)
	msg_void(command_buffer, sel_registerName("commit"))
	viewer.needs_redraw = !encoded || viewer.loads_this_frame > 0
}

viewer_event_point :: proc(event: Id) -> Point {
	window_point := msg_point(event, sel_registerName("locationInWindow"))
	return msg_point_point_id(viewer.view, sel_registerName("convertPoint:fromView:"), window_point, nil)
}

viewer_on_mouse_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	point := viewer_event_point(event)
	activation, activated := framework_macos.pointer_activation_view(
		viewer.registry,
		.Primary_Press,
		{f32(point.x), f32(point.y)},
	)
	if activated {
		if binding := viewer_binding_for_id(activation.action); binding != nil {
			viewer_execute_action(binding.action)
			return
		}
	}
	if point.y >= viewer.height-f64(VIEWER_HEADER_HEIGHT) && viewer.modal == .None {
		msg_void_id(viewer.window, sel_registerName("performWindowDragWithEvent:"), event)
	}
}

viewer_on_scroll :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	delta := msg_f64(event, sel_registerName("scrollingDeltaY"))
	viewer.grid_scroll -= f32(delta)*2
	viewer.needs_redraw = true
}

viewer_edit_backspace :: proc(value: ^string) {
	if value == nil || len(value^) == 0 {return}
	end := len(value^)-1
	for end > 0 && (value^[end] & 0xc0) == 0x80 {end -= 1}
	next := strings.clone(value^[:end])
	delete(value^)
	value^ = next
}

viewer_edit_append :: proc(value: ^string, addition: string, maximum: int) {
	if value == nil || len(addition) == 0 || len(value^)+len(addition) > maximum {return}
	next := fmt.aprintf("%s%s", value^, addition)
	delete(value^)
	value^ = next
}

viewer_palette_backspace :: proc() {
	query := command_palette.query(&viewer.palette)
	if len(query) == 0 {return}
	end := len(query)-1
	for end > 0 && (query[end] & 0xc0) == 0x80 {end -= 1}
	_ = command_palette.set_query(&viewer.palette, query[:end])
}

viewer_on_key_down :: proc "c" (self: Id, command: Sel, event: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	key_code := msg_uint(event, sel_registerName("keyCode"))
	modifiers := msg_uint(event, sel_registerName("modifierFlags"))
	if viewer.modal == .Command_Palette {
		switch key_code {
		case 53: viewer_execute_action({kind=.Close_Modal})
		case 125: _ = command_palette.move_selection(&viewer.palette, 1)
		case 126: _ = command_palette.move_selection(&viewer.palette, -1)
		case 36:
			if id, activated := command_palette.activate_selected(&viewer.palette); activated {
				viewer.modal = .None
				viewer_execute_command(id)
			}
		case 51: viewer_palette_backspace()
		case:
			characters, converted := nsstring_to_string(msg_id(event, sel_registerName("characters")), context.temp_allocator)
			if converted && len(characters) > 0 && modifiers & VIEWER_COMMAND_MODIFIER == 0 {
				_ = command_palette.set_query(&viewer.palette, fmt.tprintf("%s%s", command_palette.query(&viewer.palette), characters))
			}
		}
		viewer.needs_redraw = true
		return
	}
	if viewer.modal == .Note {
		switch key_code {
		case 53: viewer_execute_action({kind=.Close_Modal})
		case 36: if modifiers & VIEWER_COMMAND_MODIFIER != 0 {viewer_execute_action({kind=.Save_Note})}
		case 51: viewer_edit_backspace(&viewer.note_buffer)
		case:
			if key_code == 9 && modifiers & VIEWER_COMMAND_MODIFIER != 0 {
				if pasted, pasted_ok := macos_clipboard_string(context.temp_allocator); pasted_ok {
					viewer_edit_append(&viewer.note_buffer, pasted, LIBRARY_MAX_NOTE_BYTES)
				}
			} else {
				characters, converted := nsstring_to_string(msg_id(event, sel_registerName("characters")), context.temp_allocator)
				if converted && modifiers & VIEWER_COMMAND_MODIFIER == 0 {
					viewer_edit_append(&viewer.note_buffer, characters, LIBRARY_MAX_NOTE_BYTES)
				}
			}
		}
		viewer.needs_redraw = true
		return
	}
	if viewer.modal == .Confirm {
		switch key_code {
		case 53: viewer_execute_action({kind=.Close_Modal})
		case 36: viewer_execute_action({kind=.Confirm_Destructive})
		case 51: viewer_edit_backspace(&viewer.confirmation_buffer)
		case:
			if key_code == 9 && modifiers & VIEWER_COMMAND_MODIFIER != 0 {
				if pasted, pasted_ok := macos_clipboard_string(context.temp_allocator); pasted_ok {
					viewer_edit_append(&viewer.confirmation_buffer, pasted, 128)
				}
			} else {
				characters, converted := nsstring_to_string(msg_id(event, sel_registerName("characters")), context.temp_allocator)
				if converted && modifiers & VIEWER_COMMAND_MODIFIER == 0 {
					viewer_edit_append(&viewer.confirmation_buffer, characters, 128)
				}
			}
		}
		viewer.needs_redraw = true
		return
	}
	if flash.is_active(&viewer.flash) {
		characters, converted := nsstring_to_string(msg_id(event, sel_registerName("charactersIgnoringModifiers")), context.temp_allocator)
		if key_code == 53 {
			flash.cancel(&viewer.flash)
		} else if key_code == 48 {
			flash.cycle_selection(&viewer.flash, .Next)
		} else if key_code == 36 {
			result := flash.activate_selection(&viewer.flash)
			if result.kind == .Activated {viewer_activate_flash_target(result.target_id)}
		} else if converted && len(characters) == 1 {
			result := flash.consume(&viewer.flash, characters[0])
			if result.kind == .Activated {viewer_activate_flash_target(result.target_id)}
		}
		viewer.needs_redraw = true
		return
	}
	if key_code == 40 && modifiers & VIEWER_COMMAND_MODIFIER != 0 {
		viewer_open_command_palette()
		return
	}
	if viewer.modal != .None {
		if key_code == 53 {viewer_execute_action({kind=.Close_Modal})}
		return
	}
	if viewer.search_focused {
		switch key_code {
		case 53:
			viewer.search_focused = false
			viewer.needs_redraw = true
		case 36:
			viewer.search_focused = false
			viewer_commit_search()
		case 51: viewer_search_backspace()
		case 9:
			if pasted, pasted_ok := macos_clipboard_string(context.temp_allocator); pasted_ok {
				viewer_search_append(pasted, 256)
			}
		case:
			characters, converted := nsstring_to_string(msg_id(event, sel_registerName("characters")), context.temp_allocator)
			if converted && modifiers & VIEWER_COMMAND_MODIFIER == 0 {
				viewer_search_append(characters, 256)
			}
		}
		viewer.needs_redraw = true
		return
	}
	characters, converted := nsstring_to_string(msg_id(event, sel_registerName("charactersIgnoringModifiers")), context.temp_allocator)
	if converted && characters == "/" && modifiers & VIEWER_COMMAND_MODIFIER == 0 {
		viewer_begin_flash()
		return
	}
	if converted && (characters == "s" || characters == "S") && modifiers & VIEWER_COMMAND_MODIFIER != 0 {
		viewer.search_focused = true
		viewer.needs_redraw = true
		return
	}
	_, columns, _, _ := viewer_grid_layout()
	if viewer.mode == .Folder {
		count := len(viewer_folder_items())
		switch key_code {
		case 53:
			viewer.search_focused = false
			viewer_clear_search()
		case 123: viewer.folder_selected = max(0, viewer.folder_selected-1)
		case 124: viewer.folder_selected = min(count-1, viewer.folder_selected+1)
		case 125: viewer.folder_selected = min(count-1, viewer.folder_selected+columns)
		case 126: viewer.folder_selected = max(0, viewer.folder_selected-columns)
		case 36: viewer_execute_action({kind=.Open_In_Finder})
		case 51: viewer_execute_action({kind=.Copy_Image})
		}
		viewer.needs_redraw = true
		return
	}
	switch key_code {
	case 53: viewer.modal = .None
	case 123: viewer.selected = max(0, viewer.selected-1)
	case 124: viewer.selected = min(len(viewer.captures.captures)-1, viewer.selected+1)
	case 125: viewer.selected = min(len(viewer.captures.captures)-1, viewer.selected+columns)
	case 126: viewer.selected = max(0, viewer.selected-columns)
	case 36: viewer_execute_action({kind=.Open_Source})
	case 51: viewer_execute_action({kind=.Delete_Restore})
	}
	viewer.needs_redraw = true
}

viewer_on_accepts_first :: proc "c" (self: Id, command: Sel) -> bool {return true}

viewer_should_terminate :: proc "c" (self: Id, command: Sel, app: Id) -> bool {return true}

viewer_window_can_become_key :: proc "c" (self: Id, command: Sel) -> bool {return true}

viewer_on_frame :: proc "c" (self: Id, command: Sel, timer: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	bounds := msg_rect(viewer.view, sel_registerName("bounds"))
	if bounds.size.width != viewer.width || bounds.size.height != viewer.height {
		viewer.width = bounds.size.width
		viewer.height = bounds.size.height
		viewer.needs_redraw = true
	}
	scale := msg_f64(viewer.window, sel_registerName("backingScaleFactor"))
	if scale > 0 && scale != viewer.scale {
		viewer.scale = scale
		viewer.needs_redraw = true
	}
	msg_void_size(viewer.layer, sel_registerName("setDrawableSize:"), {viewer.width*viewer.scale, viewer.height*viewer.scale})
	// Reload captures on a backoff schedule: when the last reload failed, wait
	// much longer so a dead service cannot freeze the main thread every frame.
	// The service start is guarded against an unconfigured library, so these
	// attempts are cheap when the service cannot run at all.
	if !viewer.reload_started || time.tick_since(viewer.last_reload) >= viewer_reload_interval() {
		_ = viewer_reload_captures()
	}
	if viewer.scanning_root_id > 0 && time.tick_since(viewer.last_scan_step) >= 400*time.Millisecond {
		viewer.last_scan_step = time.tick_now()
		viewer_folder_scan_step()
	}
	if viewer.needs_redraw {viewer_render()}
}

viewer_reload_interval :: proc() -> time.Duration {
	if viewer.reload_failed {return 10*time.Second}
	return 2*time.Second
}

viewer_register_classes :: proc() -> (view_class, window_class: Id) {
	accessibility_class := objc_allocateClassPair(
		objc_getClass("NSAccessibilityElement"),
		"hw_gallery_AccessibilityElement",
		0,
	)
	class_addMethod(accessibility_class, sel_registerName("accessibilityPerformPress"), rawptr(viewer_on_ax_press), "B@:")
	objc_registerClassPair(accessibility_class)
	delegate_class := objc_allocateClassPair(objc_getClass("NSObject"), "hw_gallery_Delegate", 0)
	class_addMethod(delegate_class, sel_registerName("viewerFrame:"), rawptr(viewer_on_frame), "v@:@")
	class_addMethod(delegate_class, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"), rawptr(viewer_should_terminate), "B@:@")
	objc_registerClassPair(delegate_class)
	viewer.delegate = msg_id(delegate_class, sel_registerName("new"))
	view_class = objc_allocateClassPair(objc_getClass("NSView"), "hw_gallery_MetalView", 0)
	class_addMethod(view_class, sel_registerName("acceptsFirstResponder"), rawptr(viewer_on_accepts_first), "B@:")
	class_addMethod(view_class, sel_registerName("mouseDown:"), rawptr(viewer_on_mouse_down), "v@:@")
	class_addMethod(view_class, sel_registerName("scrollWheel:"), rawptr(viewer_on_scroll), "v@:@")
	class_addMethod(view_class, sel_registerName("keyDown:"), rawptr(viewer_on_key_down), "v@:@")
	class_addMethod(view_class, sel_registerName("isAccessibilityElement"), rawptr(viewer_on_ax_is_element), "B@:")
	class_addMethod(view_class, sel_registerName("accessibilityChildren"), rawptr(viewer_on_ax_children), "@@:")
	objc_registerClassPair(view_class)
	window_class = objc_allocateClassPair(objc_getClass("NSWindow"), "hw_gallery_Window", 0)
	class_addMethod(window_class, sel_registerName("canBecomeKeyWindow"), rawptr(viewer_window_can_become_key), "B@:")
	class_addMethod(window_class, sel_registerName("canBecomeMainWindow"), rawptr(viewer_window_can_become_key), "B@:")
	objc_registerClassPair(window_class)
	return
}

viewer_initialize :: proc() -> bool {
	if !objc_initialize() {return false}
	viewer.scale = 1
	viewer.selected = -1
	viewer.needs_redraw = true
	viewer.bindings = make([dynamic]Viewer_Action_Binding)
	viewer.ax_bindings = make([dynamic]Viewer_AX_Binding)
	viewer.textures = make([dynamic]Viewer_Texture)
	framework_ui.context_init(&viewer.controls)
	framework_coretext.context_init(&viewer.text)
	framework_coretext.register_font(&viewer.text, VIEWER_FONT, ".AppleSystemUIFontMonospaced-Regular")
	if error := command_palette.state_init(&viewer.palette, search_reserve_size=8*1024*1024, search_commit_size=64*1024); error != nil {
		return false
	}
	flash.state_init(&viewer.flash)
	viewer_prepare_default_library()
	viewer.app = msg_id(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	view_class, window_class := viewer_register_classes()
	msg_void_int(viewer.app, sel_registerName("setActivationPolicy:"), 0)
	msg_void_id(viewer.app, sel_registerName("setDelegate:"), viewer.delegate)
	frame := Rect{{120, 100}, {VIEWER_DEFAULT_WIDTH, VIEWER_DEFAULT_HEIGHT}}
	viewer.window = msg_id_rect_u_u_b(
		msg_id(window_class, sel_registerName("alloc")),
		sel_registerName("initWithContentRect:styleMask:backing:defer:"),
		frame,
		VIEWER_WINDOW_STYLE,
		2,
		false,
	)
	if viewer.window == nil {return false}
	msg_void_id(viewer.window, sel_registerName("setTitle:"), nsstring("hw_gallery"))
	msg_void_bool(viewer.window, sel_registerName("setOpaque:"), true)
	msg_void_bool(viewer.window, sel_registerName("setHasShadow:"), false)
	msg_void_size(viewer.window, sel_registerName("setMinSize:"), {VIEWER_MIN_WIDTH, VIEWER_MIN_HEIGHT})
	viewer.view = msg_id_rect(
		msg_id(view_class, sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		Rect{{0, 0}, frame.size},
	)
	msg_void_id(viewer.window, sel_registerName("setContentView:"), viewer.view)
	viewer.device = MTLCreateSystemDefaultDevice()
	if viewer.device == nil {return false}
	viewer.queue = msg_id(viewer.device, sel_registerName("newCommandQueue"))
	viewer.layer = msg_id(objc_getClass("CAMetalLayer"), sel_registerName("layer"))
	msg_void_id(viewer.layer, sel_registerName("setDevice:"), viewer.device)
	msg_void_u(viewer.layer, sel_registerName("setPixelFormat:"), 80)
	msg_void_bool(viewer.layer, sel_registerName("setFramebufferOnly:"), true)
	msg_void_bool(viewer.view, sel_registerName("setWantsLayer:"), true)
	msg_void_id(viewer.view, sel_registerName("setLayer:"), viewer.layer)
	resource_path := ""
	bundle := msg_id(objc_getClass("NSBundle"), sel_registerName("mainBundle"))
	if resources := msg_id(bundle, sel_registerName("resourcePath")); resources != nil {
		if value, converted := nsstring_to_string(resources, context.temp_allocator); converted {
			if path, error := filepath.join([]string{value, "ui.metallib"}, context.temp_allocator); error == nil {
				resource_path = path
			}
		}
	}
	allow_runtime_fallback := false
	when ODIN_DEBUG {allow_runtime_fallback = true}
	if !framework_metal.renderer_init(&viewer.renderer, viewer.device, resource_path, allow_runtime_fallback=allow_runtime_fallback) {
		return false
	}
	if !framework_macos.frame_timer_start(&viewer.frame_timer, viewer.delegate, "viewerFrame:") {return false}
	msg_void_id(viewer.window, sel_registerName("makeFirstResponder:"), viewer.view)
	activate := os.get_env("HW_GALLERY_ACTIVATE_ON_LAUNCH", context.temp_allocator) != "0"
	visible := os.get_env("HW_GALLERY_VISIBLE_ON_LAUNCH", context.temp_allocator) != "0"
	if activate {
		msg_void_id(viewer.window, sel_registerName("makeKeyAndOrderFront:"), nil)
		msg_void_int(viewer.app, sel_registerName("activateIgnoringOtherApps:"), 1)
	} else if visible {
		msg_void_id(viewer.window, sel_registerName("orderBack:"), nil)
	}
	_ = viewer_reload_captures()
	viewer_reload_settings()
	viewer_reload_folders()
	return true
}

viewer_destroy :: proc() {
	framework_macos.frame_timer_stop(&viewer.frame_timer)
	for &entry in viewer.textures {
		if entry.native != nil {msg_void(entry.native, sel_registerName("release"))}
		delete(entry.digest)
	}
	delete(viewer.textures)
	library_service_response_destroy(&viewer.captures)
	library_service_response_destroy(&viewer.devices)
	library_service_response_destroy(&viewer.purges)
	library_service_response_destroy(&viewer.roots)
	library_service_response_destroy(&viewer.folder_images)
	library_service_response_destroy(&viewer.folder_search)
	delete(viewer.search_query)
	if viewer.settings_loaded {local_settings_destroy(&viewer.settings)}
	command_palette.state_destroy(&viewer.palette)
	flash.state_destroy(&viewer.flash)
	framework_metal.renderer_destroy(&viewer.renderer)
	framework_coretext.context_destroy(&viewer.text)
	framework_ui.context_destroy(&viewer.controls)
	delete(viewer.bindings)
	delete(viewer.ax_bindings)
	if viewer.ax_children != nil {msg_void(viewer.ax_children, sel_registerName("release"))}
	delete(viewer.note_buffer)
	delete(viewer.confirmation_value)
	delete(viewer.confirmation_buffer)
	delete(viewer.status)
	if viewer.queue != nil {msg_void(viewer.queue, sel_registerName("release"))}
	if viewer.delegate != nil {msg_void(viewer.delegate, sel_registerName("release"))}
	viewer = {}
}

library_gui_run :: proc() {
	if !viewer_initialize() {
		fmt.eprintln("hw_gallery could not initialize its native viewer.")
		return
	}
	defer viewer_destroy()
	msg_void(viewer.app, sel_registerName("run"))
}
