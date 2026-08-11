package main

import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	executable_name := filepath.base(os.args[0])
	if (len(os.args) > 1 && os.args[1] == "--service") ||
	   strings.has_suffix(executable_name, "-service") {
		code := library_service_run()
		if code != 0 {os.exit(code)}
		return
	}
	if strings.has_suffix(executable_name, "-native-host") {
		code := native_host_run()
		if code != 0 {os.exit(code)}
		return
	}
	if len(os.args) > 1 {
		code := library_cli_run(os.args[1:])
		if code != 0 {os.exit(code)}
		return
	}
	library_gui_run()
}
