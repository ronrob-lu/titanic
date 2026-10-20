-- ==============================================================================
-- TITANIC & OCEAN LINERS MOD FOR LUANTI / MINETEST, MINECLONIA & VOXELIBRE
-- Autonomous ocean liners featuring walk-on decks, full interior cabin support,
-- screwdriver rotation, moving blocks & luggage, and automated 60s shuttle travel.
-- ==============================================================================

local modname = minetest.get_current_modname() or "titanic"

-- Safe translator
local S = function(s) return s end

-- Detection of game environments
local is_mcl = minetest.get_modpath("mcl_core") ~= nil
local is_default = minetest.get_modpath("default") ~= nil

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

-- Rotate facedir param2 by 90-degree steps clockwise
local function rotate_facedir(param2, steps)
	local axis = math.floor((param2 or 0) / 4)
	local rot = (param2 or 0) % 4
	local step_count = steps or 1
	local new_rot = (rot + step_count) % 4
	return axis * 4 + new_rot
end

-- -----------------------------------------------------------------------------
-- Ocean Liner Footprint & Hull Perimeter Construction
-- -----------------------------------------------------------------------------

local function build_footprint_data(generator_func)
	local fp_list = generator_func()
	local fp_set = {}
	for _, p in ipairs(fp_list) do
		fp_set[p.x .. ":" .. p.z] = true
	end

	local perim_map = {}
	for _, p in ipairs(fp_list) do
		local is_perim = false
		for _, offset in ipairs({{x=1,z=0}, {x=-1,z=0}, {x=0,z=1}, {x=0,z=-1}}) do
			local nx = p.x + offset.x
			local nz = p.z + offset.z
			if not fp_set[nx .. ":" .. nz] then
				is_perim = true
				break
			end
		end
		if is_perim then
			perim_map[p.x .. ":" .. p.z] = true
		end
	end

	return fp_list, fp_set, perim_map
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

local norm_fp_list, norm_fp_set, norm_perim = build_footprint_data(generate_normal_footprint)
local small_fp_list, small_fp_set, small_perim = build_footprint_data(generate_small_footprint)

local ship_types = {
	ocean_liner = {
		id = "ocean_liner",
		title = "RMS Titanic Ocean Liner",
		desc = "Massive ocean liner with walkable decks and full interior. Needs 3 blocks of water depth under hull. Autonomous 60s shuttle travel. Rotate with screwdriver. Build cabins & rooms inside!",
		mesh = "ship-ocean-liner.obj",
		icon = "ship-ocean-liner.png",
		visual_size = {x = 12, y = 12, z = 12}, -- 20% bigger (scale 1.2 in Luanti/Minetest)
		funnels = { {lx = 0, lz = 3.9}, {lx = 0, lz = 0.9}, {lx = 0, lz = -2.1}, {lx = 0, lz = -5.1} },
		funnel_height = 10.5,
		footprint = norm_fp_list,
		fp_set = norm_fp_set,
		perim_map = norm_perim,
		max_lz = 12,
		min_lz = -12,
		half_length = 12,
		half_width = 2,
		depth_check_points = { {lz = 11}, {lz = 0}, {lz = -11} },
	},
	ocean_liner_small = {
		id = "ocean_liner_small",
		title = "Small Ocean Liner",
		desc = "Compact ocean liner with walkable decks and full interior. Needs 3 blocks of water depth under hull. Autonomous 60s shuttle travel. Rotate with screwdriver. Build cabins & rooms inside!",
		mesh = "ship-ocean-liner-small.obj",
		icon = "ship-ocean-liner-small.png",
		visual_size = {x = 12, y = 12, z = 12}, -- 20% bigger (scale 1.2 in Luanti/Minetest)
		funnels = { {lx = 0, lz = 3.9}, {lx = 0, lz = 0.9}, {lx = 0, lz = -2.1} },
		funnel_height = 10.5,
		footprint = small_fp_list,
		fp_set = small_fp_set,
		perim_map = small_perim,
		max_lz = 12,
		min_lz = -6,
		half_length = 9,
		half_width = 2,
		depth_check_points = { {lz = 11}, {lz = 3}, {lz = -5} },
	},
}

