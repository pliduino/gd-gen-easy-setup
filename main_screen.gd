extends PanelContainer

@export var file_dialog: FileDialog
@export var folder_text: LineEdit
@export var project_name_edit: LineEdit
@export var lib_name_edit: LineEdit
@export var open_dialog_button: Button
@export var create_project_button: Button

@export var godot_version_select: OptionButton
@export var error_dialog: AcceptDialog
@export var create_folder_check: CheckButton

const gd_gen_repository_url: String = "https://github.com/pliduino/gd-gen.git"
const godot_cpp_repository_url: String = "https://github.com/godotengine/godot-cpp.git"

var base_path: String
var project_name: String
var create_folder: bool = true

func _ready() -> void:
	open_dialog_button.pressed.connect(_open_file_dialog)
	file_dialog.dir_selected.connect(_on_dir_select)
	create_project_button.pressed.connect(_create_project)
	project_name_edit.text_changed.connect(_on_project_name_update)
	create_folder_check.toggled.connect(_on_create_folder_toggle)
	
	base_path = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	folder_text.text = base_path
	
	project_name = project_name_edit.text
	_update_path_text()

func _on_create_folder_toggle(toggle: bool):
	create_folder = toggle
	_update_path_text()

func _open_file_dialog() -> void:
	file_dialog.popup_centered()

func _on_dir_select(path: String):
	base_path = path
	_update_path_text()
	
func _on_project_name_update(new_project_name: String):
	project_name = new_project_name
	_update_path_text()
	
func _update_path_text():
	folder_text.text = base_path
	if create_folder:
		folder_text.text += "/" + project_name

func is_folder_empty(path: String) -> bool:
	var dir := DirAccess.open(path)
	if dir == null:
		return false

	dir.include_navigational = false
	dir.include_hidden = true

	dir.list_dir_begin()
	var file_name = dir.get_next()
	dir.list_dir_end()

	return file_name == ""

