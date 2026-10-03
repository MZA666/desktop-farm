extends SceneTree

## Offline image derivation only. All source PNGs and v0.8.1 assets stay intact.
## Four authored walk contacts are held for two runtime phases each, not
## synthesized or mirrored into eight supposedly distinct authored poses.
const SOURCE := "res://assets/pixel/v0.8.2/source/"
const OUTPUT := "res://assets/pixel/v0.8.2/runtime/"
const CELL := Vector2i(64, 80)
const ALPHA_THRESHOLD := 24.0 / 255.0
const DIRECTIONS := ["down", "right", "up", "left"]
const CONTACT_ORDER := [[0,1,2,3], [0,1,2,3], [0,2,1,3], [0,1,2,3]]
var failures: Array[String] = []
var manifest := {"version": "0.8.2", "status": "awaiting_bake", "generator": "OpenAI imagegen",
	"source_preserved": true, "resampling": "nearest", "trim_alpha_threshold": 24,
	"transparent_rgb_cleanup_alpha_max": 8, "foot_anchor": [32, 78],
	"prompt_provenance": "Original assets generated with the Codex built-in imagegen tool. Prompt constraints and source lineage are recorded in assets/pixel/v0.8.2/generation-prompts.md; generation calls remain in the development conversation.",
	"sources": {}, "atlases": {}}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT)) != OK:
		printerr("Cannot create v0.8.2 runtime directory")
		quit(1)
		return
	_background("woodland", "woodland")
	_background("pond-margins", "pond-margins")
	_bake_walk()
	_bake_pickup()
	manifest.status = "ready" if failures.is_empty() else "failed"
	var file := FileAccess.open(OUTPUT + "manifest.json", FileAccess.WRITE)
	if file == null: failures.append("Cannot write v0.8.2 manifest")
	else:
		file.store_string(JSON.stringify(manifest, "\t"))
		file.close()
	if failures.is_empty():
		print("SCENE_ASSETS_V082_BAKED original sources preserved; authored/runtime phases recorded")
		quit(0)
	else:
		for failure in failures: printerr(failure)
		quit(1)

func _source(kind: String) -> Image:
	var path := SOURCE + kind + ".png"
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		failures.append("Missing v0.8.2 source asset: " + path)
		return null
	manifest.sources[kind] = {"path": path, "width": image.get_width(), "height": image.get_height(), "sha256": FileAccess.get_sha256(path)}
	image.convert(Image.FORMAT_RGBA8)
	return image

func _background(kind: String, output_kind: String) -> void:
	var image := _source(kind)
	if image == null: return
	var before := image.get_size()
	image.resize(1536, 512, Image.INTERPOLATE_NEAREST)
	_save(image, output_kind + ".png")
	manifest.atlases[output_kind] = {"path": OUTPUT + output_kind + ".png", "source": kind,
		"cell": [1536, 512], "cells": 1, "source_size": [before.x,before.y],
		"aspect_preserved": is_equal_approx(float(before.x)/before.y, 3.0), "playable": false}

func _bake_walk() -> void:
	var source := _source("farmer-walk")
	if source == null: return
	var edges := _row_edges(source, 4)
	var frames: Array[Dictionary] = []
	for row in range(4):
		var columns := _column_edges(source, 4, edges[row], edges[row+1])
		for column in range(4):
			var area := Rect2i(columns[column],edges[row],columns[column+1]-columns[column],edges[row+1]-edges[row])
			var frame := _frame(source, area, row, column)
			frame.runtime_contact = CONTACT_ORDER[row].find(column)
			frames.append(frame)
	var record := _atlas(source, frames, "farmer-walk-atlas", 8, 4, true)
	record.source = "farmer-walk"
	record.row_edges = edges
	record.directions = DIRECTIONS
	record.authored_columns = 4
	record.authored_direction_frames = [4,4,4,4]
	record.runtime_direction_frames = [8,8,8,8]
	record.authored_contact_order_by_direction = {}
	record.runtime_source_columns_by_direction = {}
	for row in range(4):
		var mapping: Array[int] = []
		for contact in CONTACT_ORDER[row]:
			mapping.append(contact)
			mapping.append(contact)
		record.authored_contact_order_by_direction[DIRECTIONS[row]] = CONTACT_ORDER[row]
		record.runtime_source_columns_by_direction[DIRECTIONS[row]] = mapping
	record.neutral_runtime_phase_by_direction = {"down":2, "right":2, "up":6, "left":2}
	record.runtime_phase_policy = "Each original contact is held for two phases. Up uses original contacts in order0,2,1,3 to alternate actual left/right boots; no generated in-betweens or mirrored legs."
	manifest.atlases["farmer-walk"] = record

func _bake_pickup() -> void:
	var source := _source("farmer-second-draft")
	if source == null: return
	var edges := _row_edges(source, 5)
	var columns := _column_edges(source, 8, edges[4], edges[5])
	var frames: Array[Dictionary] = []
	for column in range(8):
		frames.append(_frame(source, Rect2i(columns[column],edges[4],columns[column+1]-columns[column],edges[5]-edges[4]), 0, column))
	var record := _atlas(source, frames, "pickup-atlas", 8, 1, false)
	record.source = "farmer-second-draft"
	record.source_sheet_columns = 8
	record.source_sheet_rows = 5
	record.source_sheet_row = 4
	record.row_edges = edges
	record.authored_columns = 8
	record.runtime_source_columns = [0,1,2,3,4,5,6,7]
	record.runtime_phase_policy = "Eight original frames from the last row; no reflection or manual paint."
	manifest.atlases.pickup = record

