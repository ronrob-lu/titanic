-- ==============================================================================
-- TITANIC & OCEAN LINERS MOD FOR LUANTI / MINETEST, MINECLONIA & VOXELIBRE
-- Autonomous ocean liners featuring dry walk-on ground floor, full interior
-- block & chest support, smooth 60 FPS velocity animation, screwdriver rotation,
-- and automated 60s shuttle travel.
-- ==============================================================================

local modname = minetest.get_current_modname() or "titanic"

-- Safe translator
local S = function(s) return s end

-- Detection of game environments
local is_mcl = minetest.get_modpath("mcl_core") ~= nil
local is_default = minetest.get_modpath("default") ~= nil

-- Vertical offset for 3D ship mesh so:
-- 1. The lower wooden hull floor (Y_raw = 0.02) sits at base_pos.y + 0.481
--    (1.9cm below the ly = 0 titanic:deck walkable surface at base_pos.y + 0.500).
-- 2. The upper wooden promenade deck (Y_raw = 3.8266) sits at base_pos.y + 4.482
--    (1.8cm below the ly = 4 titanic:deck walkable surface at base_pos.y + 4.500).
-- This guarantees zero Z-fighting with placed blocks on both decks and zero water seepage!
local MESH_Y_OFFSET = 0.46
local STEP_INTERVAL = 0.30
local CRUISE_SPEED = 1.0 / STEP_INTERVAL -- Smooth ~3.33 m/s continuous velocity cruise

-- Track recent block digs so mining a placed block with a pickaxe never accidentally dismantles the ship
local last_block_dig_time = {}
minetest.register_on_dignode(function(pos, oldnode, digger)
	if digger and digger:is_player() then
		last_block_dig_time[digger:get_player_name()] = minetest.get_us_time()
	end
end)

titanic = {
	active_ships = {},
}

-- Persistent mod storage to track all ships across world mapblocks (including unloaded chunks)
local storage = minetest.get_mod_storage()

local function get_known_ships()
	local raw = storage:get_string("known_ships")
	if raw and raw ~= "" then
		local data = minetest.deserialize(raw)
		if type(data) == "table" then return data end
	end
	return {}
end

local function save_known_ships(tbl)
	storage:set_string("known_ships", minetest.serialize(tbl or {}))
end

local function record_ship_position(ship_id, pos, ship_type, yaw)
	if not ship_id or not pos then return end
	local known = get_known_ships()
	known[ship_id] = {
		pos = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)},
		ship_type = ship_type,
		yaw = yaw,
		updated_at = os.time(),
	}
	save_known_ships(known)
end

local function unregister_ship_position(ship_id)
	if not ship_id then return end
	local known = get_known_ships()
	if known[ship_id] then
		known[ship_id] = nil
		save_known_ships(known)
	end
end

-- -----------------------------------------------------------------------------
-- Helper Functions & Compatibility Layer
-- -----------------------------------------------------------------------------

local function is_water(pos)
	if not pos then return false end
	local node = minetest.get_node_or_nil(pos)
	if not node or node.name == "ignore" then return false end
	if minetest.get_item_group(node.name, "water") ~= 0 then return true end
	if node.name:find("water") then return true end
	return false
end

local function has_adjacent_water(pos)
	for _, off in ipairs({{x=1,z=0}, {x=-1,z=0}, {x=0,z=1}, {x=0,z=-1}}) do
		if is_water({x = pos.x + off.x, y = pos.y, z = pos.z + off.z}) then
			return true
		end
	end
	return false
end

local function is_ice(node_name)
	if not node_name or node_name == "" or node_name == "air" or node_name == "ignore" then
		return false
	end
	if minetest.get_item_group(node_name, "ice") > 0 then return true end
	if minetest.get_item_group(node_name, "frosted_ice") > 0 then return true end
	if minetest.get_item_group(node_name, "snow_block") > 0 then return true end
	if node_name:find(":ice") ~= nil or node_name:find("packed_ice") ~= nil or node_name:find("blue_ice") ~= nil then
		return true
	end
	if node_name:find("iceberg") ~= nil or node_name:find("glacier") ~= nil then
		return true
	end
	return false
end

local function get_water_node()
	if is_mcl then
		return "mcl_core:water_source"
	end
	return "default:water_source"
end

local function is_pickaxe(tool_name)
	if not tool_name or tool_name == "" then return false end
	if minetest.get_item_group(tool_name, "pickaxe") > 0 then return true end
	if tool_name:find("pick") ~= nil then return true end
	return false
end

local function is_screwdriver(tool_name)
	if not tool_name or tool_name == "" then return false end
	if minetest.get_item_group(tool_name, "screwdriver") > 0 then return true end
	if tool_name:find("screwdriver") ~= nil then return true end
	return false
end

local function play_sound(sound_name, spec)
	if minetest.sound_play then
		pcall(minetest.sound_play, sound_name, spec)
	end
end

-- Track open ship chests via detached inventories so chest GUIs NEVER blink or lose nodemeta while cruising!
local open_ship_chests = {}

local function has_non_empty_meta(meta_table)
	if not meta_table then return false end
	if meta_table.fields and next(meta_table.fields) ~= nil then
		return true
	end
	if meta_table.inventory then
		for _, list in pairs(meta_table.inventory) do
			if type(list) == "table" then
				for _, stack in ipairs(list) do
					if type(stack) == "string" and stack ~= "" then
						return true
					elseif type(stack) == "userdata" and not stack:is_empty() then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Normalize any open chest/barrel node name back to its closed usable state.
-- If new_p is provided (during cruise steps), seamlessly update open_ship_chests target coordinate!
local function normalize_container_node(node, pos, new_p)
	if not node or not node.name then return node end
	local copy = {name = node.name, param1 = node.param1 or 15, param2 = node.param2}
	if copy.name == "default:chest_open" then
		copy.name = "default:chest"
	elseif copy.name == "default:chest_locked_open" then
		copy.name = "default:chest_locked"
	elseif copy.name == "mcl_barrels:barrel_open" then
		copy.name = "mcl_barrels:barrel_closed"
	end

	if pos then
		for pname, info in pairs(open_ship_chests) do
			if info and info.pos and vector.equals(info.pos, pos) then
				if new_p then
					info.pos = {x = new_p.x, y = new_p.y, z = new_p.z}
				end
			end
		end
		if rawget(_G, "default") and default.chest and type(default.chest.open_chests) == "table" then
			for pname, info in pairs(default.chest.open_chests) do
				if info and info.pos and vector.equals(info.pos, pos) then
					default.chest.open_chests[pname] = nil
				end
			end
		end
	end

	return copy
end

local function is_container_node_name(name)
	if not name or name == "" then return false end
	if name:find("chest") or name:find("barrel") or name:find("shulker") or name:find("crate") then
		return true
	end
	return false
end

-- Update hardcoded coordinate references (e.g. nodemeta:x,y,z in Mineclonia/Minetest formspecs)
local function update_meta_coordinates(meta_table, old_p, new_p)
	if not meta_table or not meta_table.fields or not old_p or not new_p then
		return meta_table
	end
	local old_str = string.format("%d,%d,%d", old_p.x, old_p.y, old_p.z)
	local new_str = string.format("%d,%d,%d", new_p.x, new_p.y, new_p.z)
	if old_str == new_str then return meta_table end

	for k, v in pairs(meta_table.fields) do
		if type(v) == "string" and v:find(old_str, 1, true) then
			meta_table.fields[k] = v:gsub(old_str, new_str)
		end
	end
	return meta_table
end

-- Move any Mineclonia 3D chest entity (mcl_chests:chest) from old_p to new_p
-- so chests in Mineclonia/VoxeLibre never despawn or flicker when the ship moves.
local function move_mcl_chest_entities(old_p, new_p, new_param2)
	if not is_mcl or not old_p or not new_p then return false end
	local moved_any = false
	local objs = minetest.get_objects_inside_radius(old_p, 0.55)
	for _, obj in ipairs(objs) do
		local lent = obj:get_luaentity()
		if lent and lent.name and lent.name:find("mcl_chests:") then
			obj:set_pos({x = new_p.x, y = new_p.y, z = new_p.z})
			if lent._pos then
				lent._pos = {x = new_p.x, y = new_p.y, z = new_p.z}
			end
			if new_param2 and type(lent.set_yaw) == "function" then
				pcall(function() lent:set_yaw(new_param2) end)
			end
			moved_any = true
		end
	end
	return moved_any
end

-- Snaps yaw to nearest 90-degree cardinal direction: 0 (N), pi/2 (W), pi (S), 3pi/2 (E)
local function normalize_cardinal_yaw(yaw)
	local deg = math.deg(yaw or 0) % 360
	if deg < 0 then deg = deg + 360 end
	local snapped_deg = math.floor((deg + 45) / 90) % 4 * 90
	return math.rad(snapped_deg)
end

local function yaw_to_cardinal_name(yaw)
	local deg = math.floor(math.deg(normalize_cardinal_yaw(yaw)) + 0.5) % 360
	if deg == 0 then return "North (+Z)"
	elseif deg == 90 then return "West (-X)"
	elseif deg == 180 then return "South (-Z)"
	elseif deg == 270 then return "East (+X)"
	end
	return "North (+Z)"
end

-- Forward vector and Starboard (right) vector from cardinal yaw
-- In Minetest at yaw = 0, +Z is forward. Bow (+Z in OBJ) points North (+Z).
local function get_direction_vectors(yaw)
	local dir_x = -math.sin(yaw)
	local dir_z =  math.cos(yaw)
	local right_x =  math.cos(yaw)
	local right_z =  math.sin(yaw)

	-- Snap to exact integer components {-1, 0, 1}
	dir_x = (math.abs(dir_x) > 0.5) and (dir_x > 0 and 1 or -1) or 0
	dir_z = (math.abs(dir_z) > 0.5) and (dir_z > 0 and 1 or -1) or 0
	right_x = (math.abs(right_x) > 0.5) and (right_x > 0 and 1 or -1) or 0
	right_z = (math.abs(right_z) > 0.5) and (right_z > 0 and 1 or -1) or 0

	return {x = dir_x, y = 0, z = dir_z}, {x = right_x, y = 0, z = right_z}
end

-- Convert ship-local coordinates (lx=starboard, ly=up, lz=bow) to world coordinates
local function local_to_world_pos(ship_pos, lx, ly, lz, dir, right)
	local wx = math.floor(ship_pos.x + right.x * lx + dir.x * lz + 0.5)
	local wy = math.floor(ship_pos.y + ly + 0.5)
	local wz = math.floor(ship_pos.z + right.z * lx + dir.z * lz + 0.5)
	return {x = wx, y = wy, z = wz}
end