func _create_project():
	var project_folder = base_path;
	if create_folder:
		project_folder += "/" + project_name 
	
	var result = DirAccess.make_dir_recursive_absolute(project_folder)
	
	if result != OK:
		pop_error_dialog("Could not create folder", "DirAccess failed to create dir: " + result)
		return
		
	if !is_folder_empty(project_folder):
		pop_error_dialog("Project folder is not empty", "Your project folder should have no files in it.")
		return
	
	
	var module_folder = "%s/%s" % [project_folder, lib_name_edit.text];
	DirAccess.make_dir_absolute(module_folder)
	DirAccess.make_dir_absolute("%s/src" % module_folder)
	var register_types_h_file = FileAccess.open("%s/src/register_types.h" % module_folder, 
		FileAccess.WRITE)
		
	register_types_h_file.store_string("#pragma once

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_{module_name}_module(ModuleInitializationLevel p_level);
void uninitialize_{module_name}_module(ModuleInitializationLevel p_level);".format({"module_name": lib_name_edit.text}))
	
	register_types_h_file.close()
	
	var register_types_cpp_file = FileAccess.open("%s/src/register_types.cpp" % module_folder, FileAccess.WRITE)
	
	register_types_cpp_file.store_string("#include \"register_types.h\"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/engine.hpp>

#include <generated/register_types.generated.h>

using namespace godot;

void initialize_{module_name}_module(ModuleInitializationLevel p_level)
{
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
	{
		return;
	}

	GENERATED_TYPES();
}

void uninitialize_{module_name}_module(ModuleInitializationLevel p_level)
{
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
	{
		return;
	}
}

extern \"C\"
{
	// Initialization.
	GDExtensionBool GDE_EXPORT {module_name}_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization)
	{
		godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

		init_obj.register_initializer(initialize_{module_name}_module);
		init_obj.register_terminator(uninitialize_{module_name}_module);
		init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

		return init_obj.init();
	}
}".format({"module_name": lib_name_edit.text}))
	
	register_types_cpp_file.close()
	
	_generate_module_sconstruct_file(module_folder, lib_name_edit.text)
	
	DirAccess.make_dir_absolute(project_folder + "/godot")
	_generate_godot_project_file(project_folder + "/godot")
	
	DirAccess.make_dir_absolute(project_folder + "/godot/GDExtension")
	_generate_gdextension_file(project_folder + "/godot", lib_name_edit.text)
	
	if _clone_gd_gen(project_folder):
		OS.move_to_trash(project_folder)
		return
	
	if _clone_godot_cpp(project_folder, godot_version_select.text):
		OS.move_to_trash(project_folder)
		return
	
	_generate_git_ignore(project_folder)
	
	_generate_base_sconstruct_file(project_folder, [lib_name_edit.text])
	
	if _init_git(project_folder):
		OS.move_to_trash(project_folder)
		return
	
	get_tree().quit()

func _init_git(base_folder: String) -> int:
	var output = []
	var exit_code = OS.execute("git", ["init", base_folder], output, true)
	if exit_code != 0:
		var exit_message = ""
		for o in output:
			exit_message += o
		pop_error_dialog("Failed to initialize git", exit_message)
	return exit_code

func pop_error_dialog(title: String, text: String):
	error_dialog.title = title
	error_dialog.dialog_text = text
	error_dialog.popup_centered()

func _generate_git_ignore(base_folder: String) -> void:
	var file: FileAccess = FileAccess.open("%s/.gitignore" % base_folder, 
		FileAccess.WRITE)
	
	file.store_string("godot/.godot/
	**/*.obj")
	
	file.close()

func _generate_base_sconstruct_file(base_folder: String, modules: Array[String]) -> void:
	var file: FileAccess = FileAccess.open("%s/SConstruct" % base_folder, 
		FileAccess.WRITE)
		
	file.store_string("#!/usr/bin/env python\n")
	
	for module in modules:
		file.store_string("SConscript(\"%s/SConstruct\")" % module)
		
	file.close()

func _clone_gd_gen(base_folder: String):
	var output = []
	var exit_code = OS.execute("git", ["clone", gd_gen_repository_url, base_folder + "/gd-gen"], output, true)
	if exit_code != 0:
		var exit_message = ""
		for o in output:
			exit_message += o
		pop_error_dialog("Failed to clone gd-gen", exit_message)
	return exit_code
		
func _clone_godot_cpp(base_folder: String, version: String):
	var output = []
	var exit_code = OS.execute("git", ["clone", "-b", version if version != "4.5" else "master", godot_cpp_repository_url, base_folder + "/godot-cpp"], output, true)
	if exit_code != 0:
		var exit_message = ""
		for o in output:
			exit_message += o
		pop_error_dialog("Failed to clone godot-cpp", exit_message)
	return exit_code

func _generate_godot_project_file(godot_folder: String) -> void:
	var file: FileAccess = FileAccess.open("%s/project.godot" % godot_folder, 
		FileAccess.WRITE)
		
	file.store_string("; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name=\"{project_name}\"
".format({"project_name": project_name}))
	
	file.close()

func _generate_module_sconstruct_file(module_folder: String, module_name: String) -> void:
	var file: FileAccess = FileAccess.open("%s/SConstruct" % module_folder, 
		FileAccess.WRITE)
		
	file.store_string("#!/usr/bin/env python
import os
import sys

project_name = \"{project_name}\";
module_name = \"{module_name}\";

generator_program = SConscript(\"../gd-gen/SConstruct\")
env = SConscript(\"../godot-cpp/SConstruct\")


if str(ARGUMENTS.get(\"debug_symbols\", \"no\")) == \"yes\":
	env.Append(CCFLAGS=[\"/Zi\"])

def AllSources(node='.', pattern='*.cpp'):
	result = []
	for dir in Glob(os.path.join(node, '*')):
		if dir.isdir():
			result += AllSources(str(dir), pattern)
	result += [
		file for file in Glob(os.path.join(node, pattern), source=True)
		if file.isfile()
	]
	return result

sources = AllSources(\"src\", \"*.cpp\")

base_folder = Dir('.').srcnode().abspath

generate = Command(target = \"generate\",
				source = sources,
				action = \"{} {}/src\".format(generator_program[0].path, base_folder))

Depends(generate, generator_program)

AlwaysBuild(generate)

env.Append(CPPPATH=[\"src/\", \"./\"])
env.Append(CPPDEFINES=[\"GODOT_GENERATOR_EXPAND_MACROS\"])

if env[\"platform\"] == \"macos\":
	library = env.SharedLibrary(
		\"../godot/GDExtension/{}/{}_{}.{}.{}.framework/lib{}.{}.{}\".format(
		   module_name, project_name, module_name, env[\"platform\"], env[\"target\"], module_name, env[\"platform\"], env[\"target\"]
		),
		source=sources,
	)
elif env[\"platform\"] == \"ios\":
	if env[\"ios_simulator\"]:
		library = env.StaticLibrary(
			\"../godot/GDExtension/{}/{}_{}.{}.{}.simulator.a\".format(module_name, project_name, module_name, env[\"platform\"], env[\"target\"]),
			source=sources,
		)
	else:
		library = env.StaticLibrary(
			\"../godot/GDExtension/{}/{}_{}.{}.{}.a\".format(module_name, project_name, module_name, env[\"platform\"], env[\"target\"]),
			source=sources,
		)
else:
	library = env.SharedLibrary(
		\"../godot/GDExtension/{}/{}_{}{}{}\".format(module_name, project_name, module_name, env[\"suffix\"], env[\"SHLIBSUFFIX\"]),
		source=sources,
	)

Depends(library, generate)

Default(library)".format({"module_name": module_name, "project_name": project_name}))
		
	file.close()

func _generate_gdextension_file(godot_folder: String, module_name: String) -> void:
	var full_path = "%s/GDExtension/%s" % [godot_folder, module_name];
	DirAccess.make_dir_absolute(full_path)
	
	var file: FileAccess = FileAccess.open("{full_path}/{project_name}_{module_name}.gdextension"
		.format({"full_path": full_path, "module_name": module_name, "project_name": project_name}), 
		FileAccess.WRITE)
		
	print("{full_path}/{project_name}_{module_name}.gdextension"
		.format({"full_path": full_path, "module_name": module_name, "project_name": project_name}))
		
	file.store_string("[configuration]

entry_symbol = \"{module_name}_library_init\"
compatibility_minimum = \"{godot_version}\"
reloadable = true

[libraries]

macos.debug = \"res://GDExtension/{module_name}/{project_name}_{module_name}.macos.template_debug.framework\"
macos.release = \"res://GDExtension/{module_name}/{project_name}_{module_name}.macos.template_release.framework\"
ios.debug = \"res://GDExtension/{module_name}/{project_name}_{module_name}.ios.template_debug.xcframework\"
ios.release = \"res://GDExtension/{module_name}/{project_name}_{module_name}.ios.template_release.xcframework\"
windows.debug.x86_32 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.windows.template_debug.x86_32.dll\"
windows.release.x86_32 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.windows.template_release.x86_32.dll\"
windows.debug.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.windows.template_debug.x86_64.dll\"
windows.release.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.windows.template_release.x86_64.dll\"
linux.debug.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_debug.x86_64.so\"
linux.release.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_release.x86_64.so\"
linux.debug.arm64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_debug.arm64.so\"
linux.release.arm64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_release.arm64.so\"
linux.debug.rv64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_debug.rv64.so\"
linux.release.rv64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.linux.template_release.rv64.so\"
android.debug.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.android.template_debug.x86_64.so\"
android.release.x86_64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.android.template_release.x86_64.so\"
android.debug.arm64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.android.template_debug.arm64.so\"
android.release.arm64 = \"res://GDExtension/{module_name}/{project_name}_{module_name}.android.template_release.arm64.so\"
".format({"module_name": lib_name_edit.text, "godot_version": godot_version_select.text, "project_name": project_name}))
	
	file.close()