func _frame(source: Image, area: Rect2i, row: int, column: int) -> Dictionary:
	var bounds := _bounds(source, area)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		failures.append("Empty source farmer frame row %d column %d"%[row,column])
		bounds = Rect2i(area.position,Vector2i.ONE)
	return {"bounds":bounds,"row":row,"column":column}

func _atlas(source: Image, frames: Array[Dictionary], filename: String, columns: int, rows: int, hold_contacts: bool) -> Dictionary:
	var width := 1
	var height := 1
	for frame in frames:
		width = maxi(width,(frame.bounds as Rect2i).size.x)
		height = maxi(height,(frame.bounds as Rect2i).size.y)
	# One scale for the entire atlas prevents direction- or phase-dependent size.
	var scale := minf(float(CELL.x-4)/width,float(CELL.y-4)/height)
	var atlas := Image.create(columns*CELL.x,rows*CELL.y,false,Image.FORMAT_RGBA8)
	atlas.fill(Color.TRANSPARENT)
	var records: Array[Dictionary] = []
	for frame in frames:
		var bounds: Rect2i = frame.bounds
		var sprite := source.get_region(bounds)
		_clean_transparent_rgb(sprite)
		var size := Vector2i(maxi(1,roundi(bounds.size.x*scale)),maxi(1,roundi(bounds.size.y*scale)))
		sprite.resize(size.x,size.y,Image.INTERPOLATE_NEAREST)
		# Every contact's lowest foot has the same runtime bottom anchor.
		var offset := Vector2i((CELL.x-size.x)/2,CELL.y-2-size.y)
		for phase in range(2 if hold_contacts else 1):
			var column := int(frame.get("runtime_contact",frame.column))*2+phase if hold_contacts else int(frame.column)
			var destination := Vector2i(column*CELL.x,int(frame.row)*CELL.y)+offset
			atlas.blit_rect(sprite,Rect2i(Vector2i.ZERO,size),destination)
			records.append({"row":frame.row,"column":column,"source_column":frame.column,
				"source_bounds":[bounds.position.x,bounds.position.y,bounds.size.x,bounds.size.y],
				"scale":scale,"offset":[offset.x,offset.y],"foot_anchor":[32,78]})
	_save(atlas,filename+".png")
	return {"path":OUTPUT+filename+".png","columns":columns,"rows":rows,
		"cell":[CELL.x,CELL.y],"cells":columns*rows,"common_scale":scale,"sprites":records}

func _row_edges(image: Image, rows: int) -> Array[int]:
	var edges: Array[int] = [0]
	var nominal := float(image.get_height())/rows
	for row in range(1,rows):
		var expected := roundi(row*nominal)
		var radius := roundi(nominal*0.24)
		var best := expected
		var count_best := 2147483647
		for y in range(maxi(edges[-1]+1,expected-radius),mini(image.get_height()-1,expected+radius)+1):
			var count := 0
			for x in range(image.get_width()):
				if image.get_pixel(x,y).a>=ALPHA_THRESHOLD: count+=1
			if count<count_best or (count==count_best and absi(y-expected)<absi(best-expected)):
				best=y
				count_best=count
		edges.append(best)
	edges.append(image.get_height())
	return edges

func _column_edges(image: Image, columns: int, top: int, bottom: int) -> Array[int]:
	var edges: Array[int] = [0]
	var nominal := float(image.get_width())/columns
	for column in range(1,columns):
		var expected := roundi(column*nominal)
		var radius := roundi(nominal*0.24)
		var best := expected
		var count_best := 2147483647
		for x in range(maxi(edges[-1]+1,expected-radius),mini(image.get_width()-1,expected+radius)+1):
			var count := 0
			for y in range(top,bottom):
				if image.get_pixel(x,y).a>=ALPHA_THRESHOLD: count+=1
			if count<count_best or (count==count_best and absi(x-expected)<absi(best-expected)):
				best=x
				count_best=count
		edges.append(best)
	edges.append(image.get_width())
	return edges

func _bounds(image: Image, area: Rect2i) -> Rect2i:
	var left := area.end.x
	var top := area.end.y
	var right := area.position.x
	var bottom := area.position.y
	for y in range(area.position.y,area.end.y):
		for x in range(area.position.x,area.end.x):
			if image.get_pixel(x,y).a>=ALPHA_THRESHOLD:
				left=mini(left,x)
				top=mini(top,y)
				right=maxi(right,x+1)
				bottom=maxi(bottom,y+1)
	return Rect2i(left,top,maxi(0,right-left),maxi(0,bottom-top))

func _clean_transparent_rgb(image: Image) -> void:
	var bytes := image.get_data()
	for index in range(0,bytes.size(),4):
		if bytes[index+3]<=8:
			bytes[index]=0
			bytes[index+1]=0
			bytes[index+2]=0
			bytes[index+3]=0
	image.set_data(image.get_width(),image.get_height(),false,Image.FORMAT_RGBA8,bytes)

func _save(image: Image, filename: String) -> void:
	var path := OUTPUT+filename
	var error := image.save_png(ProjectSettings.globalize_path(path))
	if error!=OK: failures.append("Cannot write asset "+path+": "+error_string(error))
	else: print("V082_ASSET_BAKED ",filename," ",image.get_size())