-- Convert world coordinates back to ship-local coordinates
local function world_to_local_pos(ship_pos, world_pos, dir, right)
	local dx = world_pos.x - ship_pos.x
	local dz = world_pos.z - ship_pos.z
	local lx = math.floor(dx * right.x + dz * right.z + 0.5)
	local lz = math.floor(dx * dir.x + dz * dir.z + 0.5)
	local ly = math.floor(world_pos.y - ship_pos.y + 0.5)
	return lx, ly, lz
end

-- Rotate facedir / 4dir param2 by 90-degree steps clockwise
local function rotate_facedir(param2, steps)
	local axis = math.floor((param2 or 0) / 4)
	local rot = (param2 or 0) % 4
	local step_count = steps or 1
	local new_rot = (rot + step_count) % 4
	return axis * 4 + new_rot
end

local function anchor_to_entity_pos(anchor)
	return {
		x = anchor.x,
		y = anchor.y + MESH_Y_OFFSET,
		z = anchor.z,
	}
end

-- -----------------------------------------------------------------------------
-- Ocean Liner Footprint Construction
-- -----------------------------------------------------------------------------

local function build_footprint_data(generator_func)
	local fp_list = generator_func()
	local fp_set = {}
	for _, p in ipairs(fp_list) do
		fp_set[p.x .. ":" .. p.z] = true
	end
	return fp_list, fp_set
end

local function generate_normal_footprint()
	local fp = {}
	-- Bow (Z = 12, 11: 3 blocks wide)
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = 12}) end
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = 11}) end
	-- Main body (Z = 10 to -10: 5 blocks wide)
	for z = 10, -10, -1 do
		for x = -2, 2 do
			table.insert(fp, {x = x, z = z})
		end
	end
	-- Stern (Z = -11, -12: 3 blocks wide)
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = -11}) end
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = -12}) end
	return fp
end

local function generate_small_footprint()
	local fp = {}
	-- Bow (Z = 12, 11: 3 blocks wide)
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = 12}) end
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = 11}) end
	-- Main body (Z = 10 to -4: 5 blocks wide)
	for z = 10, -4, -1 do
		for x = -2, 2 do
			table.insert(fp, {x = x, z = z})
		end
	end
	-- Stern (Z = -5, -6: 3 blocks wide)
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = -5}) end
	for _, x in ipairs({-1, 0, 1}) do table.insert(fp, {x = x, z = -6}) end
	return fp
end

local norm_fp_list, norm_fp_set = build_footprint_data(generate_normal_footprint)
local small_fp_list, small_fp_set = build_footprint_data(generate_small_footprint)

-- Build outer hull boundary ring (1-block ring around the lower floor footprint)
-- so players on the bottom floor (ly = 1, 2, 3) cannot run through the hull walls,
-- while players on the second floor / top deck (ly >= 4) can freely leave or go outside!
local function build_boundary_data(fp_list, fp_set)
	local b_list = {}
	local b_set = {}
	local dirs4 = {{x=1,z=0}, {x=-1,z=0}, {x=0,z=1}, {x=0,z=-1}}
	for _, p in ipairs(fp_list) do
		for _, d in ipairs(dirs4) do
			local nx = p.x + d.x
			local nz = p.z + d.z
			local key = nx .. ":" .. nz
			if not fp_set[key] and not b_set[key] then
				b_set[key] = true
				table.insert(b_list, {x = nx, z = nz})
			end
		end
	end
	return b_list, b_set
end

-- Build 5-block-wide second floor footprint with a central stairwell opening (3x3 hole)
-- so players can build stairs between the bottom floor (ly = 0) and second floor (ly = 4)!
local function build_upper_footprint_data(fp_list, hole_min_z, hole_max_z)
	local u_list = {}
	local u_set = {}
	local h_set = {}
	for _, p in ipairs(fp_list) do
		local key = p.x .. ":" .. p.z
		if math.abs(p.x) <= 1 and p.z >= hole_min_z and p.z <= hole_max_z then
			h_set[key] = true
		else
			u_set[key] = true
			table.insert(u_list, {x = p.x, z = p.z})
		end
	end
	return u_list, u_set, h_set
end

local norm_bound_list, norm_bound_set = build_boundary_data(norm_fp_list, norm_fp_set)
local small_bound_list, small_bound_set = build_boundary_data(small_fp_list, small_fp_set)

local norm_upper_list, norm_upper_set, norm_hole_set = build_upper_footprint_data(norm_fp_list, -1, 1)
local small_upper_list, small_upper_set, small_hole_set = build_upper_footprint_data(small_fp_list, 1, 3)

local ship_types = {
	ocean_liner = {
		id = "ocean_liner",
		title = "RMS Titanic Ocean Liner",
		desc = "Massive ocean liner with dry walkable wooden decks, central stairwell opening, and full interior. Needs 3 blocks of water depth under hull. Autonomous 60s shuttle travel. Rotate with screwdriver. Place chests & blocks inside!",
		mesh = "ship-ocean-liner.obj",
		icon = "ship-ocean-liner.png",
		-- Precision-scaled so:
		-- 1) Lower hull floor (Y_raw=0.02) sits at Y=0.481 (ly=0 deck) with hull edge |X|=2.478 < 2.500 (zero ocean water stripes inside)
		-- 2) Upper wooden promenade deck (Y_raw=3.8266) sits at Y=4.482 (ly=4 deck) with full width |X|=3.480 > 2.500 and central stairwell hole
		visual_size = {x = 13.5, y = 10.51, z = 12.5},
		funnels = { {lx = 0, lz = 4.2}, {lx = 0, lz = 1.0}, {lx = 0, lz = -2.3}, {lx = 0, lz = -5.5} },
		funnel_height = 10.0,
		footprint = norm_fp_list,
		fp_set = norm_fp_set,
		upper_footprint = norm_upper_list,
		upper_fp_set = norm_upper_set,
		hole_set = norm_hole_set,
		boundary = norm_bound_list,
		bound_set = norm_bound_set,
		max_lz = 12,
		min_lz = -12,
		half_length = 12,
		half_width = 2,
		depth_check_points = { {lz = 11}, {lz = 0}, {lz = -11} },
	},
	ocean_liner_small = {
		id = "ocean_liner_small",
		title = "Small Ocean Liner",
		desc = "Compact ocean liner with dry walkable wooden decks, central stairwell opening, and full interior. Needs 3 blocks of water depth under hull. Autonomous 60s shuttle travel. Rotate with screwdriver. Place chests & blocks inside!",
		mesh = "ship-ocean-liner-small.obj",
		icon = "ship-ocean-liner-small.png",
		visual_size = {x = 13.5, y = 10.51, z = 12.5},
		funnels = { {lx = 0, lz = 4.2}, {lx = 0, lz = 1.0}, {lx = 0, lz = -2.3} },
		funnel_height = 10.0,
		footprint = small_fp_list,
		fp_set = small_fp_set,
		upper_footprint = small_upper_list,
		upper_fp_set = small_upper_set,
		hole_set = small_hole_set,
		boundary = small_bound_list,
		bound_set = small_bound_set,
		max_lz = 12,
		min_lz = -6,
		half_length = 9,
		half_width = 2,
		depth_check_points = { {lz = 11}, {lz = 3}, {lz = -5} },
	},
}

-- Find which active ship owns a given world coordinate (eliminates needing nodemeta on deck nodes!)
local function get_ship_at_pos(pos)
	if not pos then return nil end
	for _, ship in pairs(titanic.active_ships) do
		if ship and not ship.removed and ship.grid_anchor then
			local dir, right = get_direction_vectors(ship.yaw or 0)
			local lx, ly, lz = world_to_local_pos(ship.grid_anchor, pos, dir, right)
			if ly >= -1 and ly <= 11
					and math.abs(lx) <= (ship.sdef.half_width + 1)
					and lz >= (ship.sdef.min_lz - 1)
					and lz <= (ship.sdef.max_lz + 1) then
				return ship
			end
		end
	end
	return nil
end

-- Seamless detached inventory proxy for chests placed on ships so open chests NEVER blink
-- or lose nodemeta when the ship steps across world coordinates!
local player_detached_chests = {}

local function sync_detached_to_chest_node(pname, inv)
	local info = open_ship_chests[pname]
	if not info or not info.pos then return end
	local node_inv = minetest.get_meta(info.pos):get_inventory()
	if node_inv then
		node_inv:set_size("main", inv:get_size("main"))
		node_inv:set_list("main", inv:get_list("main"))
	end
end

local function open_ship_chest_for_player(player, pos)
	if not player or not player:is_player() or not pos then return false end
	local pname = player:get_player_name()
	local node = minetest.get_node(pos)
	if node.name == "default:chest_open" then
		minetest.swap_node(pos, {name = "default:chest", param1 = 15, param2 = node.param2})
	elseif node.name == "default:chest_locked_open" then
		minetest.swap_node(pos, {name = "default:chest_locked", param1 = 15, param2 = node.param2})
	end

	local node_inv = minetest.get_meta(pos):get_inventory()
	if not node_inv then return false end
	local list = node_inv:get_list("main")
	if not list or #list == 0 then
		node_inv:set_size("main", 8 * 4)
		list = node_inv:get_list("main")
	end

	local det_name = "titanic_chest_" .. pname
	local det_inv = player_detached_chests[pname]
	if not det_inv then
		det_inv = minetest.create_detached_inventory(det_name, {
			allow_move = function(inv, from_list, from_index, to_list, to_index, count, p)
				return count
			end,
			allow_put = function(inv, listname, index, stack, p)
				return stack:get_count()
			end,
			allow_take = function(inv, listname, index, stack, p)
				return stack:get_count()
			end,
			on_move = function(inv, from_list, from_index, to_list, to_index, count, p)
				sync_detached_to_chest_node(pname, inv)
			end,
			on_put = function(inv, listname, index, stack, p)
				sync_detached_to_chest_node(pname, inv)
			end,
			on_take = function(inv, listname, index, stack, p)
				sync_detached_to_chest_node(pname, inv)
			end,
		}, pname)
		player_detached_chests[pname] = det_inv
	end

	open_ship_chests[pname] = {pos = {x = pos.x, y = pos.y, z = pos.z}}
	det_inv:set_size("main", #list)
	det_inv:set_list("main", list)

	play_sound("default_chest_open", {pos = pos, gain = 0.3, max_hear_distance = 10})
	local bg = (rawget(_G, "default") and default.gui_bg or "")
		.. (rawget(_G, "default") and default.gui_bg_img or "")
		.. (rawget(_G, "default") and default.gui_slots or "")
	local formspec = "size[8,9]"
		.. bg
		.. "list[detached:" .. det_name .. ";main;0,0.3;8,4;]"
		.. "list[current_player;main;0,4.85;8,1;]"
		.. "list[current_player;main;0,6.08;8,3;8]"
		.. "listring[detached:" .. det_name .. ";main]"
		.. "listring[current_player;main]"
	minetest.show_formspec(pname, "titanic:ship_chest", formspec)
	return true
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname == "titanic:ship_chest" and fields.quit and player then
		local pname = player:get_player_name()
		local info = open_ship_chests[pname]
		if info and info.pos then
			play_sound("default_chest_close", {pos = info.pos, gain = 0.3, max_hear_distance = 10})
		end
		open_ship_chests[pname] = nil
	end
end)