-- -----------------------------------------------------------------------------
-- Registration of Deck Surface & Invisible Hull Barrier Nodes
-- -----------------------------------------------------------------------------

-- 1. Walkable Deck Floor & Ceiling (Completely Invisible, Solid, Non-Floodable)
minetest.register_node("titanic:deck", {
	description = "Titanic Deck Surface",
	tiles = {"titanic_deck.png"},
	drawtype = "airlike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = true,
	pointable = true,
	diggable = true,
	buildable_to = false,
	floodable = false, -- Never replaced or washed away by ocean water!
	groups = {choppy = 2, cracky = 2, oddly_breakable_by_hand = 1},
	drop = "titanic:deck",

	on_rotate = function(pos, node, user, mode, new_param2)
		local meta = minetest.get_meta(pos)
		local ship_id = meta:get_string("ship_id")
		local ship_ent = titanic.active_ships[ship_id]
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
		local meta = minetest.get_meta(pos)
		local ship_id = meta:get_string("ship_id")
		local ship_ent = titanic.active_ships[ship_id]
		if ship_ent then
			ship_ent:on_punch(puncher)
		end
	end,
})

-- 2. Invisible Hull Barrier (Prevents Water Leakage & Stops Players from Falling Out)
minetest.register_node("titanic:hull", {
	description = "Titanic Hull Wall",
	tiles = {"titanic_deck.png"},
	drawtype = "airlike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = true,
	pointable = false, -- Transparent to player crosshair: place blocks inside freely!
	diggable = false,
	buildable_to = false,
	floodable = false, -- Blocks water from entering the cabin!
	groups = {not_in_creative_inventory = 1},
})

-- -----------------------------------------------------------------------------
-- Ship Entity Implementation
-- -----------------------------------------------------------------------------