minetest.register_on_mods_loaded(function()
	for _, cname in ipairs({"default:chest", "default:chest_open"}) do
		local def = minetest.registered_nodes[cname]
		if def then
			local old_rc = def.on_rightclick
			minetest.override_item(cname, {
				on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
					if get_ship_at_pos(pos) then
						open_ship_chest_for_player(clicker, pos)
						return itemstack
					end
					if old_rc then
						return old_rc(pos, node, clicker, itemstack, pointed_thing)
					end
					return itemstack
				end,
			})
		end
	end
end)

-- -----------------------------------------------------------------------------
-- Registration of Deck Floor Node
-- -----------------------------------------------------------------------------

-- Walkable Ship Deck Surface (Invisible, Solid, Non-Floodable, Indestructible by hand
-- so breaking placed blocks inside the ship never punches holes in the ship floor!)
minetest.register_node("titanic:deck", {
	description = "Titanic Deck Surface",
	tiles = {"titanic_deck.png"},
	inventory_image = "ship-ocean-liner-small.png",
	wield_image = "ship-ocean-liner-small.png",
	drawtype = "airlike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = true,
	pointable = true,
	diggable = false,
	buildable_to = false,
	floodable = false, -- Never replaced or washed away by ocean water!
	groups = {not_in_creative_inventory = 1, fall_damage_add_percent = -100},
	drop = "",

	on_rotate = function(pos, node, user, mode, new_param2)
		local ship_ent = get_ship_at_pos(pos)
		if not ship_ent then
			local ship_id = minetest.get_meta(pos):get_string("ship_id")
			ship_ent = titanic.active_ships[ship_id]
		end
		if ship_ent then
			if ship_ent.state == "traveling" then
				if user and user:is_player() then
					minetest.chat_send_player(user:get_player_name(),
						"⚓ The ocean liner is under way! Wait until docked to change rotation.")
				end
				return false
			end
			ship_ent:rotate_by(math.pi / 2, user)
			return true
		end
		return false
	end,

	on_punch = function(pos, node, puncher)
		if not puncher or not puncher:is_player() then return end
		local ship_ent = get_ship_at_pos(pos)
		if not ship_ent then
			local ship_id = minetest.get_meta(pos):get_string("ship_id")
			ship_ent = titanic.active_ships[ship_id]
		end
		if ship_ent then
			ship_ent:on_punch(puncher, pos)
		end
	end,
})

-- Invisible, walkable lower-hull boundary wall node (ly = 1, 2, 3 around the perimeter)
-- Prevents players on the bottom floor from running through the 3D ship hull walls,
-- while remaining pointable = false so crosshairs pass straight through for building inside!
minetest.register_node("titanic:hull", {
	description = "Titanic Lower Hull Boundary",
	tiles = {"titanic_deck.png"},
	inventory_image = "ship-ocean-liner-small.png",
	wield_image = "ship-ocean-liner-small.png",
	drawtype = "airlike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = true,
	pointable = false,
	diggable = false,
	buildable_to = false,
	floodable = false,
	groups = {not_in_creative_inventory = 1, fall_damage_add_percent = -100},
	drop = "",
})

-- If a player places a chest/container directly beneath an upper titanic:deck node (at ly = 3),
-- clear the single titanic:deck node right above the chest so its lid is never obstructed!
minetest.register_on_placenode(function(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	if newnode and is_container_node_name(newnode.name) then
		local above_p = {x = pos.x, y = pos.y + 1, z = pos.z}
		local above_node = minetest.get_node_or_nil(above_p)
		if above_node and above_node.name == "titanic:deck" then
			minetest.set_node(above_p, {name = "air", param1 = 15})
		end
	end
end)

-- Prevent any accidental fall, node suffocation, or drowning damage while aboard or near an ocean liner
minetest.register_on_player_hpchange(function(player, hp_change, reason)
	if not player or hp_change >= 0 then
		return hp_change
	end
	local rtype = type(reason) == "table" and reason.type or reason
	if rtype == "fall" or rtype == "node_damage" or rtype == "drown" then
		local ppos = player:get_pos()
		if ppos then
			-- Check if standing on or near any titanic:deck node
			local near_deck = minetest.find_node_near(ppos, 3, {"titanic:deck"})
			if near_deck then
				return 0
			end
			-- Or within the bounding box of any active ocean liner
			for _, ship in pairs(titanic.active_ships) do
				local anchor = ship and (ship.grid_anchor or ship.current_pos)
				if anchor and math.abs(ppos.x - anchor.x) <= 18
						and math.abs(ppos.y - anchor.y) <= 14
						and math.abs(ppos.z - anchor.z) <= 18 then
					return 0
				end
			end
		end
	end
	return hp_change
end, true)

-- -----------------------------------------------------------------------------
-- Ship Entity Implementation
-- -----------------------------------------------------------------------------

local function create_ship_entity(sdef)
	local entity = {
		initial_properties = {
			physical = false,
			collide_with_objects = false,
			backface_culling = false,
			use_texture_alpha = "clip",
			-- Subtle self-illumination prevents the large 3D mesh from blinking dark/bright
			-- when its anchor crosses block boundaries or custom blocks move near (0,0,0)
			glow = 4,
			-- Small submerged keel selectionbox strictly below the deck surface (y < -0.1)
			-- so player crosshairs NEVER hit the entity when placing blocks or opening chests on the floor!
			selectionbox = {-1.2, -1.5, -1.2, 1.2, -0.1, 1.2},
			visual = "mesh",
			mesh = sdef.mesh,
			textures = {"colormap.png"},
			visual_size = sdef.visual_size,
			makes_footstep_sound = false,
		},

		ship_id = nil,
		ship_type = sdef.id,
		sdef = sdef,
		yaw = 0,
		direction = 1, -- Always 1 (cruises forward bow-first; turns around 180° upon docking/departure)
		state = "idle", -- "idle", "traveling", or "sinking"
		idle_timer = 0,
		travel_step_timer = 0,
		sink_timer = 0,
		grid_anchor = nil,
		current_pos = nil,
		needs_turnaround = false,
		removed = false,
	}

	-- -------------------------------------------------------------------------
	-- Water Depth & Obstacle Check (3 Blocks Depth Under Keel)
	-- -------------------------------------------------------------------------
	function entity:check_depth_and_obstacles(test_ship_pos)
		local dir, right = get_direction_vectors(self.yaw)

		-- 0. Prevent two ocean liners from driving into each other!
		for other_id, other in pairs(titanic.active_ships) do
			if other_id ~= self.ship_id and other and not other.removed and other.grid_anchor then
				local o_anchor = other.grid_anchor
				if math.abs(test_ship_pos.y - o_anchor.y) <= 6 then
					local bow_p = local_to_world_pos(test_ship_pos, 0, 0, self.sdef.max_lz + 1, dir, right)
					local o_dir, o_right = get_direction_vectors(other.yaw or 0)
					local olx, _, olz = world_to_local_pos(o_anchor, bow_p, o_dir, o_right)
					if math.abs(olx) <= (other.sdef.half_width + 2)
							and olz >= (other.sdef.min_lz - 2)
							and olz <= (other.sdef.max_lz + 2) then
						return false, "another ship"
					end
				end
			end
		end

		-- 1. Check water depth under keel: must have at least 3 blocks of water under hull!
		for _, cp in ipairs(self.sdef.depth_check_points) do
			local wpt = local_to_world_pos(test_ship_pos, 0, 0, cp.lz, dir, right)
			for dy = -1, -3, -1 do
				local check_p = {x = wpt.x, y = test_ship_pos.y + dy, z = wpt.z}
				if not is_water(check_p) then
					local node = minetest.get_node_or_nil(check_p)
					if node and is_ice(node.name) then
						return false, "iceberg"
					end
					return false, "shallow" -- Less than 3 blocks water depth!
				end
			end
		end

		-- 2. Check leading edge for solid obstacle collision (land, dock, ice, walls)
		local leading_lz = self.sdef.max_lz + 1

		for x = -self.sdef.half_width, self.sdef.half_width do
			local edge_p = local_to_world_pos(test_ship_pos, x, 0, leading_lz, dir, right)
			for y_off = 0, 6 do
				local p = {x = edge_p.x, y = test_ship_pos.y + y_off, z = edge_p.z}
				local node = minetest.get_node_or_nil(p)
				if node and node.name ~= "air" and node.name ~= "ignore"
						and node.name ~= "titanic:deck" and node.name ~= "titanic:hull"
						and not is_water(p) then
					local ndef = minetest.registered_nodes[node.name]
					if ndef and ndef.walkable then
						if is_ice(node.name) then
							return false, "iceberg"
						end
						return false, "obstacle"
					end
				end
			end
		end

		return true, "clear"
	end

	-- -------------------------------------------------------------------------
	-- Player Riders Detection (Interior Cabins & Exterior Decks)
	-- -------------------------------------------------------------------------
	function entity:get_riders(pos_override)
		local base_pos = pos_override or self.grid_anchor or self.current_pos
		if not base_pos then return {} end
		local dir, right = get_direction_vectors(self.yaw)
		local riders = {}

		for _, player in ipairs(minetest.get_connected_players()) do
			local ppos = player:get_pos()
			if ppos then
				local lx, ly, lz = world_to_local_pos(base_pos, ppos, dir, right)
				-- Within vertical bounds of ship (ly = 0 to 10)
				if ly >= 0 and ly <= 10 then
					-- Within horizontal bounds of ship (with 1-block grace for smooth motion)
					if math.abs(lx) <= (self.sdef.half_width + 1)
							and lz >= (self.sdef.min_lz - 1)
							and lz <= (self.sdef.max_lz + 1) then
						local is_swimming_outside = false
						if (math.abs(lx) > self.sdef.half_width or lz < self.sdef.min_lz or lz > self.sdef.max_lz)
								and is_water(ppos) then
							is_swimming_outside = true
						end
						if not is_swimming_outside then
							table.insert(riders, player)
						end
					end
				end
			end
		end
		return riders
	end

	-- -------------------------------------------------------------------------
	-- Collect Custom User Placed Blocks (Chests, Luggage, Furniture, Rooms)
	-- -------------------------------------------------------------------------
	function entity:collect_custom_blocks(ship_pos, dir, right, next_ship_pos)
		local custom = {}
		for _, fp in ipairs(self.sdef.footprint) do
			for ly = 1, 10 do
				local wp = local_to_world_pos(ship_pos, fp.x, ly, fp.z, dir, right)
				local node = minetest.get_node(wp)
				if node.name ~= "air" and node.name ~= "ignore"
						and node.name ~= "titanic:deck" and node.name ~= "titanic:hull"
						and not is_water(wp) then
					local next_p = nil
					if next_ship_pos then
						next_p = local_to_world_pos(next_ship_pos, fp.x, ly, fp.z, dir, right)
					end
					local clean_node = normalize_container_node(node, wp, next_p)
					local meta = minetest.get_meta(wp):to_table()
					table.insert(custom, {
						lx = fp.x,
						ly = ly,
						lz = fp.z,
						node = clean_node,
						meta = has_non_empty_meta(meta) and meta or nil,
						old_p = wp,
					})
				end
			end
		end
		return custom
	end

	-- -------------------------------------------------------------------------
	-- Initial Deck & Dry Ground Floor Generation (Dual Wooden Decks: ly=0 & ly=4)
	-- -------------------------------------------------------------------------
	function entity:spawn_initial_decks(pos_override, dir_override, right_override, preserve_custom)
		local base_pos = pos_override or self.grid_anchor
		if not base_pos then return end
		local dir = dir_override
		local right = right_override
		if not dir or not right then
			dir, right = get_direction_vectors(self.yaw)
		end

		for _, fp in ipairs(self.sdef.footprint) do
			local fp_key = fp.x .. ":" .. fp.z
			-- 1. Lower Hull Wooden Floor (ly = 0, at y = base_pos.y):
			-- Replaces all ocean water at y = base_pos.y across the entire footprint with
			-- solid, dry, walkable titanic:deck aligned with the Y_raw = 0.02 wooden floor!
			local p_floor = local_to_world_pos(base_pos, fp.x, 0, fp.z, dir, right)
			minetest.set_node(p_floor, {name = "titanic:deck", param1 = 15})

			-- 2. Lower Hold Interior (ly = 1, 2, 3) & Upper Promenade Space (ly = 5 to 10):
			-- 100% open dry air inside the footprint, so blocks, stairs, and chests
			-- can be placed freely anywhere on both the lower floor and upper deck!
			for ly = 1, 10 do
				if ly ~= 4 then
					local p_space = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
					local cur = minetest.get_node(p_space)
					if not preserve_custom then
						if cur.name == "titanic:deck" or cur.name == "titanic:hull" or is_water(p_space) then
							minetest.set_node(p_space, {name = "air", param1 = 15})
						end
					else
						if cur.name == "titanic:deck" or cur.name == "titanic:hull" or is_water(p_space) then
							minetest.set_node(p_space, {name = "air", param1 = 15})
						elseif cur.name == "default:chest_open"
								or cur.name == "default:chest_locked_open"
								or cur.name == "mcl_barrels:barrel_open" then
							local fixed = normalize_container_node(cur, p_space)
							minetest.swap_node(p_space, fixed)
						end
					end
				end
			end

			-- 3. Upper Wooden Promenade & Cabin Deck (ly = 4, aligned with Y_raw = 3.8266):
			-- Features a 3x3 central stairwell opening (hole_set) in the middle of the 5-block-wide
			-- second floor so players can build stairs between the bottom and top floors!
			local p_prom = local_to_world_pos(base_pos, fp.x, 4, fp.z, dir, right)
			local p_below = local_to_world_pos(base_pos, fp.x, 3, fp.z, dir, right)
			local below_node = minetest.get_node(p_below)
			local cur_prom = minetest.get_node(p_prom)
			local has_custom_at_prom = preserve_custom
				and cur_prom.name ~= "air" and cur_prom.name ~= "ignore"
				and cur_prom.name ~= "titanic:deck" and cur_prom.name ~= "titanic:hull"
				and not is_water(p_prom)

			if not has_custom_at_prom then
				if self.sdef.hole_set[fp_key] or is_container_node_name(below_node.name) then
					minetest.set_node(p_prom, {name = "air", param1 = 15})
				else
					minetest.set_node(p_prom, {name = "titanic:deck", param1 = 15})
				end
			end
		end

		-- 4. Lower Hull Perimeter Boundary (ly = 1, 2, 3):
		-- Invisible walkable titanic:hull nodes along the outer perimeter of the bottom floor
		-- so players cannot run through the 3D ship hull on the bottom floor, while the top floor
		-- (ly >= 4) remains completely open so players can leave the ship or walk outside!
		for _, bp in ipairs(self.sdef.boundary) do
			for ly = 1, 3 do
				local p_bound = local_to_world_pos(base_pos, bp.x, ly, bp.z, dir, right)
				local cur = minetest.get_node(p_bound)
				if cur.name == "air" or cur.name == "titanic:deck" or cur.name == "titanic:hull" then
					minetest.set_node(p_bound, {name = "titanic:hull", param1 = 15})
				end
			end
		end

		-- Lift any players who were in the water inside the footprint up onto the dry lower floor (base_pos.y + 0.6)
		for _, player in ipairs(minetest.get_connected_players()) do
			local ppos = player:get_pos()
			if ppos then
				local lx, ly, lz = world_to_local_pos(base_pos, ppos, dir, right)
				if math.abs(lx) <= self.sdef.half_width
						and lz >= self.sdef.min_lz and lz <= self.sdef.max_lz
						and ppos.y >= (base_pos.y - 1.5) and ppos.y < (base_pos.y + 0.55) then
					player:set_pos({x = ppos.x, y = base_pos.y + 0.6, z = ppos.z})
				end
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Clear All Ship Nodes at a Given Position & Heading (Restores Water/Air)
	-- -------------------------------------------------------------------------
	function entity:clear_ship_nodes(base_pos, dir, right)
		for _, fp in ipairs(self.sdef.footprint) do
			for ly = 0, 10 do
				local wp = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
				local node = minetest.get_node(wp)
				if node.name == "titanic:deck" or node.name == "titanic:hull" then
					if ly == 0 then
						minetest.set_node(wp, {name = get_water_node()})
					else
						minetest.set_node(wp, {name = "air", param1 = 15})
					end
				end
			end
		end
		for _, bp in ipairs(self.sdef.boundary) do
			for ly = 1, 3 do
				local wp = local_to_world_pos(base_pos, bp.x, ly, bp.z, dir, right)
				local node = minetest.get_node(wp)
				if node.name == "titanic:hull" or node.name == "titanic:deck" then
					minetest.set_node(wp, {name = "air", param1 = 15})
				end
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Place / Restore a Custom Block with Full Chest & Formspec Integrity
	-- -------------------------------------------------------------------------
	local function place_custom_block_with_meta(old_p, new_p, new_node, meta_table, use_swap)
		if meta_table then
			update_meta_coordinates(meta_table, old_p, new_p)
		end

		if use_swap then
			-- Move any Mineclonia 3D chest entity smoothly without destroying/recreating it
			local moved_mcl_ent = move_mcl_chest_entities(old_p, new_p, new_node.param2)
			local cur = minetest.get_node(new_p)
			if cur.name ~= new_node.name or cur.param2 ~= new_node.param2 then
				if is_mcl and new_node.name:find("mcl_chests:") and not moved_mcl_ent then
					minetest.set_node(new_p, new_node)
				else
					minetest.swap_node(new_p, new_node)
				end
			end
			if meta_table then
				minetest.get_meta(new_p):from_table(meta_table)
			end
		else
			minetest.set_node(new_p, new_node)
			if meta_table then
				-- Merge inventory & updated fields while preserving any fresh on_construct fields if needed
				local fresh = minetest.get_meta(new_p):to_table() or {fields = {}, inventory = {}}
				if meta_table.inventory then
					fresh.inventory = meta_table.inventory
				end
				if meta_table.fields then
					for k, v in pairs(meta_table.fields) do
						fresh.fields[k] = v
					end
				end
				minetest.get_meta(new_p):from_table(fresh)
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Screwdriver Rotation (90° / 180° with Screwdriver or Shuttle Turnaround)
	-- -------------------------------------------------------------------------
	function entity:rotate_by(angle, player)
		if self.removed or not self.grid_anchor then return end
		if self.state == "traveling" then
			if player and player:is_player() then
				minetest.chat_send_player(player:get_player_name(),
					"⚓ The ocean liner is under way! Wait until docked to change rotation.")
			end
			return
		end

		local old_yaw = self.yaw
		local new_yaw = normalize_cardinal_yaw(old_yaw + angle)
		if math.abs(new_yaw - old_yaw) < 0.01 then return end

		local anchor = self.grid_anchor
		local old_dir, old_right = get_direction_vectors(old_yaw)
		local new_dir, new_right = get_direction_vectors(new_yaw)

		-- 1. Collect all custom user blocks at old orientation
		local custom_blocks = self:collect_custom_blocks(anchor, old_dir, old_right)
		local riders = self:get_riders(anchor)

		-- 2. Clear old custom nodes (clearing metadata first so on_destruct never drops items)
		for _, b in ipairs(custom_blocks) do
			if b.meta then
				minetest.get_meta(b.old_p):from_table(nil)
			end
			minetest.set_node(b.old_p, {name = "air", param1 = 15})
		end

		-- 3. Clear old deck and hull nodes
		self:clear_ship_nodes(anchor, old_dir, old_right)

		-- 4. Update entity yaw and position
		self.yaw = new_yaw
		self.grid_anchor = anchor
		local ent_pos = anchor_to_entity_pos(anchor)
		self.current_pos = ent_pos
		self.object:set_velocity({x = 0, y = 0, z = 0})
		self.object:set_pos(ent_pos)
		self.object:set_yaw(new_yaw)
		self.object:set_properties({backface_culling = false})
		record_ship_position(self.ship_id, anchor, self.ship_type, new_yaw)

		-- 5. Spawn new deck floor at new orientation
		self:spawn_initial_decks(anchor, new_dir, new_right, false)

		-- 6. Place rotated custom blocks at new orientation
		local angle_steps = math.floor(math.deg(angle) / 90 + 0.5) % 4
		for _, b in ipairs(custom_blocks) do
			local new_p = local_to_world_pos(anchor, b.lx, b.ly, b.lz, new_dir, new_right)
			local new_node = table.copy(b.node)
			local ndef = minetest.registered_nodes[new_node.name]
			if ndef and (ndef.paramtype2 == "facedir" or ndef.paramtype2 == "4dir") then
				new_node.param2 = rotate_facedir(new_node.param2, angle_steps)
			end
			for pname, info in pairs(open_ship_chests) do
				if info and info.pos and vector.equals(info.pos, b.old_p) then
					info.pos = {x = new_p.x, y = new_p.y, z = new_p.z}
				end
			end
			place_custom_block_with_meta(b.old_p, new_p, new_node, b.meta, false)
		end

		-- 7. Rotate riders inside or on top of the ship
		for _, rider in ipairs(riders) do
			local ppos = rider:get_pos()
			if ppos then
				local dx = ppos.x - anchor.x
				local dz = ppos.z - anchor.z
				local exact_lx = dx * old_right.x + dz * old_right.z
				local exact_lz = dx * old_dir.x + dz * old_dir.z
				local new_wx = anchor.x + new_right.x * exact_lx + new_dir.x * exact_lz
				local new_wz = anchor.z + new_right.z * exact_lx + new_dir.z * exact_lz
				rider:set_pos({x = new_wx, y = ppos.y, z = new_wz})
				local cur_yaw = rider:get_look_horizontal()
				rider:set_look_horizontal(cur_yaw + angle)
			end
		end

		play_sound("default_place_node", {pos = anchor, gain = 0.6})
		if player and player:is_player() then
			minetest.chat_send_player(player:get_player_name(),
				string.format("🧭 Titanic rotated to face %s.", yaw_to_cardinal_name(new_yaw)))
		end
	end

	-- -------------------------------------------------------------------------
	-- Atmospheric Particles (Coal Smoke & Water Wake)
	-- -------------------------------------------------------------------------
	function entity:emit_travel_particles(pos, step_dir)
		local dir, right = get_direction_vectors(self.yaw)
		-- Funnel coal smoke
		for _, f in ipairs(self.sdef.funnels) do
			local fpos = local_to_world_pos(pos, f.lx, self.sdef.funnel_height, f.lz, dir, right)
			minetest.add_particlespawner({
				amount = 4,
				time = STEP_INTERVAL,
				minpos = {x = fpos.x - 0.2, y = fpos.y, z = fpos.z - 0.2},
				maxpos = {x = fpos.x + 0.2, y = fpos.y + 0.5, z = fpos.z + 0.2},
				minvel = {x = -step_dir.x * 0.5, y = 1.5, z = -step_dir.z * 0.5},
				maxvel = {x = -step_dir.x * 1.0, y = 2.5, z = -step_dir.z * 1.0},
				texture = "titanic_smoke.png",
				minsize = 2.5,
				maxsize = 5.0,
				minexptime = 1.5,
				maxexptime = 3.0,
			})
		end

		-- Stern wake
		local stern_lz = self.sdef.min_lz
		local stern_pos = local_to_world_pos(pos, 0, 0, stern_lz, dir, right)
		minetest.add_particlespawner({
			amount = 8,
			time = STEP_INTERVAL,
			minpos = {x = stern_pos.x - 1.5, y = stern_pos.y - 0.2, z = stern_pos.z - 1.5},
			maxpos = {x = stern_pos.x + 1.5, y = stern_pos.y + 0.2, z = stern_pos.z + 1.5},
			minvel = {x = -0.3, y = 0.2, z = -0.3},
			maxvel = {x = 0.3, y = 0.8, z = 0.3},
			texture = "speedboats_wake.png",
			minsize = 2.0,
			maxsize = 4.0,
			minexptime = 0.8,
			maxexptime = 1.6,
		})
	end

	-- -------------------------------------------------------------------------
	-- Smooth Differential Cruising Step (Zero Churn, Zero Flicker, Zero Water)
	-- -------------------------------------------------------------------------
	function entity:execute_travel_step()
		if not self.grid_anchor or self.removed then return end
		local dir, right = get_direction_vectors(self.yaw)
		local step_dir = {x = dir.x, y = 0, z = dir.z}
		local base_pos = self.grid_anchor
		local target_pos = vector.add(base_pos, step_dir)

		-- 1. Check depth & obstacles ahead before taking this step
		local is_clear, reason = self:check_depth_and_obstacles(target_pos)
		if not is_clear then
			if reason == "iceberg" then
				self:strike_iceberg()
				return
			end

			-- Reached dock / shore / shallow water!
			self.state = "idle"
			self.idle_timer = 0
			self.needs_turnaround = true -- Rotates 180° on departure!
			self.object:set_velocity({x = 0, y = 0, z = 0})
			self.object:set_pos(anchor_to_entity_pos(base_pos))
			play_sound("default_place_node", {pos = base_pos, gain = 0.8})

			local riders = self:get_riders(base_pos)
			for _, r in ipairs(riders) do
				minetest.chat_send_player(r:get_player_name(),
					string.format("⚓ Titanic reached dock (%s). Idling 60s at dock before return voyage.", reason))
			end
			return
		end

		-- 2. Collect riders and custom user placed blocks (chests, chairs, luggage, walls)
		local riders = self:get_riders(base_pos)
		local custom_blocks = self:collect_custom_blocks(base_pos, dir, right, target_pos)

		-- 3. Differential Wooden Deck & Hull Boundary Update:
		--    - ly = 0: Lower Hull Floor (footprint)
		--    - ly = 1, 2, 3: Invisible Bottom-Floor Boundary Wall (boundary -> titanic:hull)
		--    - ly = 4: Second Floor Invisible Deck (upper_footprint -> titanic:deck, leaving 3x3 central stairwell hole!)
		-- Uses swap_node with param1 = 15 (full daylight) and zero nodemeta writes so chunks NEVER
		-- flash dark or trigger redundant lighting/nodemeta mesh rebuilds!

		-- 3a. Clear trailing Lower Hull Floor (ly = 0)
		for _, fp in ipairs(self.sdef.footprint) do
			local remains_in_target = self.sdef.fp_set[fp.x .. ":" .. (fp.z - 1)]
			if not remains_in_target then
				local old_floor = local_to_world_pos(base_pos, fp.x, 0, fp.z, dir, right)
				local cur = minetest.get_node(old_floor)
				if cur.name == "titanic:deck" or cur.name == "titanic:hull" or cur.name == "air" then
					minetest.swap_node(old_floor, {name = get_water_node(), param1 = 15})
				end
			end
		end

		-- 3b. Clear trailing Second Floor Deck (ly = 4, respecting central 3x3 stairwell hole)
		for _, ufp in ipairs(self.sdef.upper_footprint) do
			local remains_in_upper = self.sdef.upper_fp_set[ufp.x .. ":" .. (ufp.z - 1)]
			if not remains_in_upper then
				local old_prom = local_to_world_pos(base_pos, ufp.x, 4, ufp.z, dir, right)
				local cur_prom = minetest.get_node(old_prom)
				if cur_prom.name == "titanic:deck" or cur_prom.name == "titanic:hull" then
					minetest.swap_node(old_prom, {name = "air", param1 = 15})
				end
			end
		end

		-- 3c. Clear trailing Bottom-Floor Boundary Walls (ly = 1, 2, 3)
		for _, bp in ipairs(self.sdef.boundary) do
			local remains_in_bound = self.sdef.bound_set[bp.x .. ":" .. (bp.z - 1)]
			if not remains_in_bound then
				for ly = 1, 3 do
					local old_b = local_to_world_pos(base_pos, bp.x, ly, bp.z, dir, right)
					local cur_b = minetest.get_node(old_b)
					if cur_b.name == "titanic:hull" or cur_b.name == "titanic:deck" then
						minetest.swap_node(old_b, {name = "air", param1 = 15})
					end
				end
			end
		end

		-- 3d. Place leading Lower Hull Floor (ly = 0) and clear interior water/boundary at ly = 1..8
		for _, fp in ipairs(self.sdef.footprint) do
			local was_in_base = self.sdef.fp_set[fp.x .. ":" .. (fp.z + 1)]
			if not was_in_base then
				local new_floor = local_to_world_pos(target_pos, fp.x, 0, fp.z, dir, right)
				minetest.swap_node(new_floor, {name = "titanic:deck", param1 = 15})

				for ly = 1, 8 do
					if ly ~= 4 then
						local p_up = local_to_world_pos(target_pos, fp.x, ly, fp.z, dir, right)
						local cur_up = minetest.get_node(p_up)
						if cur_up.name == "titanic:hull" or is_water(p_up) then
							minetest.swap_node(p_up, {name = "air", param1 = 15})
						end
					end
				end
			end
		end

		-- 3e. Place leading Second Floor Deck (ly = 4, leaving 3x3 central stairwell hole open as air!)
		for _, ufp in ipairs(self.sdef.upper_footprint) do
			local was_in_upper = self.sdef.upper_fp_set[ufp.x .. ":" .. (ufp.z + 1)]
			if not was_in_upper then
				local new_prom = local_to_world_pos(target_pos, ufp.x, 4, ufp.z, dir, right)
				local cur_prom = minetest.get_node(new_prom)
				if cur_prom.name == "air" or cur_prom.name == "titanic:deck"
						or cur_prom.name == "titanic:hull" or is_water(new_prom) then
					minetest.swap_node(new_prom, {name = "titanic:deck", param1 = 15})
				end
			end
		end

		-- 3f. Place leading Bottom-Floor Boundary Walls (ly = 1, 2, 3)
		for _, bp in ipairs(self.sdef.boundary) do
			local was_in_bound = self.sdef.bound_set[bp.x .. ":" .. (bp.z + 1)]
			if not was_in_bound then
				for ly = 1, 3 do
					local new_b = local_to_world_pos(target_pos, bp.x, ly, bp.z, dir, right)
					local cur_b = minetest.get_node(new_b)
					if cur_b.name == "air" or cur_b.name == "titanic:deck"
							or cur_b.name == "titanic:hull" or is_water(new_b) then
						minetest.swap_node(new_b, {name = "titanic:hull", param1 = 15})
					end
				end
			end
		end

		-- 4. Move Custom User Blocks Front-to-Back (lz descending) Without Flicker:
		table.sort(custom_blocks, function(a, b)
			if a.lz ~= b.lz then return a.lz > b.lz end
			if a.ly ~= b.ly then return a.ly > b.ly end
			return a.lx < b.lx
		end)

		local new_pos_set = {}
		local container_at_ly3_new = {}
		for _, b in ipairs(custom_blocks) do
			b.new_p = local_to_world_pos(target_pos, b.lx, b.ly, b.lz, dir, right)
			new_pos_set[minetest.hash_node_position(b.new_p)] = true
			if b.ly == 3 and is_container_node_name(b.node.name) then
				local above_new = local_to_world_pos(target_pos, b.lx, 4, b.lz, dir, right)
				container_at_ly3_new[minetest.hash_node_position(above_new)] = above_new
			end
		end

		for _, b in ipairs(custom_blocks) do
			place_custom_block_with_meta(b.old_p, b.new_p, b.node, b.meta, true)
			local old_hash = minetest.hash_node_position(b.old_p)
			if not new_pos_set[old_hash] then
				if b.meta then
					minetest.get_meta(b.old_p):from_table(nil)
				end
				-- Always pass param1 = 15 when restoring air or titanic:deck so adjacent faces
				-- and the 3D ship entity NEVER sample param1 = 0 (pitch black)!
				-- Only restore titanic:deck at ly = 4 if the position in target_pos is part of upper_fp_set (not the stairwell hole!)
				local old_remains_in_upper = self.sdef.upper_fp_set[b.lx .. ":" .. (b.lz - 1)]
				if b.ly == 4 and old_remains_in_upper and not container_at_ly3_new[old_hash] then
					minetest.swap_node(b.old_p, {name = "titanic:deck", param1 = 15})
				else
					minetest.swap_node(b.old_p, {name = "air", param1 = 15})
				end
			end

			if b.ly == 3 and is_container_node_name(b.node.name) then
				local above_new = local_to_world_pos(target_pos, b.lx, 4, b.lz, dir, right)
				local above_new_hash = minetest.hash_node_position(above_new)
				if not new_pos_set[above_new_hash] then
					minetest.swap_node(above_new, {name = "air", param1 = 15})
				end
				local old_remains_in_upper = self.sdef.upper_fp_set[b.lx .. ":" .. (b.lz - 1)]
				if old_remains_in_upper then
					local above_old = local_to_world_pos(base_pos, b.lx, 4, b.lz, dir, right)
					local above_old_hash = minetest.hash_node_position(above_old)
					if not new_pos_set[above_old_hash] and not container_at_ly3_new[above_old_hash] then
						minetest.swap_node(above_old, {name = "titanic:deck", param1 = 15})
					end
				end
			end
		end

		-- 5. Smooth Continuous 3D Ship Entity Motion & Rider Synchronization:
		-- Instead of stopping and snapping 1 block at a time, keep the ship entity cruising
		-- at a continuous constant velocity (CRUISE_SPEED) and only resync position if it ever drifts!
		self.grid_anchor = target_pos
		local expected_ent_pos = anchor_to_entity_pos(target_pos)
		local cruise_vel = {x = step_dir.x * CRUISE_SPEED, y = 0, z = step_dir.z * CRUISE_SPEED}
		local actual_ent_pos = self.object:get_pos()
		if not actual_ent_pos or vector.distance(actual_ent_pos, expected_ent_pos) > 0.35 then
			self.object:set_pos(expected_ent_pos)
		end
		self.object:set_velocity(cruise_vel)
		self.current_pos = expected_ent_pos
		record_ship_position(self.ship_id, target_pos, self.ship_type, self.yaw)

		-- 6. Ensure riders never clip into newly advanced stairs/blocks on grid transitions
		for _, rider in ipairs(riders) do
			local ppos = rider:get_pos()
			if ppos then
				local new_ppos = {x = ppos.x, y = ppos.y, z = ppos.z}
				local needs_set = false

				-- If rider has no velocity assistance yet or was pushed back by a wall, keep them on board
				local rvel = rider:get_velocity()
				local forward_v = rvel and (rvel.x * step_dir.x + rvel.z * step_dir.z) or 0
				if forward_v < (CRUISE_SPEED * 0.35) then
					new_ppos.x = new_ppos.x + step_dir.x * (1.0 - math.max(0, forward_v / CRUISE_SPEED))
					new_ppos.z = new_ppos.z + step_dir.z * (1.0 - math.max(0, forward_v / CRUISE_SPEED))
					needs_set = true
				end

				local feet_node = minetest.get_node_or_nil({
					x = math.floor(new_ppos.x + 0.5),
					y = math.floor(new_ppos.y + 0.5),
					z = math.floor(new_ppos.z + 0.5),
				})
				if feet_node and feet_node.name ~= "air"
						and feet_node.name ~= "titanic:deck" and feet_node.name ~= "titanic:hull" then
					local ndef = minetest.registered_nodes[feet_node.name]
					if ndef and ndef.walkable then
						new_ppos.y = math.floor(new_ppos.y + 0.5) + 0.55
						needs_set = true
					end
				end

				if needs_set then
					rider:set_pos(new_ppos)
				end
			end
		end

		-- 7. Emit continuous travel particles (coal smoke & stern wake)
		self:emit_travel_particles(target_pos, step_dir)
	end

	-- -------------------------------------------------------------------------
	-- Entity Lifecycle Callbacks
	-- -------------------------------------------------------------------------
	function entity:on_activate(staticdata, dtime_s)
		self.object:set_armor_groups({immortal = 1})
		local pos = self.object:get_pos()
		self.current_pos = pos

		local is_new = false
		if staticdata and staticdata ~= "" then
			local data = minetest.deserialize(staticdata)
			if type(data) == "table" then
				self.ship_id = data.ship_id
				self.yaw = normalize_cardinal_yaw(data.yaw or 0)
				self.direction = 1
				self.state = (data.state == "sinking") and "idle" or (data.state or "idle")
				self.idle_timer = data.idle_timer or 0
				self.needs_turnaround = data.needs_turnaround or false
				if data.grid_anchor then
					self.grid_anchor = data.grid_anchor
				end
				if data.is_fresh_spawn then
					is_new = true
				end
			end
		else
			is_new = true
		end

		if not self.ship_id then
			self.ship_id = "ship_" .. tostring(math.random(100000, 999999)) .. "_" .. tostring(os.time())
			is_new = true
		end

		if not self.grid_anchor and pos then
			self.grid_anchor = {
				x = math.floor(pos.x + 0.5),
				y = math.floor(pos.y - MESH_Y_OFFSET + 0.5),
				z = math.floor(pos.z + 0.5),
			}
		end

		-- If another ship entity is ALREADY occupying this exact footprint (e.g. from two ships
		-- previously merging at a dock), remove this duplicate entity without touching the surviving ship's nodes!
		if self.grid_anchor then
			for other_id, other in pairs(titanic.active_ships) do
				if other_id ~= self.ship_id and other and not other.removed and other.grid_anchor then
					local dx = math.abs(self.grid_anchor.x - other.grid_anchor.x)
					local dy = math.abs(self.grid_anchor.y - other.grid_anchor.y)
					local dz = math.abs(self.grid_anchor.z - other.grid_anchor.z)
					if dy <= 4 and dx <= 12 and dz <= 12 then
						self.removed = true
						unregister_ship_position(self.ship_id)
						self.object:remove()
						return
					end
				end
			end
		end

		local ent_pos = anchor_to_entity_pos(self.grid_anchor)
		self.current_pos = ent_pos
		self.travel_step_timer = 0

		titanic.active_ships[self.ship_id] = self
		self.object:set_pos(ent_pos)
		self.object:set_yaw(self.yaw)
		self.object:set_properties({backface_culling = false, glow = 4})
		if self.state == "traveling" then
			local dir, _ = get_direction_vectors(self.yaw)
			self.object:set_velocity({x = dir.x * CRUISE_SPEED, y = 0, z = dir.z * CRUISE_SPEED})
		else
			self.object:set_velocity({x = 0, y = 0, z = 0})
		end

		record_ship_position(self.ship_id, self.grid_anchor, self.ship_type, self.yaw)
		-- Spawn dry ly=0 floor (and if reloading an existing ship, preserve user blocks while healing old water/hull nodes)
		self:spawn_initial_decks(self.grid_anchor, nil, nil, not is_new)
	end

	function entity:get_staticdata()
		return minetest.serialize({
			ship_id = self.ship_id,
			yaw = self.yaw,
			direction = 1,
			state = (self.state == "sinking") and "idle" or self.state,
			idle_timer = self.idle_timer,
			needs_turnaround = self.needs_turnaround,
			grid_anchor = self.grid_anchor,
		})
	end

	function entity:on_step(dtime)
		if self.removed or not self.object then return end
		local cur = self.object:get_pos()
		if not cur then return end
		self.current_pos = cur
		local anchor = self.grid_anchor or {
			x = math.floor(cur.x + 0.5),
			y = math.floor(cur.y - MESH_Y_OFFSET + 0.5),
			z = math.floor(cur.z + 0.5),
		}

		-- Sinking state
		if self.state == "sinking" then
			self.sink_timer = (self.sink_timer or 0) + dtime
			self.object:set_velocity({x = 0, y = -0.6, z = 0})

			if math.random(1, 2) == 1 then
				local dir, right = get_direction_vectors(self.yaw)
				local bubble_p = local_to_world_pos(cur, math.random(-2, 2), 0, math.random(self.sdef.min_lz, self.sdef.max_lz), dir, right)
				minetest.add_particlespawner({
					amount = 6,
					time = 0.2,
					minpos = {x = bubble_p.x - 1, y = bubble_p.y - 1, z = bubble_p.z - 1},
					maxpos = {x = bubble_p.x + 1, y = bubble_p.y + 1, z = bubble_p.z + 1},
					minvel = {x = -0.2, y = 1.0, z = -0.2},
					maxvel = {x = 0.2, y = 2.5, z = 0.2},
					texture = "speedboats_bubble.png",
					minsize = 1.5,
					maxsize = 4.0,
					minexptime = 1.0,
					maxexptime = 2.0,
				})
			end

			-- Sinks for 10 seconds before disappearing beneath the waves
			if self.sink_timer >= 10.0 then
				self:remove_vessel(false, false)
			end
			return
		end

		-- Idle at dock state (60 seconds idle)
		if self.state == "idle" then
			self.idle_timer = self.idle_timer + dtime

			-- Travel departure check after 60 seconds idle!
			if self.idle_timer >= 60.0 then
				-- If ship reached an obstacle/dock at the end of previous voyage, rotate 180° on departure!
				if self.needs_turnaround then
					self:rotate_by(math.pi)
					self.needs_turnaround = false
					anchor = self.grid_anchor or anchor
					play_sound("default_place_node", {pos = anchor, gain = 1.0})
				end

				local dir, _ = get_direction_vectors(self.yaw)
				local forward_step = {x = dir.x, y = 0, z = dir.z}
				local target_pos = vector.add(anchor, forward_step)

				local is_clear, reason = self:check_depth_and_obstacles(target_pos)
				if is_clear then
					-- Clear to depart in forward direction!
					self.state = "traveling"
					self.direction = 1
					self.idle_timer = 0
					self.travel_step_timer = 0
					self.object:set_pos(anchor_to_entity_pos(anchor))
					self.object:set_velocity({x = dir.x * CRUISE_SPEED, y = 0, z = dir.z * CRUISE_SPEED})
					play_sound("default_place_node", {pos = anchor, gain = 1.0})
					local riders = self:get_riders(anchor)
					for _, r in ipairs(riders) do
						minetest.chat_send_player(r:get_player_name(),
							string.format("🚢 %s departing! Cruising forward...", self.sdef.title))
					end
				elseif reason == "iceberg" then
					self:strike_iceberg()
					return
				else
					-- Forward blocked before departure; try rotating 180° to return
					self:rotate_by(math.pi)
					anchor = self.grid_anchor or anchor
					local rev_dir, _ = get_direction_vectors(self.yaw)
					local rev_target = vector.add(anchor, rev_dir)
					local rev_clear, rev_reason = self:check_depth_and_obstacles(rev_target)

					if rev_clear then
						self.state = "traveling"
						self.direction = 1
						self.idle_timer = 0
						self.travel_step_timer = 0
						self.object:set_pos(anchor_to_entity_pos(anchor))
						self.object:set_velocity({x = rev_dir.x * CRUISE_SPEED, y = 0, z = rev_dir.z * CRUISE_SPEED})
						play_sound("default_place_node", {pos = anchor, gain = 1.0})
						local riders = self:get_riders(anchor)
						for _, r in ipairs(riders) do
							minetest.chat_send_player(r:get_player_name(),
								string.format("🚢 %s rotated 180° on departure! Cruising return path...", self.sdef.title))
						end
					elseif rev_reason == "iceberg" then
						self:strike_iceberg()
						return
					else
						-- Both ways stuck (e.g. shallow water in all directions)
						self.idle_timer = 0 -- Wait another 60 seconds
						self.object:set_velocity({x = 0, y = 0, z = 0})
						local riders = self:get_riders(anchor)
						for _, r in ipairs(riders) do
							minetest.chat_send_player(r:get_player_name(),
								string.format("⚠️ Titanic cannot travel (%s): needs 3 blocks of water depth under hull!", reason))
						end
					end
				end
			end
		elseif self.state == "traveling" then
			local dir, _ = get_direction_vectors(self.yaw)
			local cruise_vel = {x = dir.x * CRUISE_SPEED, y = 0, z = dir.z * CRUISE_SPEED}
			self.object:set_velocity(cruise_vel)

			-- Smoothly carry riders along with the ship between grid steps so player movement
			-- matches the continuous 60 FPS glide of the 3D ship model!
			local riders = self:get_riders(anchor)
			for _, rider in ipairs(riders) do
				local rvel = rider:get_velocity()
				if rvel then
					local forward_v = rvel.x * dir.x + rvel.z * dir.z
					local delta_v = CRUISE_SPEED - forward_v
					if math.abs(delta_v) > 0.05 then
						rider:add_velocity({
							x = dir.x * delta_v * 0.65,
							y = 0,
							z = dir.z * delta_v * 0.65,
						})
					end
				end
			end

			self.travel_step_timer = (self.travel_step_timer or 0) + dtime

			while self.state == "traveling" and self.travel_step_timer >= STEP_INTERVAL do
				self.travel_step_timer = self.travel_step_timer - STEP_INTERVAL
				self:execute_travel_step()
			end
		end
	end

	-- -------------------------------------------------------------------------
	function entity:remove_vessel(clean_nodes, drop_inventory)
		if self.removed then return end
		self.removed = true
		if self.ship_id then
			titanic.active_ships[self.ship_id] = nil
			unregister_ship_position(self.ship_id)
		end

		local anchor = self.grid_anchor
		if clean_nodes and anchor then
			local dir, right = get_direction_vectors(self.yaw)

			-- Drop or clear custom blocks
			local custom = self:collect_custom_blocks(anchor, dir, right)
			for _, b in ipairs(custom) do
				if drop_inventory then
					minetest.node_dig(b.old_p, b.node, nil)
				else
					minetest.get_meta(b.old_p):from_table(nil)
					minetest.set_node(b.old_p, {name = "air"})
				end
			end

			-- Clear deck and hull nodes
			self:clear_ship_nodes(anchor, dir, right)
		end

		if self.object then
			pcall(function() self.object:remove() end)
		end
	end

	-- -------------------------------------------------------------------------
	-- Iceberg Collision & Catastrophic Sinking (Normal Luanti Falling Nodes)
	-- -------------------------------------------------------------------------
	function entity:strike_iceberg()
		if self.removed or self.state == "sinking" then return end
		self.state = "sinking"
		self.sink_timer = 0
		unregister_ship_position(self.ship_id)

		self.object:set_velocity({x = 0, y = -0.6, z = 0})

		local dir, right = get_direction_vectors(self.yaw)
		local anchor = self.grid_anchor or {
			x = math.floor(self.current_pos.x + 0.5),
			y = math.floor(self.current_pos.y - MESH_Y_OFFSET + 0.5),
			z = math.floor(self.current_pos.z + 0.5),
		}
		local riders = self:get_riders(anchor)
		local ship_pos = table.copy(anchor)

		-- Play loud impact and metal crunching sounds
		play_sound("default_dug_metal", {pos = ship_pos, gain = 1.0})
		play_sound("default_break_glass", {pos = ship_pos, gain = 1.0})

		-- Broadcast warning to riders and chat
		for _, r in ipairs(riders) do
			minetest.chat_send_player(r:get_player_name(),
				"❄️💥 MAYDAY! MAYDAY! The Ocean Liner struck an iceberg! All cargo and decks are plunging into the ocean depths!")
		end

		-- Large splash and ice-crystal bubble burst at the bow
		local bow_lz = self.sdef.max_lz
		local bow_pos = local_to_world_pos(ship_pos, 0, 1, bow_lz, dir, right)
		minetest.add_particlespawner({
			amount = 45,
			time = 0.5,
			minpos = {x = bow_pos.x - 3, y = bow_pos.y - 1, z = bow_pos.z - 3},
			maxpos = {x = bow_pos.x + 3, y = bow_pos.y + 4, z = bow_pos.z + 3},
			minvel = {x = -2, y = 2, z = -2},
			maxvel = {x = 2, y = 5, z = 2},
			texture = "speedboats_bubble.png",
			minsize = 2.0,
			maxsize = 6.0,
			minexptime = 1.0,
			maxexptime = 2.5,
		})

		-- 1. Collect custom blocks
		local custom_blocks = self:collect_custom_blocks(ship_pos, dir, right)

		-- 2. Clear deck floor so the floor disappears and hull is flooded with water
		self:clear_ship_nodes(ship_pos, dir, right)

		-- 3. Turn all custom placed blocks (luggage, chests, furniture, walls, wood)
		--    into Luanti falling nodes! They will fall with gravity to the ocean floor!
		table.sort(custom_blocks, function(a, b) return a.ly < b.ly end)

		for _, b in ipairs(custom_blocks) do
			local spawned = minetest.spawn_falling_node(b.old_p)
			if not spawned then
				-- If engine cannot turn this specific node into a falling entity (e.g. torches), dig & drop it
				minetest.node_dig(b.old_p, b.node, nil)
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Pickaxe-Only Dismantling, Screwdriver Rotation & Deck Companionway
	-- -------------------------------------------------------------------------
	function entity:on_punch(puncher, punched_pos)
		if not puncher or not puncher:is_player() or self.removed then return end
		local pname = puncher:get_player_name()
		local now_us = minetest.get_us_time()

		-- Ignore accidental follow-through punches within 0.6s of mining a placed block on deck
		if last_block_dig_time[pname] and (now_us - last_block_dig_time[pname]) < 600000 then
			return
		end

		local tool = puncher:get_wielded_item():get_name()

		-- Screwdriver rotation
		if is_screwdriver(tool) then
			self.needs_turnaround = false
			self:rotate_by(math.pi / 2, puncher)
			return
		end

		-- Sneak + punch with empty hand steps between Lower Hull Floor (ly=0) and Upper Promenade Deck (ly=4)
		local ctrl = puncher:get_player_control()
		if ctrl and ctrl.sneak and tool == "" and self.grid_anchor then
			local ppos = puncher:get_pos()
			if ppos then
				if ppos.y < (self.grid_anchor.y + 2.5) then
					puncher:set_pos({x = ppos.x, y = self.grid_anchor.y + 4.6, z = ppos.z})
				else
					puncher:set_pos({x = ppos.x, y = self.grid_anchor.y + 0.6, z = ppos.z})
				end
				return
			end
		end

		if self.state == "traveling" then
			minetest.chat_send_player(pname,
				"⚓ The ocean liner is under way! Wait until docked to dismantle.")
			return
		end

		-- Pickaxe dismantling
		if not is_pickaxe(tool) then
			play_sound("default_place_node", {pos = self.grid_anchor or self.current_pos, gain = 0.5})
			minetest.chat_send_player(pname,
				"⚓ Titanic ocean liners are reinforced! Use a pickaxe to dismantle, a screwdriver to rotate, or Sneak+Punch with empty hand to switch decks.")
			return
		end

		local anchor = self.grid_anchor or self.current_pos
		local ship_pos = table.copy(anchor)
		local ship_item = modname .. ":" .. self.ship_type

		self:remove_vessel(true, true)
		play_sound("default_dig_cracky", {pos = ship_pos, gain = 1.0})

		local inv = puncher:get_inventory()
		local is_creative = minetest.is_creative_enabled and minetest.is_creative_enabled(pname)

		if not is_creative then
			if inv and inv:room_for_item("main", ship_item) then
				inv:add_item("main", ship_item)
			else
				minetest.add_item(ship_pos, ship_item)
			end
		end
	end

	function entity:on_rightclick(clicker)
		if not clicker or not clicker:is_player() or self.removed then return end
		local tool = clicker:get_wielded_item():get_name()

		if is_screwdriver(tool) then
			self.needs_turnaround = false
			self:rotate_by(math.pi / 2, clicker)
			return
		end

		-- Status report
		local status = (self.state == "idle")
			and string.format("⚓ Idle at dock (Next cruise in %ds)", math.ceil(60 - self.idle_timer))
			or "🌊 Cruising Forward"

		minetest.chat_send_player(clicker:get_player_name(),
			string.format("🚢 %s | Heading: %s | %s", self.sdef.title, yaw_to_cardinal_name(self.yaw), status))
	end

	return entity
end

-- -----------------------------------------------------------------------------
-- Registration of Ships (Items & Entities)
-- -----------------------------------------------------------------------------

for id, sdef in pairs(ship_types) do
	local item_name = modname .. ":" .. id
	local entity_name = modname .. ":entity_" .. id

	-- 1. Register Entity
	minetest.register_entity(entity_name, create_ship_entity(sdef))

	-- 2. Register Ocean Liner Item
	minetest.register_craftitem(item_name, {
		description = sdef.title .. "\n" .. sdef.desc,
		inventory_image = sdef.icon,
		wield_image = sdef.icon,
		wield_scale = {x = 2.4, y = 2.4, z = 1.8},
		liquids_pointable = true,
		groups = {boat = 1, transport = 1, flammable = 2},

		on_place = function(itemstack, placer, pointed_thing)
			if pointed_thing.type ~= "node" then
				return itemstack
			end

			local under = pointed_thing.under
			local above = pointed_thing.above

			if not is_water(under) and not is_water(above) then
				if placer and placer:is_player() then
					minetest.chat_send_player(placer:get_player_name(),
						"⚠️ Ocean liners must be placed in water!")
				end
				return itemstack
			end

			local spawn_pos = table.copy(under)
			if not is_water(under) then
				spawn_pos = table.copy(above)
			end

			spawn_pos.x = math.floor(spawn_pos.x + 0.5)
			spawn_pos.y = math.floor(spawn_pos.y + 0.5)
			spawn_pos.z = math.floor(spawn_pos.z + 0.5)

			-- Always float spawn_pos up to the top water surface node so the ship never spawns submerged!
			local max_climb = 30
			while max_climb > 0 and is_water({x = spawn_pos.x, y = spawn_pos.y + 1, z = spawn_pos.z}) do
				spawn_pos.y = spawn_pos.y + 1
				max_climb = max_climb - 1
			end

			local look_yaw = placer and placer:get_look_horizontal() or 0
			local cardinal_yaw = normalize_cardinal_yaw(look_yaw)
			local new_ship_id = "ship_" .. tostring(math.random(100000, 999999)) .. "_" .. tostring(os.time())

			-- Pass initial staticdata directly into add_entity so on_activate spawns decks
			-- ONCE at the exact cardinal_yaw (never at yaw=0 first!).
			local init_staticdata = minetest.serialize({
				ship_id = new_ship_id,
				yaw = cardinal_yaw,
				direction = 1,
				state = "idle",
				idle_timer = 0,
				needs_turnaround = false,
				grid_anchor = spawn_pos,
				is_fresh_spawn = true,
			})

			local ent_pos = anchor_to_entity_pos(spawn_pos)
			local obj = minetest.add_entity(ent_pos, entity_name, init_staticdata)
			if obj then
				play_sound("default_place_node", {pos = spawn_pos, gain = 0.8})

				if placer and placer:is_player() then
					minetest.chat_send_player(placer:get_player_name(),
						string.format("🚢 %s launched! Heading %s. Idling 60s at dock before departure. Place chests & blocks inside! Use screwdriver to rotate.",
							sdef.title, yaw_to_cardinal_name(cardinal_yaw)))
				end

				local pname = placer and placer:is_player() and placer:get_player_name()
				local is_creative = pname and minetest.is_creative_enabled and minetest.is_creative_enabled(pname)
				if not is_creative then
					itemstack:take_item()
				end
			end

			return itemstack
		end,
	})
end

-- -----------------------------------------------------------------------------
-- Crafting Recipes (Mineclonia / VoxeLibre & Minetest Game)
-- -----------------------------------------------------------------------------

if is_mcl then
	minetest.register_craft({
		output = "titanic:ocean_liner",
		recipe = {
			{"mcl_core:iron_ingot", "mcl_core:coalblock", "mcl_core:iron_ingot"},
			{"mcl_core:ironblock", "group:wood", "mcl_core:ironblock"},
			{"group:wood", "group:wood", "group:wood"},
		}
	})

	minetest.register_craft({
		output = "titanic:ocean_liner_small",
		recipe = {
			{"mcl_core:iron_ingot", "mcl_core:coal_lump", "mcl_core:iron_ingot"},
			{"group:wood", "mcl_core:iron_ingot", "group:wood"},
			{"group:wood", "group:wood", "group:wood"},
		}
	})

	minetest.register_craft({
		output = "titanic:deck 4",
		recipe = {
			{"group:wood", "group:wood"},
		}
	})
elseif is_default then
	minetest.register_craft({
		output = "titanic:ocean_liner",
		recipe = {
			{"default:steel_ingot", "default:coalblock", "default:steel_ingot"},
			{"default:steelblock", "group:wood", "default:steelblock"},
			{"group:wood", "group:wood", "group:wood"},
		}
	})

	minetest.register_craft({
		output = "titanic:ocean_liner_small",
		recipe = {
			{"default:steel_ingot", "default:coal_lump", "default:steel_ingot"},
			{"group:wood", "default:steel_ingot", "group:wood"},
			{"group:wood", "group:wood", "group:wood"},
		}
	})

	minetest.register_craft({
		output = "titanic:deck 4",
		recipe = {
			{"group:wood", "group:wood"},
		}
	})
else
	minetest.register_craft({
		output = "titanic:ocean_liner",
		recipe = {
			{"", "group:wood", ""},
			{"group:wood", "group:wood", "group:wood"},
			{"group:wood", "group:wood", "group:wood"},
		}
	})
end

-- Shapeless conversion between normal and small liner
minetest.register_craft({
	type = "shapeless",
	output = "titanic:ocean_liner_small",
	recipe = {"titanic:ocean_liner"},
})

minetest.register_craft({
	type = "shapeless",
	output = "titanic:ocean_liner",
	recipe = {"titanic:ocean_liner_small"},
})

-- -----------------------------------------------------------------------------
-- Backward Compatibility Aliases
-- -----------------------------------------------------------------------------

minetest.register_alias("titanic:titanic", "titanic:ocean_liner")
minetest.register_alias("speedboats:speed_a", "titanic:ocean_liner")
minetest.register_alias("speedboats:speed_b", "titanic:ocean_liner")
minetest.register_alias("speedboats:boat", "titanic:ocean_liner")
minetest.register_alias("speedboats:speedboat", "titanic:ocean_liner")
minetest.register_alias("speedboats:fan", "titanic:ocean_liner_small")
minetest.register_alias("speedboats:ocean_liner", "titanic:ocean_liner")
minetest.register_alias("speedboats:ocean_liner_small", "titanic:ocean_liner_small")

-- -----------------------------------------------------------------------------
-- Chat Command: Delete All Ocean Liners (Loaded & Unloaded Chunks)
-- -----------------------------------------------------------------------------

local function delete_all_ships(caller_name)
	local known = get_known_ships()
	local unloaded_loaded = 0

	-- Safe destruction helper: checks method existence and protects against nil/corrupted entities
	local function safely_destroy_ship(ent)
		if not ent then return end
		pcall(function()
			if type(ent.remove_vessel) == "function" then
				ent:remove_vessel(true, true)
			elseif ent.object and type(ent.object.remove) == "function" then
				ent.object:remove()
			elseif type(ent.remove) == "function" then
				ent:remove()
			end
		end)
	end

	-- 1. Emerge / load mapblocks for all known ships that might be in unloaded chunks
	for ship_id, data in pairs(known) do
		if data.pos and minetest.load_area then
			local p1 = {x = data.pos.x - 25, y = data.pos.y - 12, z = data.pos.z - 25}
			local p2 = {x = data.pos.x + 25, y = data.pos.y + 15, z = data.pos.z + 25}
			pcall(minetest.load_area, p1, p2)
			unloaded_loaded = unloaded_loaded + 1

			pcall(function()
				local objs = minetest.get_objects_inside_radius(data.pos, 35)
				for _, obj in ipairs(objs) do
					local lent = obj:get_luaentity()
					if lent and lent.name and (lent.name:find("^titanic:") or lent.name:find("^speedboats:")) then
						safely_destroy_ship(lent)
					end
				end
			end)
		end
	end

	local removed_count = 0

	-- 2. Remove all active registered ships in memory
	for ship_id, ship in pairs(table.copy(titanic.active_ships)) do
		safely_destroy_ship(ship)
		titanic.active_ships[ship_id] = nil
		removed_count = removed_count + 1
	end

	-- 3. Sweep all active luaentities in memory for any unlinked ship entities
	for _, obj in pairs(minetest.luaentities) do
		if obj and obj.name and (obj.name:find("^titanic:entity_") or obj.name:find("^speedboats:")) then
			safely_destroy_ship(obj)
			removed_count = removed_count + 1
		end
	end

	-- 4. Clean up any stray orphan deck/hull nodes around players and known ship positions
	--    Only restore water if adjacent nodes at the same Y level are water; otherwise restore air!
	local cleaned_nodes = 0
	local scan_centers = {}
	for _, player in ipairs(minetest.get_connected_players()) do
		local ppos = player:get_pos()
		if ppos then table.insert(scan_centers, ppos) end
	end
	for _, data in pairs(known) do
		if data.pos then table.insert(scan_centers, data.pos) end
	end

	for _, center in ipairs(scan_centers) do
		local p1 = {x = math.floor(center.x - 35), y = math.floor(center.y - 12), z = math.floor(center.z - 35)}
		local p2 = {x = math.floor(center.x + 35), y = math.floor(center.y + 18), z = math.floor(center.z + 35)}
		local orphan_nodes = minetest.find_nodes_in_area(p1, p2, {"titanic:deck", "titanic:hull"})
		-- Sort top-to-bottom so upper hull/deck nodes become air before checking lower water level
		table.sort(orphan_nodes, function(a, b) return a.y > b.y end)
		for _, pos in ipairs(orphan_nodes) do
			if has_adjacent_water(pos) then
				minetest.set_node(pos, {name = get_water_node()})
			else
				minetest.set_node(pos, {name = "air"})
			end
			cleaned_nodes = cleaned_nodes + 1
		end
	end

	-- 5. Clear known ships registry completely
	save_known_ships({})
	titanic.active_ships = {}

	local msg = string.format("⚓ Deleted %d ocean liner(s) from the world (loaded %d distant mapblock regions, cleaned %d deck nodes). Ocean water restored.",
		removed_count, unloaded_loaded, cleaned_nodes)
	minetest.log("action", "[titanic] " .. msg)
	return true, msg
end

minetest.register_chatcommand("delete_ships", {
	params = "",
	description = "Deletes all Titanic and Ocean Liner ships from the world at once, restoring ocean water and cleaning decks even in distant unloaded mapblocks.",
	privs = {},
	func = function(name, param)
		return delete_all_ships(name)
	end,
})

minetest.register_chatcommand("clear_ships", {
	params = "",
	description = "Alias for /delete_ships",
	privs = {},
	func = function(name, param)
		return delete_all_ships(name)
	end,
})

minetest.register_chatcommand("delete_titanic", {
	params = "",
	description = "Alias for /delete_ships",
	privs = {},
	func = function(name, param)
		return delete_all_ships(name)
	end,
})

minetest.register_chatcommand("clear_titanic", {
	params = "",
	description = "Alias for /delete_ships",
	privs = {},
	func = function(name, param)
		return delete_all_ships(name)
	end,
})

minetest.log("action", "[titanic] Loaded Titanic and Ocean Liners with dry ground floor, smooth velocity animation, and full chest support.")