local function create_ship_entity(sdef)
	local entity = {
		initial_properties = {
			physical = false,
			collide_with_objects = false,
			backface_culling = false,
			-- Submerged keel selectionbox only (y <= 0.5). Above waterline, player crosshairs
			-- hit the deck and interior nodes directly so blocks can be placed with 100% ease!
			selectionbox = {-2.5, -1.5, -sdef.half_length, 2.5, 0.5, sdef.half_length},
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
				-- Within vertical bounds of ship (ly=1 to 10)
				if ly >= 1 and ly <= 10 then
					-- Within horizontal bounds of ship
					if math.abs(lx) <= self.sdef.half_width and lz >= self.sdef.min_lz and lz <= self.sdef.max_lz then
						-- Allow jumping off into open sea outside the hull
						local is_swimming_away = false
						if math.abs(lx) >= self.sdef.half_width and is_water(ppos) then
							is_swimming_away = true
						end
						if not is_swimming_away then
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
	function entity:collect_custom_blocks(ship_pos, dir, right)
		local custom = {}
		for _, fp in ipairs(self.sdef.footprint) do
			for ly = 1, 10 do
				local wp = local_to_world_pos(ship_pos, fp.x, ly, fp.z, dir, right)
				local node = minetest.get_node(wp)
				if node.name ~= "air" and node.name ~= "ignore"
						and node.name ~= "titanic:deck" and node.name ~= "titanic:hull"
						and not is_water(wp) then
					local meta = minetest.get_meta(wp):to_table()
					table.insert(custom, {
						lx = fp.x,
						ly = ly,
						lz = fp.z,
						node = node,
						meta = meta,
						old_p = wp,
					})
				end
			end
		end
		return custom
	end

	-- -------------------------------------------------------------------------
	-- Initial Deck & Solid Dry Hull Generation
	-- -------------------------------------------------------------------------
	function entity:spawn_initial_decks(pos_override, dir_override, right_override)
		local base_pos = pos_override or self.grid_anchor or self.current_pos
		if not base_pos then return end
		local dir = dir_override
		local right = right_override
		if not dir or not right then
			dir, right = get_direction_vectors(self.yaw)
		end

		for _, fp in ipairs(self.sdef.footprint) do
			local key = fp.x .. ":" .. fp.z
			local is_perimeter = self.sdef.perim_map[key]

			-- 1. Lower Deck Floor (ly = 1): Solid floor for interior cabins & engine rooms
			local p_floor = local_to_world_pos(base_pos, fp.x, 1, fp.z, dir, right)
			minetest.set_node(p_floor, {name = "titanic:deck"})
			minetest.get_meta(p_floor):set_string("ship_id", self.ship_id)

			-- 2. Lower Cabin Space (ly = 2, 3):
			-- Perimeter has invisible hull barriers to prevent water leaks and player falling out;
			-- Interior has 100% dry air!
			for ly = 2, 3 do
				local p_mid = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
				if is_perimeter then
					minetest.set_node(p_mid, {name = "titanic:hull"})
				else
					minetest.set_node(p_mid, {name = "air"})
				end
			end

			-- 3. Upper Promenade Deck / Cabin Ceiling (ly = 4): Solid invisible deck surface
			local p_promenade = local_to_world_pos(base_pos, fp.x, 4, fp.z, dir, right)
			minetest.set_node(p_promenade, {name = "titanic:deck"})
			minetest.get_meta(p_promenade):set_string("ship_id", self.ship_id)

			-- 4. Clear any water above upper deck (ly = 5, 6, 7)
			for ly = 5, 7 do
				local p_up = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
				if is_water(p_up) then
					minetest.set_node(p_up, {name = "air"})
				end
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Clear All Ship Nodes at a Given Position & Heading (Restores Water/Air)
	-- -------------------------------------------------------------------------
	function entity:clear_ship_nodes(base_pos, dir, right)
		for _, fp in ipairs(self.sdef.footprint) do
			for ly = 1, 10 do
				local wp = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
				local node = minetest.get_node(wp)
				if node.name == "titanic:deck" or node.name == "titanic:hull" then
					if wp.y <= base_pos.y then
						minetest.set_node(wp, {name = get_water_node()})
					else
						minetest.set_node(wp, {name = "air"})
					end
				end
			end
		end
	end

	-- -------------------------------------------------------------------------
	-- Screwdriver Rotation (90° / 180° with Screwdriver or Shuttle Turnaround)
	-- -------------------------------------------------------------------------
	function entity:rotate_by(angle, player)
		if self.removed or not self.current_pos then return end
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

		local anchor = self.grid_anchor or {
			x = math.floor(self.current_pos.x + 0.5),
			y = math.floor(self.current_pos.y + 0.5),
			z = math.floor(self.current_pos.z + 0.5)
		}

		local old_dir, old_right = get_direction_vectors(old_yaw)
		local new_dir, new_right = get_direction_vectors(new_yaw)

		-- 1. Collect all custom user blocks at old orientation
		local custom_blocks = self:collect_custom_blocks(anchor, old_dir, old_right)
		local riders = self:get_riders(anchor)

		-- 2. Clear old custom nodes
		for _, b in ipairs(custom_blocks) do
			if b.old_p.y <= anchor.y then
				minetest.set_node(b.old_p, {name = get_water_node()})
			else
				minetest.set_node(b.old_p, {name = "air"})
			end
		end

		-- 3. Clear old deck and hull nodes
		self:clear_ship_nodes(anchor, old_dir, old_right)

		-- 4. Update entity yaw and position
		self.yaw = new_yaw
		self.grid_anchor = anchor
		self.current_pos = table.copy(anchor)
		self.object:set_pos(anchor)
		self.object:set_yaw(new_yaw)
		self.object:set_properties({backface_culling = false})
		record_ship_position(self.ship_id, anchor, self.ship_type, new_yaw)

		-- 5. Spawn new deck and hull boundary nodes at new orientation
		self:spawn_initial_decks(anchor, new_dir, new_right)

		-- 6. Place rotated custom blocks at new orientation
		local angle_steps = math.floor(math.deg(angle) / 90 + 0.5) % 4
		for _, b in ipairs(custom_blocks) do
			local new_p = local_to_world_pos(anchor, b.lx, b.ly, b.lz, new_dir, new_right)
			local new_node = table.copy(b.node)
			local ndef = minetest.registered_nodes[new_node.name]
			if ndef and (ndef.paramtype2 == "facedir" or ndef.paramtype2 == "4dir") then
				new_node.param2 = rotate_facedir(new_node.param2, angle_steps)
			end
			minetest.set_node(new_p, new_node)
			if b.meta then
				minetest.get_meta(new_p):from_table(b.meta)
			end
		end

		-- 7. Rotate riders inside or on top of the ship
		for _, rider in ipairs(riders) do
			local ppos = rider:get_pos()
			local lx, ly, lz = world_to_local_pos(anchor, ppos, old_dir, old_right)
			local new_ppos = local_to_world_pos(anchor, lx, ly, lz, new_dir, new_right)
			rider:set_pos({x = new_ppos.x, y = ppos.y, z = new_ppos.z})
			local cur_yaw = rider:get_look_horizontal()
			rider:set_look_horizontal(cur_yaw + angle)
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
				time = 0.45,
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
			time = 0.45,
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
	-- Smooth Differential Cruising Step (Zero Churn, Zero Blinking, Zero Water)
	-- -------------------------------------------------------------------------
	function entity:execute_travel_step()
		if not self.current_pos or self.removed then return end
		local dir, right = get_direction_vectors(self.yaw)
		local step_dir = {x = dir.x, y = 0, z = dir.z}
		local base_pos = self.grid_anchor or self.current_pos
		local target_pos = vector.add(base_pos, step_dir)

		-- 1. Check depth & obstacles ahead before taking this step
		local is_clear, reason = self:check_depth_and_obstacles(target_pos)
		if not is_clear then
			if reason == "iceberg" then
				self:strike_iceberg()
				return
			end

			-- Reached dock / shore / shallow water!
			-- Stop, schedule 180° turnaround for return voyage, and idle for 60 seconds!
			self.state = "idle"
			self.idle_timer = 0
			self.needs_turnaround = true -- Rotates 180° on departure!
			play_sound("default_place_node", {pos = base_pos, gain = 0.8})

			local riders = self:get_riders()
			for _, r in ipairs(riders) do
				minetest.chat_send_player(r:get_player_name(),
					string.format("⚓ Titanic reached dock (%s). Idling 60s at dock before return voyage.", reason))
			end
			return
		end

		-- 2. Detect riders who are on board BEFORE moving
		local riders = self:get_riders()

		-- 3. Collect custom user placed blocks (chests, chairs, luggage)
		local custom_blocks = self:collect_custom_blocks(base_pos, dir, right)

		-- 4. Move custom user blocks by step_dir
		for _, b in ipairs(custom_blocks) do
			minetest.set_node(b.old_p, {name = "air"})
		end
		for _, b in ipairs(custom_blocks) do
			local new_p = local_to_world_pos(target_pos, b.lx, b.ly, b.lz, dir, right)
			minetest.set_node(new_p, b.node)
			if b.meta then
				minetest.get_meta(new_p):from_table(b.meta)
			end
		end

		-- 5. Differential Deck & Hull Update:
		-- Only vacate nodes at the trailing edge (stern) and create nodes at leading edge (bow)!
		-- All middle 95% of deck and hull nodes are completely untouched (zero blinking!)

		-- (A) Vacate Stern (trailing edge)
		for _, fp in ipairs(self.sdef.footprint) do
			-- Check if (fp.x, fp.z - 1) is still within the ship footprint at target_pos
			local remains_in_target = self.sdef.fp_set[fp.x .. ":" .. (fp.z - 1)]
			if not remains_in_target then
				-- This column at base_pos is vacated! Restore ocean water / air
				for ly = 1, 4 do
					local old_wp = local_to_world_pos(base_pos, fp.x, ly, fp.z, dir, right)
					local cur = minetest.get_node(old_wp)
					if cur.name == "titanic:deck" or cur.name == "titanic:hull" or cur.name == "air" then
						if old_wp.y <= base_pos.y then
							minetest.set_node(old_wp, {name = get_water_node()})
						else
							minetest.set_node(old_wp, {name = "air"})
						end
					end
				end
			end
		end

		-- (B) Create Bow (leading edge)
		for _, fp in ipairs(self.sdef.footprint) do
			-- Check if (fp.x, fp.z + 1) was already within the ship footprint at base_pos
			local was_in_base = self.sdef.fp_set[fp.x .. ":" .. (fp.z + 1)]
			if not was_in_base then
				-- This column at target_pos is newly entered!
				local key = fp.x .. ":" .. fp.z
				local is_perimeter = self.sdef.perim_map[key]

				-- Floor (ly = 1)
				local p_floor = local_to_world_pos(target_pos, fp.x, 1, fp.z, dir, right)
				minetest.set_node(p_floor, {name = "titanic:deck"})
				minetest.get_meta(p_floor):set_string("ship_id", self.ship_id)

				-- Lower Cabin Walls & Air (ly = 2, 3)
				for ly = 2, 3 do
					local p_mid = local_to_world_pos(target_pos, fp.x, ly, fp.z, dir, right)
					if is_perimeter then
						minetest.set_node(p_mid, {name = "titanic:hull"})
					else
						minetest.set_node(p_mid, {name = "air"})
					end
				end

				-- Promenade Deck (ly = 4)
				local p_prom = local_to_world_pos(target_pos, fp.x, 4, fp.z, dir, right)
				minetest.set_node(p_prom, {name = "titanic:deck"})
				minetest.get_meta(p_prom):set_string("ship_id", self.ship_id)

				-- Clear any water above deck
				for ly = 5, 7 do
					local p_up = local_to_world_pos(target_pos, fp.x, ly, fp.z, dir, right)
					if is_water(p_up) then
						minetest.set_node(p_up, {name = "air"})
					end
				end
			end
		end

		-- 6. Move 3D ship entity synchronously to target_pos
		self.current_pos = target_pos
		self.grid_anchor = target_pos
		self.object:set_pos(target_pos)
		record_ship_position(self.ship_id, target_pos, self.ship_type, self.yaw)

		-- 7. Translate riders who were on board by step_dir
		for _, rider in ipairs(riders) do
			local ppos = rider:get_pos()
			if ppos then
				rider:set_pos({x = ppos.x + step_dir.x, y = ppos.y, z = ppos.z + step_dir.z})
			end
		end

		-- 8. Emit continuous travel particles (coal smoke & stern wake)
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
				y = math.floor(pos.y + 0.5),
				z = math.floor(pos.z + 0.5),
			}
		end
		self.current_pos = self.grid_anchor and table.copy(self.grid_anchor) or table.copy(pos)
		self.travel_step_timer = 0

		titanic.active_ships[self.ship_id] = self
		self.object:set_yaw(self.yaw)
		self.object:set_properties({backface_culling = false})
		self.object:set_velocity({x = 0, y = 0, z = 0})

		record_ship_position(self.ship_id, self.grid_anchor or self.current_pos, self.ship_type, self.yaw)
		if is_new then
			self:spawn_initial_decks()
		end
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

		-- Sinking state
		if self.state == "sinking" then
			self.sink_timer = (self.sink_timer or 0) + dtime
			local new_y = cur.y - 0.5 * dtime
			self.object:set_pos({x = cur.x, y = new_y, z = cur.z})

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
					play_sound("default_place_node", {pos = cur, gain = 1.0})
				end

				local dir, right = get_direction_vectors(self.yaw)
				local forward_step = {x = dir.x, y = 0, z = dir.z}
				local target_pos = vector.add(self.grid_anchor or cur, forward_step)

				local is_clear, reason = self:check_depth_and_obstacles(target_pos)
				if is_clear then
					-- Clear to depart in forward direction!
					self.state = "traveling"
					self.direction = 1
					self.idle_timer = 0
					self.travel_step_timer = 0
					play_sound("default_place_node", {pos = cur, gain = 1.0})
					local riders = self:get_riders()
					for _, r in ipairs(riders) do
						minetest.chat_send_player(r:get_player_name(),
							string.format("🚢 %s departing! Cruising in a straight path forward...", self.sdef.title))
					end
				elseif reason == "iceberg" then
					self:strike_iceberg()
					return
				else
					-- Forward blocked before departure; try rotating 180° to return
					self:rotate_by(math.pi)
					local rev_dir, _ = get_direction_vectors(self.yaw)
					local rev_target = vector.add(self.grid_anchor or cur, rev_dir)
					local rev_clear, rev_reason = self:check_depth_and_obstacles(rev_target)

					if rev_clear then
						self.state = "traveling"
						self.direction = 1
						self.idle_timer = 0
						self.travel_step_timer = 0
						play_sound("default_place_node", {pos = cur, gain = 1.0})
						local riders = self:get_riders()
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
						local riders = self:get_riders()
						for _, r in ipairs(riders) do
							minetest.chat_send_player(r:get_player_name(),
								string.format("⚠️ Titanic cannot travel (%s): needs 3 blocks of water depth under hull!", reason))
						end
					end
				end
			end
		elseif self.state == "traveling" then
			self.travel_step_timer = (self.travel_step_timer or 0) + dtime
			-- Steady, smooth cruising step every 0.45 seconds (~2.2 m/s majestic cruise)
			if self.travel_step_timer >= 0.45 then
				self.travel_step_timer = 0
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

		local anchor = self.grid_anchor or self.current_pos
		if clean_nodes and anchor then
			local dir, right = get_direction_vectors(self.yaw)

			-- Drop or clear custom blocks
			local custom = self:collect_custom_blocks(anchor, dir, right)
			for _, b in ipairs(custom) do
				if drop_inventory then
					minetest.node_dig(b.old_p, b.node, nil)
				else
					minetest.set_node(b.old_p, {name = (b.old_p.y <= anchor.y) and get_water_node() or "air"})
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
		local riders = self:get_riders()
		local anchor = self.grid_anchor or self.current_pos
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

		-- 2. Clear deck and hull nodes so the floor disappears and hull is flooded
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
	-- Pickaxe-Only Dismantling & Screwdriver Interaction
	-- -------------------------------------------------------------------------
	function entity:on_punch(puncher)
		if not puncher or not puncher:is_player() or self.removed then return end
		local tool = puncher:get_wielded_item():get_name()

		-- Screwdriver rotation
		if is_screwdriver(tool) then
			self.needs_turnaround = false
			self:rotate_by(math.pi / 2, puncher)
			return
		end

		if self.state == "traveling" then
			minetest.chat_send_player(puncher:get_player_name(),
				"⚓ The ocean liner is under way! Wait until docked to dismantle.")
			return
		end

		-- Pickaxe dismantling
		if not is_pickaxe(tool) then
			play_sound("default_place_node", {pos = self.current_pos, gain = 0.5})
			minetest.chat_send_player(puncher:get_player_name(),
				"⚓ Titanic ocean liners are reinforced! Use a pickaxe to dismantle.")
			return
		end

		local anchor = self.grid_anchor or self.current_pos
		local ship_pos = table.copy(anchor)
		local ship_item = modname .. ":" .. self.ship_type

		self:remove_vessel(true, true)
		play_sound("default_dig_cracky", {pos = ship_pos, gain = 1.0})

		local inv = puncher:get_inventory()
		local pname = puncher:get_player_name()
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

			local look_yaw = placer and placer:get_look_horizontal() or 0
			local cardinal_yaw = normalize_cardinal_yaw(look_yaw)

			local obj = minetest.add_entity(spawn_pos, entity_name)
			if obj then
				local ent = obj:get_luaentity()
				if ent then
					ent.yaw = cardinal_yaw
					ent.direction = 1
					ent.current_pos = table.copy(spawn_pos)
					ent.grid_anchor = table.copy(spawn_pos)
					obj:set_yaw(cardinal_yaw)
					obj:set_properties({backface_culling = false})
					ent:spawn_initial_decks()
				end

				play_sound("default_place_node", {pos = spawn_pos, gain = 0.8})

				if placer and placer:is_player() then
					minetest.chat_send_player(placer:get_player_name(),
						string.format("🚢 %s launched! Heading %s. Idling 60s at dock before departure. Build interior rooms & cabins inside! Use screwdriver to rotate.",
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
		for _, pos in ipairs(orphan_nodes) do
			minetest.set_node(pos, {name = get_water_node()})
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

minetest.log("action", "[titanic] Loaded Titanic and Ocean Liners with full interior support successfully.")
